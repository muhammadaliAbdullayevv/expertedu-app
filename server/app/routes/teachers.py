from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, schedule
from ..deps import CurrentUser, Scope, get_current_user, get_scope, require_owner
from ..money import rules, service as money
from ..phone import normalize
from ..scope import branch_filter, link_teacher, require_teacher, teacher_filter
from ..schemas import (
    CreateTeacherRequest,
    ScheduleSlot,
    Teacher,
    TeacherGroupCard,
    TeacherListItem,
    TeacherMonthPoint,
    TeacherProfile,
    SetTeacherBranchesRequest,
    UpdateTeacherRequest,
)
from .timetable import _timetable

router = APIRouter(prefix="/teachers", tags=["teachers"], dependencies=[Depends(get_current_user)])


def _clean_phone(phone: str | None) -> str | None:
    return normalize(phone) if phone and phone.strip() else None


_BRANCHES = """
coalesce((select array_agg(tb.branch_id order by b.name) from teacher_branches tb join branches b on b.id = tb.branch_id
          where tb.teacher_id = t.id and {scope}), '{{}}') as branch_ids,
coalesce((select array_agg(b.name order by b.name) from teacher_branches tb join branches b on b.id = tb.branch_id
          where tb.teacher_id = t.id and {scope}), '{{}}') as branch_names
"""


def _branches(n: int) -> str:
    return _BRANCHES.format(scope=branch_filter("tb.branch_id", n))


async def _teacher(conn, scope: Scope, teacher_id: int) -> Teacher:
    """The teacher as the scope sees them, or 404."""
    row = await conn.fetchrow(
        f"select t.*, {_branches(2)} from teachers t where t.id = $1 and {teacher_filter('t', 2)}",
        teacher_id,
        scope.ids,
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
    return Teacher(**row)


@router.get("", response_model=list[TeacherListItem])
async def list_teachers(include_inactive: bool = False, scope: Scope = Depends(get_scope)):
    where = teacher_filter("t", 1) + ("" if include_inactive else " and t.is_active")
    rows = await db.pool().fetch(
        f"""
        select t.*, {_branches(1)},
               count(distinct g.id) filter (where g.is_active) as group_count,
               count(e.id) filter (where g.is_active and e.status = 'active') as student_count
        from teachers t
        left join groups g on g.teacher_id = t.id and {branch_filter('g.branch_id', 1)}
        left join enrollments e on e.group_id = g.id
        where {where}
        group by t.id
        order by t.full_name asc
        """,
        scope.ids,
    )
    return [TeacherListItem(**row) for row in rows]


@router.post("", response_model=Teacher, status_code=status.HTTP_201_CREATED)
async def create_teacher(
    payload: CreateTeacherRequest, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    name = payload.full_name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                """
                insert into teachers (full_name, phone, note, created_by)
                values ($1, $2, $3, $4)
                returning id
                """,
                name,
                _clean_phone(payload.phone),
                payload.note,
                user.id,
            )
            await link_teacher(conn, row["id"], scope.write_branch())
            return await _teacher(conn, scope, row["id"])


@router.put("/{teacher_id}/branches", response_model=Teacher)
async def set_teacher_branches(
    teacher_id: int, payload: SetTeacherBranchesRequest, user: CurrentUser = Depends(require_owner)
):
    """OWNER ONLY: which branches this teacher works in (at least one)."""
    ids = sorted(set(payload.branch_ids))
    if not ids:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Kamida bitta filialni tanlang.")
    everything = Scope(user, None, 0)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await require_teacher(conn, everything, teacher_id)
            if await conn.fetchval("select count(*) from branches where id = any($1::bigint[])", ids) != len(ids):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Filial topilmadi.")
            # A teacher cannot be taken out of a branch where they still teach a group.
            blocked = await conn.fetchval(
                """
                select b.name from groups g join branches b on b.id = g.branch_id
                where g.teacher_id = $1 and g.is_active and g.branch_id <> all($2::bigint[]) limit 1
                """,
                teacher_id, ids,
            )
            if blocked:
                raise HTTPException(
                    status.HTTP_409_CONFLICT, f"{blocked} filialida hali guruhi bor: avval guruhni boshqa o'qituvchiga bering."
                )
            await conn.execute("delete from teacher_branches where teacher_id = $1 and branch_id <> all($2::bigint[])", teacher_id, ids)
            for branch_id in ids:
                await link_teacher(conn, teacher_id, branch_id)
            return await _teacher(conn, everything, teacher_id)


@router.patch("/{teacher_id}", response_model=Teacher)
async def update_teacher(teacher_id: int, payload: UpdateTeacherRequest, scope: Scope = Depends(get_scope)):
    existing = await require_teacher(db.pool(), scope, teacher_id)

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return await _teacher(db.pool(), scope, teacher_id)
    if "full_name" in updates:
        if not (updates["full_name"] or "").strip():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
        updates["full_name"] = updates["full_name"].strip()
    if "is_active" in updates and updates["is_active"] is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "is_active bo'sh bo'lishi mumkin emas.")
    if "phone" in updates:
        updates["phone"] = _clean_phone(updates["phone"])

    fields = list(updates.keys())
    values = list(updates.values())
    set_clause = ", ".join(f"{field} = ${i + 2}" for i, field in enumerate(fields))
    await db.pool().execute(f"update teachers set {set_clause} where id = $1", teacher_id, *values)
    return await _teacher(db.pool(), scope, teacher_id)


def _months_back(month: date, count: int) -> list[date]:
    months = [month]
    for _ in range(count - 1):
        months.insert(0, rules.month_start(months[0] - timedelta(days=1)))
    return months


@router.get("/{teacher_id}/profile", response_model=TeacherProfile)
async def teacher_profile(
    teacher_id: int,
    month: date | None = None,
    user: CurrentUser = Depends(get_current_user),
    scope: Scope = Depends(get_scope),
):
    """The teacher's page: their groups (name, students, days, times), what
    they earn this month, today and tomorrow, and six months of pay. The pay is
    the share of what ALL their groups collected (or their fixed amount), worked
    out by the same calculation as the Finance page, so the two always agree."""
    today = clock.today()
    month = rules.month_start(month or today)
    async with db.pool().acquire() as conn:
        teacher = await require_teacher(conn, scope, teacher_id)
        teacher_out = await _teacher(conn, scope, teacher_id)

        groups = await conn.fetch(
            f"""
            select g.id, g.name, g.level, g.capacity, s.name as subject_name, b.name as branch_name,
                   (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as students
            from groups g
            left join subjects s on s.id = g.subject_id
            left join branches b on b.id = g.branch_id
            where g.teacher_id = $1 and g.is_active and {branch_filter('g.branch_id', 2)}
            order by g.name
            """,
            teacher_id,
            scope.ids,
        )
        slots = await schedule.load_slots(conn, group_ids=[g["id"] for g in groups], active_only=False)
        lessons = await _timetable(conn, today, today + timedelta(days=1), teacher_id=teacher_id, ids=scope.ids)

        # Pay is the owner's alone: an admin's request never even computes it.
        report, mine, history = None, None, []
        if user.is_owner:
            report = await money.salary_month(conn, month, scope.ids)
            mine = next((t for t in report["teachers"] if t["teacher_id"] == teacher_id), None)
            for m in _months_back(month, 6):
                r = report if m == month else await money.salary_month(conn, m, scope.ids)
                row = next((t for t in r["teachers"] if t["teacher_id"] == teacher_id), None)
                history.append(
                    TeacherMonthPoint(
                        month=m,
                        collected=row["collected"] if row else 0,
                        earned=row["earned"] if row else 0,
                        paid=row["paid"] if row else 0,
                        closed=r["closed"],
                    )
                )

    cards = [
        TeacherGroupCard(
            group_id=g["id"],
            name=g["name"],
            subject_name=g["subject_name"],
            level=g["level"],
            student_count=g["students"],
            capacity=g["capacity"],
            branch_name=g["branch_name"],
            schedule=[
                ScheduleSlot(weekday=sl.weekday, starts_at=sl.starts_at, ends_at=sl.ends_at, room=sl.room)
                for sl in slots
                if sl.group_id == g["id"]
            ],
        )
        for g in groups
    ]
    return TeacherProfile(
        teacher=teacher_out,
        salary_visible=user.is_owner,
        salary_method=teacher["salary_method"] if user.is_owner else None,
        salary_percent=(
            float(teacher["salary_percent"]) if user.is_owner and teacher["salary_percent"] is not None else None
        ),
        salary_fixed=teacher["salary_fixed"] if user.is_owner else None,
        groups=cards,
        student_total=sum(g["students"] for g in groups),
        month=month,
        month_closed=report["closed"] if report else False,
        collected=mine["collected"] if mine else 0,
        earned=mine["earned"] if mine else 0,
        paid=mine["paid"] if mine else 0,
        remaining=mine["remaining"] if mine else 0,
        lessons=lessons,
        history=history,
    )
