from fastapi import APIRouter, Depends, HTTPException, status

from .. import db, schedule
from ..deps import CurrentUser, get_current_user
from ..money import rules, service as money
from ..schemas import CreateGroupRequest, Group, GroupListItem, RosterEntry, ScheduleSlot, UpdateGroupRequest

router = APIRouter(prefix="/groups", tags=["groups"], dependencies=[Depends(get_current_user)])

# Every single-group read goes through here, so teacher_name is always the
# linked teacher's current name -- groups no longer store one of their own.
_GROUP_SELECT = """
select g.*, t.full_name as teacher_name
from groups g
left join teachers t on t.id = g.teacher_id
"""


_REQUIRED_LABELS = {
    "subject_id": "Fan",
    "name": "Guruh nomi",
    "fee_amount": "Narx",
    "billing_mode": "To'lov turi",
    "prorate_first_period": "Birinchi davrni hisoblash",
    "is_active": "Holat",
}


def _billing(mode: str, billing_day: int | None, due_day: int | None = None) -> tuple[str, int | None]:
    """(mode, day) to store. fixed_day needs a day from 1 to 28 (older
    builds send due_day, which is capped at 28); a student_anniversary
    group has no day -- each enrollment bills on its own start day."""
    if mode not in rules.BILLING_MODES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov turi noto'g'ri.")
    if mode == "student_anniversary":
        return mode, None
    day = billing_day if billing_day is not None else (None if due_day is None else min(due_day, 28))
    if day is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov kunini kiriting.")
    if not 1 <= day <= 28:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "To'lov kuni 1 dan 28 gacha bo'lishi kerak.")
    return mode, day


def _validate(
    *,
    name: str | None = None,
    fee_amount: int | None = None,
    capacity: int | None = None,
) -> None:
    if name is not None and not name.strip():
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Guruh nomi kiritilishi shart.")
    if fee_amount is not None and fee_amount <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Narx musbat bo'lishi kerak.")
    if capacity is not None and capacity <= 0:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sig'im musbat son bo'lishi kerak.")


async def _require_subject(subject_id: int) -> None:
    if not await db.pool().fetchval("select 1 from subjects where id = $1", subject_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fan topilmadi.")


async def _require_teacher(teacher_id: int) -> None:
    if not await db.pool().fetchval("select 1 from teachers where id = $1", teacher_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")


async def _teacher_id_for_name(name: str, user_id: int) -> int | None:
    """Matches a typed teacher name (case-insensitively) to an existing
    teacher, creating one if there's none -- how groups created from older
    app builds, which only send a name, still end up linked to a record."""
    name = name.strip()
    if not name:
        return None
    existing = await db.pool().fetchval(
        "select id from teachers where lower(full_name) = lower($1) order by is_active desc, id limit 1",
        name,
    )
    if existing:
        return existing
    return await db.pool().fetchval(
        "insert into teachers (full_name, created_by) values ($1, $2) returning id", name, user_id
    )


async def _fetch_group(group_id: int) -> Group:
    row = await db.pool().fetchrow(f"{_GROUP_SELECT} where g.id = $1", group_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    return Group(**row)


@router.get("", response_model=list[GroupListItem])
async def list_groups(include_inactive: bool = False):
    where = "" if include_inactive else "where g.is_active"
    rows = await db.pool().fetch(
        f"""
        select g.*, t.full_name as teacher_name, s.name as subject_name,
               count(e.id) filter (where e.status = 'active') as student_count
        from groups g
        left join teachers t on t.id = g.teacher_id
        left join subjects s on s.id = g.subject_id
        left join enrollments e on e.group_id = g.id
        {where}
        group by g.id, t.full_name, s.name
        order by g.name asc
        """
    )
    async with db.pool().acquire() as conn:
        slots = await schedule.load_slots(conn, group_ids=[row["id"] for row in rows], active_only=False)
    by_group: dict[int, list[ScheduleSlot]] = {}
    for slot in slots:
        by_group.setdefault(slot.group_id, []).append(
            ScheduleSlot(weekday=slot.weekday, starts_at=slot.starts_at, ends_at=slot.ends_at, room=slot.room)
        )
    return [GroupListItem(**row, schedule=by_group.get(row["id"], [])) for row in rows]


@router.post("", response_model=Group, status_code=status.HTTP_201_CREATED)
async def create_group(payload: CreateGroupRequest, user: CurrentUser = Depends(get_current_user)):
    _validate(name=payload.name, fee_amount=payload.fee_amount, capacity=payload.capacity)
    billing_mode, billing_day = _billing(payload.billing_mode, payload.billing_day, payload.due_day)
    await _require_subject(payload.subject_id)

    teacher_id = payload.teacher_id
    if teacher_id is not None:
        await _require_teacher(teacher_id)
    elif payload.teacher_name:
        teacher_id = await _teacher_id_for_name(payload.teacher_name, user.id)

    group_id = await db.pool().fetchval(
        """
        insert into groups (subject_id, name, teacher_id, fee_amount, billing_mode, billing_day,
                            prorate_first_period, capacity, note, created_by)
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        returning id
        """,
        payload.subject_id,
        payload.name.strip(),
        teacher_id,
        payload.fee_amount,
        billing_mode,
        billing_day,
        payload.prorate_first_period,
        payload.capacity,
        payload.note,
        user.id,
    )
    return await _fetch_group(group_id)


@router.get("/{group_id}", response_model=Group)
async def get_group(group_id: int):
    return await _fetch_group(group_id)


@router.patch("/{group_id}", response_model=Group)
async def update_group(group_id: int, payload: UpdateGroupRequest):
    existing = await _fetch_group(group_id)

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return existing

    # Only the teacher, capacity and note can be cleared; everything else is a
    # required column, so an explicit null is a bad request, not a 500.
    for field, label in _REQUIRED_LABELS.items():
        if field in updates and updates[field] is None:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, f"{label} bo'sh bo'lishi mumkin emas.")
    _validate(
        name=updates.get("name"),
        fee_amount=updates.get("fee_amount"),
        capacity=updates.get("capacity"),
    )
    legacy_due_day = updates.pop("due_day", None)
    if {"billing_mode", "billing_day"} & updates.keys() or legacy_due_day is not None:
        mode, day = _billing(
            updates.get("billing_mode") or existing.billing_mode,
            updates.get("billing_day", None if "billing_mode" in updates else existing.billing_day),
            legacy_due_day,
        )
        if (mode, day) != (existing.billing_mode, existing.billing_day):
            charged = await db.pool().fetchval(
                "select 1 from charges c join enrollments e on e.id = c.enrollment_id "
                "where e.group_id = $1 limit 1",
                group_id,
            )
            if charged:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    "Bu guruhda to'lov talablari bor: to'lov turi yoki kunini o'zgartirib bo'lmaydi.",
                )
        updates["billing_mode"], updates["billing_day"] = mode, day
    if "name" in updates:
        updates["name"] = updates["name"].strip()
    if updates.get("subject_id") is not None:
        await _require_subject(updates["subject_id"])
    if updates.get("teacher_id") is not None:
        await _require_teacher(updates["teacher_id"])

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            # A new teacher, or the group back in use, must still fit the
            # timetable: no teacher or room taken twice at once.
            teacher_id = updates.get("teacher_id", existing.teacher_id)
            is_active = updates.get("is_active", existing.is_active)
            if is_active and (teacher_id != existing.teacher_id or not existing.is_active):
                slots = await schedule.load_slots(conn, group_ids=[group_id], active_only=False)
                await schedule.check_clashes(conn, group_id=group_id, teacher_id=teacher_id, slots=slots)
            await conn.execute(f"update groups set {set_clause} where id = $1", group_id, *values)
    return await _fetch_group(group_id)


@router.get("/{group_id}/roster", response_model=list[RosterEntry])
async def get_roster(group_id: int, include_withdrawn: bool = False):
    where = "" if include_withdrawn else "and e.status = 'active'"
    rows = await db.pool().fetch(
        f"""
        select e.id as enrollment_id, e.student_id, s.full_name as student_full_name,
               s.phone as student_phone, e.joined_at, e.status, eb.owed as balance
        from enrollments e
        join students s on s.id = e.student_id
        join enrollment_balances eb on eb.enrollment_id = e.id
        where e.group_id = $1 {where}
        order by s.full_name asc
        """,
        group_id,
    )
    due = await money.next_due_dates(db.pool(), [row["enrollment_id"] for row in rows])
    return [RosterEntry(**row, next_due_date=due.get(row["enrollment_id"])) for row in rows]
