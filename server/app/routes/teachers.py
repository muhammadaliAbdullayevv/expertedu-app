from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from .. import clock, db, schedule
from ..config import settings
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
    TeacherWeek,
    UpdateTeacherRequest,
)
from .groups import _attendance
from .timetable import _timetable

router = APIRouter(prefix="/teachers", tags=["teachers"], dependencies=[Depends(get_current_user)])


def _clean_phone(phone: str | None) -> str | None:
    return normalize(phone) if phone and phone.strip() else None


@router.get("", response_model=list[TeacherListItem])
async def list_teachers(include_inactive: bool = False):
    where = "" if include_inactive else "where t.is_active"
    rows = await db.pool().fetch(
        f"""
        select t.*, count(g.id) filter (where g.is_active) as group_count
        from teachers t
        left join groups g on g.teacher_id = t.id
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


_RECENT_DAYS = 30


def _months_back(month: date, count: int) -> list[date]:
    months = [month]
    for _ in range(count - 1):
        months.insert(0, rules.month_start(months[0] - timedelta(days=1)))
    return months


@router.get("/{teacher_id}/profile", response_model=TeacherProfile)
async def teacher_profile(teacher_id: int, month: date | None = None):
    """The teacher's page: their groups (size, days, times), what the groups
    brought in this month and the teacher's share, how their lessons go, today
    and tomorrow, and the last six months of pay. The pay figures come from
    the same calculation as the Finance page, so the two always agree."""
    today = clock.today()
    month = rules.month_start(month or today)
    async with db.pool().acquire() as conn:
        teacher = await conn.fetchrow("select * from teachers where id = $1", teacher_id)
        if teacher is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")

        groups = await conn.fetch(
            """
            select g.id, g.name, g.level, g.capacity, s.name as subject_name,
                   g.salary_method as g_method, g.salary_percent as g_percent, g.salary_fixed as g_fixed,
                   t.salary_method as t_method, t.salary_percent as t_percent, t.salary_fixed as t_fixed,
                   (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as students
            from groups g
            join teachers t on t.id = g.teacher_id
            left join subjects s on s.id = g.subject_id
            where g.teacher_id = $1 and g.is_active
            order by g.name
            """,
            teacher_id,
        )
        slots = await schedule.load_slots(conn, group_ids=[g["id"] for g in groups], active_only=False)

        report = await money.salary_month(conn, month)
        mine = next((t for t in report["teachers"] if t["teacher_id"] == teacher_id), None)
        lines = mine["lines"] if mine else []

        since = today - timedelta(days=_RECENT_DAYS)
        marks = await conn.fetch(
            """
            select l.group_id, a.status
            from attendance a
            join lessons l on l.id = a.lesson_id
            join enrollments e on e.id = a.enrollment_id
            join groups g on g.id = l.group_id
            where g.teacher_id = $1 and g.is_active and e.status = 'active'
              and (l.starts_at at time zone $2)::date >= $3
            order by l.starts_at, a.id
            """,
            teacher_id,
            settings.center_timezone,
            since,
        )

        monday = today - timedelta(days=today.weekday())
        week_lessons = await _timetable(conn, monday, monday + timedelta(days=6), teacher_id=teacher_id)
        lessons = await _timetable(conn, today, today + timedelta(days=1), teacher_id=teacher_id)

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

    by_group_marks: dict[int, list[str]] = {}
    for m in marks:
        by_group_marks.setdefault(m["group_id"], []).append(m["status"])

    cards = []
    for g in groups:
        method, percent, fixed = money._effective_rule(g)
        own = [line for line in lines if line["group_id"] == g["id"]]
        cards.append(
            TeacherGroupCard(
                group_id=g["id"],
                name=g["name"],
                subject_name=g["subject_name"],
                level=g["level"],
                student_count=g["students"],
                capacity=g["capacity"],
                schedule=[
                    ScheduleSlot(weekday=s.weekday, starts_at=s.starts_at, ends_at=s.ends_at, room=s.room)
                    for s in slots
                    if s.group_id == g["id"]
                ],
                salary_method=method,
                salary_percent=None if percent is None else float(percent),
                salary_fixed=fixed,
                own_rule=g["g_method"] is not None,
                collected=sum(line["collected"] for line in own),
                share=sum(line["share"] for line in own),
                attendance_rate=_attendance(by_group_marks.get(g["id"], [])).rate,
            )
        )

    now = datetime.now(timezone.utc)
    week = TeacherWeek()
    for lesson in week_lessons:
        if lesson.status == "cancelled":
            week.cancelled += 1
            continue
        week.planned += 1
        if lesson.marked_count > 0:
            week.marked += 1
        elif lesson.ends_at <= now:
            week.unmarked_past += 1

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
        attendance=_attendance([m["status"] for m in marks]),
        week=week,
        lessons=lessons,
        history=history,
    )
