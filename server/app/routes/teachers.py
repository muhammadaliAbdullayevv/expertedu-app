from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, schedule
from ..deps import CurrentUser, get_current_user
from ..money import rules, service as money
from ..phone import normalize
from ..schemas import (
    CreateTeacherRequest,
    ScheduleSlot,
    Teacher,
    TeacherGroupCard,
    TeacherListItem,
    TeacherMonthPoint,
    TeacherProfile,
    UpdateTeacherRequest,
)
from .timetable import _timetable

router = APIRouter(prefix="/teachers", tags=["teachers"], dependencies=[Depends(get_current_user)])


def _clean_phone(phone: str | None) -> str | None:
    return normalize(phone) if phone and phone.strip() else None


@router.get("", response_model=list[TeacherListItem])
async def list_teachers(include_inactive: bool = False):
    where = "" if include_inactive else "where t.is_active"
    rows = await db.pool().fetch(
        f"""
        select t.*,
               count(distinct g.id) filter (where g.is_active) as group_count,
               count(e.id) filter (where g.is_active and e.status = 'active') as student_count
        from teachers t
        left join groups g on g.teacher_id = t.id
        left join enrollments e on e.group_id = g.id
        {where}
        group by t.id
        order by t.full_name asc
        """
    )
    return [TeacherListItem(**row) for row in rows]


@router.post("", response_model=Teacher, status_code=status.HTTP_201_CREATED)
async def create_teacher(payload: CreateTeacherRequest, user: CurrentUser = Depends(get_current_user)):
    name = payload.full_name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    row = await db.pool().fetchrow(
        """
        insert into teachers (full_name, phone, note, created_by)
        values ($1, $2, $3, $4)
        returning *
        """,
        name,
        _clean_phone(payload.phone),
        payload.note,
        user.id,
    )
    return Teacher(**row)


@router.patch("/{teacher_id}", response_model=Teacher)
async def update_teacher(teacher_id: int, payload: UpdateTeacherRequest):
    existing = await db.pool().fetchrow("select * from teachers where id = $1", teacher_id)
    if existing is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")

    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        return Teacher(**existing)
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
    row = await db.pool().fetchrow(
        f"update teachers set {set_clause} where id = $1 returning *", teacher_id, *values
    )
    return Teacher(**row)


def _months_back(month: date, count: int) -> list[date]:
    months = [month]
    for _ in range(count - 1):
        months.insert(0, rules.month_start(months[0] - timedelta(days=1)))
    return months


@router.get("/{teacher_id}/profile", response_model=TeacherProfile)
async def teacher_profile(teacher_id: int, month: date | None = None):
    """The teacher's page: their groups (name, students, days, times), what
    they earn this month, today and tomorrow, and six months of pay. The pay is
    the share of what ALL their groups collected (or their fixed amount), worked
    out by the same calculation as the Finance page, so the two always agree."""
    today = clock.today()
    month = rules.month_start(month or today)
    async with db.pool().acquire() as conn:
        teacher = await conn.fetchrow("select * from teachers where id = $1", teacher_id)
        if teacher is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")

        groups = await conn.fetch(
            """
            select g.id, g.name, g.level, g.capacity, s.name as subject_name,
                   (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as students
            from groups g
            left join subjects s on s.id = g.subject_id
            where g.teacher_id = $1 and g.is_active
            order by g.name
            """,
            teacher_id,
        )
        slots = await schedule.load_slots(conn, group_ids=[g["id"] for g in groups], active_only=False)
        lessons = await _timetable(conn, today, today + timedelta(days=1), teacher_id=teacher_id)

        report = await money.salary_month(conn, month)
        mine = next((t for t in report["teachers"] if t["teacher_id"] == teacher_id), None)

        history = []
        for m in _months_back(month, 6):
            r = report if m == month else await money.salary_month(conn, m)
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
            schedule=[
                ScheduleSlot(weekday=sl.weekday, starts_at=sl.starts_at, ends_at=sl.ends_at, room=sl.room)
                for sl in slots
                if sl.group_id == g["id"]
            ],
        )
        for g in groups
    ]
    return TeacherProfile(
        teacher=Teacher(**teacher),
        salary_method=teacher["salary_method"],
        salary_percent=None if teacher["salary_percent"] is None else float(teacher["salary_percent"]),
        salary_fixed=teacher["salary_fixed"],
        groups=cards,
        student_total=sum(g["students"] for g in groups),
        month=month,
        month_closed=report["closed"],
        collected=mine["collected"] if mine else 0,
        earned=mine["earned"] if mine else 0,
        paid=mine["paid"] if mine else 0,
        remaining=mine["remaining"] if mine else 0,
        lessons=lessons,
        history=history,
    )
