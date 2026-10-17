from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, status

from .. import admissions, db, idempotency
from ..deps import CurrentUser, get_current_user
from ..schemas import CancelRequest, CreateFollowUpTaskRequest, FollowUpTask, UpdateFollowUpTaskRequest

router = APIRouter(prefix="/follow-up-tasks", tags=["follow-ups"], dependencies=[Depends(get_current_user)])

_TASK_SELECT = """
select t.*, l.full_name as lead_full_name, l.phone as lead_phone, l.stage as lead_stage,
       u.full_name as assigned_to_name
from follow_up_tasks t
join leads l on l.id = t.lead_id
left join users u on u.id = t.assigned_to
"""


async def fetch_tasks(conn, where: str, *args) -> list[FollowUpTask]:
    rows = await conn.fetch(f"{_TASK_SELECT} {where} order by t.status = 'open' desc, t.due_at, t.id", *args)
    return [FollowUpTask(**row) for row in rows]


async def _fetch_task(conn, task_id: int) -> FollowUpTask:
    tasks = await fetch_tasks(conn, "where t.id = $1", task_id)
    if not tasks:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Vazifa topilmadi.")
    return tasks[0]


async def _lock_open_task(conn, task_id: int, version: int | None = None) -> dict:
    task = await conn.fetchrow("select * from follow_up_tasks where id = $1 for update", task_id)
    if task is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Vazifa topilmadi.")
    admissions.check_version(task["version"], version)
    if task["status"] != "open":
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu vazifa allaqachon yopilgan.")
    return task


def _title(value: str | None) -> str:
    title = (value or "").strip()
    if not title:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Vazifani yozing.")
    return title


@router.get("", response_model=list[FollowUpTask])
async def list_tasks(
    status_filter: str = "open",
    assigned_to: int | None = None,
    lead_id: int | None = None,
    due_before: datetime | None = None,
):
    """status_filter: 'open' (default), 'done', 'cancelled' or 'all'."""
    conditions, args = [], []
    if status_filter != "all":
        if status_filter not in ("open", "done", "cancelled"):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Holat noto'g'ri.")
        args.append(status_filter)
        conditions.append(f"t.status = ${len(args)}")
    if assigned_to is not None:
        args.append(assigned_to)
        conditions.append(f"t.assigned_to = ${len(args)}")
    if lead_id is not None:
        args.append(lead_id)
        conditions.append(f"t.lead_id = ${len(args)}")
    if due_before is not None:
        args.append(admissions.aware(due_before))
        conditions.append(f"t.due_at < ${len(args)}")
    where = f"where {' and '.join(conditions)}" if conditions else ""
    async with db.pool().acquire() as conn:
        return await fetch_tasks(conn, where, *args)


@router.post("", response_model=FollowUpTask, status_code=status.HTTP_201_CREATED)
async def create_task(
    payload: CreateFollowUpTaskRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    title = _title(payload.title)

    async def work(conn):
        lead = await admissions.lock_lead(conn, payload.lead_id)
        if lead["stage"] not in admissions.OPEN_STAGES:
            raise HTTPException(status.HTTP_409_CONFLICT, "So'rov yopilgan — vazifa qo'shib bo'lmaydi.")
        if payload.assigned_to is not None and not await conn.fetchval(
            "select 1 from users where id = $1 and is_active", payload.assigned_to
        ):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Mas'ul xodim topilmadi.")
        task_id = await admissions.add_task(
            conn, lead, title, admissions.aware(payload.due_at), user_id=user.id, assigned_to=payload.assigned_to
        )
        return await _fetch_task(conn, task_id)

    return await idempotency.run(
        key=idempotency_key, user=user, endpoint="POST /follow-up-tasks", payload=payload, work=work
    )


@router.patch("/{task_id}", response_model=FollowUpTask)
async def update_task(task_id: int, payload: UpdateFollowUpTaskRequest, user: CurrentUser = Depends(get_current_user)):
    changes = payload.model_dump(exclude_unset=True)
    changes.pop("version")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            task = await _lock_open_task(conn, task_id, payload.version)
            if "title" in changes:
                changes["title"] = _title(changes["title"])
            if "due_at" in changes:
                if changes["due_at"] is None:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Muddatni tanlang.")
                changes["due_at"] = admissions.aware(changes["due_at"])
            if changes.get("assigned_to") is not None and not await conn.fetchval(
                "select 1 from users where id = $1 and is_active", changes["assigned_to"]
            ):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Mas'ul xodim topilmadi.")
            changes = {field: value for field, value in changes.items() if value != task[field]}
            if changes:
                set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(changes))
                await conn.execute(
                    f"update follow_up_tasks set {set_clause}, version = version + 1 where id = $1",
                    task_id,
                    *changes.values(),
                )
                await admissions.log(
                    conn, task["lead_id"], f"Vazifa o'zgartirildi: {changes.get('title', task['title'])}",
                    user_id=user.id, task_id=task_id,
                )
            return await _fetch_task(conn, task_id)


async def _close(task_id: int, new_status: str, note: str | None, user: CurrentUser) -> FollowUpTask:
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            task = await conn.fetchrow("select * from follow_up_tasks where id = $1 for update", task_id)
            if task is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Vazifa topilmadi.")
            if task["status"] == new_status:
                return await _fetch_task(conn, task_id)
            if task["status"] != "open":
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu vazifa allaqachon yopilgan.")
            await conn.execute(
                "update follow_up_tasks set status = $2, completed_at = now(), completed_by = $3, "
                "version = version + 1 where id = $1",
                task_id,
                new_status,
                user.id,
            )
            verb = "Vazifa bajarildi" if new_status == "done" else "Vazifa bekor qilindi"
            body = f"{verb}: {task['title']}"
            if note:
                body += f". {note}"
            await admissions.log(conn, task["lead_id"], body, user_id=user.id, task_id=task_id)
            return await _fetch_task(conn, task_id)


@router.post("/{task_id}/complete", response_model=FollowUpTask)
async def complete_task(task_id: int, payload: CancelRequest, user: CurrentUser = Depends(get_current_user)):
    """payload.reason is an optional note on how it went."""
    return await _close(task_id, "done", (payload.reason or "").strip() or None, user)


@router.post("/{task_id}/cancel", response_model=FollowUpTask)
async def cancel_task(task_id: int, payload: CancelRequest, user: CurrentUser = Depends(get_current_user)):
    return await _close(task_id, "cancelled", (payload.reason or "").strip() or None, user)
