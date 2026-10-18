from fastapi import APIRouter, Depends, HTTPException, status

from datetime import datetime, timedelta

from .. import admissions, clock, course_finder, db, schedule
from ..deps import CurrentUser, Scope, get_current_user, get_scope
from ..money import rules, service as money
from ..scope import branch_filter, link_teacher, require_group, require_teacher as scoped_teacher, teacher_filter
from ..schemas import (
    CreateGroupRequest,
    Group,
    GroupListItem,
    GroupMatch,
    GroupProfile,
    GroupSearchResult,
    GroupTeacher,
    GroupWaiting,
    ProfileAttendance,
    RosterEntry,
    ScheduleSlot,
    TrialDate,
    UpdateGroupRequest,
)

router = APIRouter(prefix="/groups", tags=["groups"], dependencies=[Depends(get_current_user)])

# Every single-group read goes through here, so teacher_name is always the
# linked teacher's current name -- groups no longer store one of their own.
_GROUP_SELECT = """
select g.*, t.full_name as teacher_name, b.name as branch_name
from groups g
left join teachers t on t.id = g.teacher_id
left join branches b on b.id = g.branch_id
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


async def _require_teacher(teacher_id: int, branch_id: int) -> None:
    """The teacher must work in the group's branch."""
    await scoped_teacher(db.pool(), Scope(None, [branch_id], branch_id), teacher_id)


async def _teacher_id_for_name(name: str, user_id: int, branch_id: int) -> int | None:
    """Matches a typed teacher name (case-insensitively) to an existing
    teacher, creating one if there's none -- how groups created from older
    app builds, which only send a name, still end up linked to a record."""
    name = name.strip()
    if not name:
        return None
    existing = await db.pool().fetchval(
        f"select t.id from teachers t where lower(t.full_name) = lower($1) and {teacher_filter('t', 2)} "
        "order by t.is_active desc, t.id limit 1",
        name,
        [branch_id],
    )
    if existing:
        return existing
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            teacher_id = await conn.fetchval(
                "insert into teachers (full_name, created_by) values ($1, $2) returning id", name, user_id
            )
            await link_teacher(conn, teacher_id, branch_id)
    return teacher_id


async def _fetch_group(group_id: int, scope: Scope) -> Group:
    row = await db.pool().fetchrow(
        f"{_GROUP_SELECT} where g.id = $1 and {branch_filter('g.branch_id', 2)}", group_id, scope.ids
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    return Group(**row)


@router.get("", response_model=list[GroupListItem])
async def list_groups(include_inactive: bool = False, scope: Scope = Depends(get_scope)):
    where = branch_filter("g.branch_id", 1) + ("" if include_inactive else " and g.is_active")
    rows = await db.pool().fetch(
        f"""
        select g.*, t.full_name as teacher_name, s.name as subject_name, b.name as branch_name,
               count(e.id) filter (where e.status = 'active') as student_count
        from groups g
        left join teachers t on t.id = g.teacher_id
        left join subjects s on s.id = g.subject_id
        left join branches b on b.id = g.branch_id
        left join enrollments e on e.group_id = g.id
        where {where}
        group by g.id, t.full_name, s.name, b.name
        order by g.name asc
        """,
        scope.ids,
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
async def create_group(
    payload: CreateGroupRequest, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    _validate(name=payload.name, fee_amount=payload.fee_amount, capacity=payload.capacity)
    billing_mode, billing_day = _billing(payload.billing_mode, payload.billing_day, payload.due_day)
    await _require_subject(payload.subject_id)

    branch_id = scope.write_branch()
    teacher_id = payload.teacher_id
    if teacher_id is not None:
        await _require_teacher(teacher_id, branch_id)
    elif payload.teacher_name:
        teacher_id = await _teacher_id_for_name(payload.teacher_name, user.id, branch_id)

    group_id = await db.pool().fetchval(
        """
        insert into groups (subject_id, name, teacher_id, fee_amount, billing_mode, billing_day,
                            prorate_first_period, capacity, note, created_by, level, start_date, branch_id)
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
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
        (payload.level or "").strip() or None,
        payload.start_date,
        branch_id,
    )
    return await _fetch_group(group_id, scope)


# The two routes below are declared before "/{group_id}" so "search" and
# "levels" aren't read as ids.
@router.get("/search", response_model=GroupSearchResult)
async def search_groups(
    subject_id: int | None = None,
    level: str | None = None,
    weekdays: str | None = None,
    time_of_day: str | None = None,
    scope: Scope = Depends(get_scope),
):
    """Kurs qidirish: groups that fit what a client asked for -- exact
    matches (all the group's days suit them) and near ones (some do). See
    app/course_finder.py."""
    wanted = None
    if weekdays:
        try:
            wanted = {int(d) for d in weekdays.split(",") if d}
        except ValueError:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hafta kunlari noto'g'ri.")
        if any(not 1 <= d <= 7 for d in wanted):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hafta kunlari 1 dan 7 gacha bo'lishi kerak.")
    if time_of_day is not None and time_of_day not in course_finder.TIME_OF_DAY:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Vaqt noto'g'ri.")
    async with db.pool().acquire() as conn:
        found = await course_finder.search(
            conn, subject_id=subject_id, level=level, weekdays=wanted, time_of_day=time_of_day,
            branch_ids=scope.ids,
        )
    return GroupSearchResult(
        exact=[GroupMatch(**item) for item in found["exact"]],
        near=[GroupMatch(**item) for item in found["near"]],
    )


@router.get("/levels", response_model=list[str])
async def group_levels(subject_id: int | None = None, scope: Scope = Depends(get_scope)):
    """The levels the active groups of a subject have, for the finder's chips."""
    rows = await db.pool().fetch(
        f"select distinct level from groups g where g.is_active and g.level is not null "
        f"and ($1::bigint is null or g.subject_id = $1) and {branch_filter('g.branch_id', 2)} order by level",
        subject_id,
        scope.ids,
    )
    return [row["level"] for row in rows]


@router.get("/{group_id}/trial-dates", response_model=list[TrialDate])
async def trial_dates(group_id: int, count: int = 3, scope: Scope = Depends(get_scope)):
    """The group's next lessons a guest could come to as a trial (cancelled
    lessons left out), with the guest session already opened for each."""
    if not 1 <= count <= 10:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Soni 1 dan 10 gacha bo'lsin.")
    async with db.pool().acquire() as conn:
        await require_group(conn, scope, group_id)
        return await upcoming_trial_dates(conn, group_id, count)


async def upcoming_trial_dates(conn, group_id: int, count: int) -> list[TrialDate]:
    group = await conn.fetchrow("select * from groups where id = $1", group_id)
    if group is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    slots = await schedule.load_slots(conn, group_ids=[group_id])
    now = datetime.now(schedule.center_tz())
    cancelled = {
        row["starts_at"]
        for row in await conn.fetch(
            "select starts_at from lessons where group_id = $1 and status = 'cancelled' and starts_at > now()",
            group_id,
        )
    }
    upcoming = [
        o
        for o in schedule.occurrences(slots, now.date(), now.date() + timedelta(days=60))
        if o.starts_at > now and o.starts_at not in cancelled
    ][:count]
    enrolled = await conn.fetchval(
        "select count(*) from enrollments where group_id = $1 and status = 'active'", group_id
    )
    free = None if group["capacity"] is None else max(group["capacity"] - enrolled, 0)
    result = []
    for o in upcoming:
        session = await conn.fetchrow(
            """
            select ts.id, ts.capacity,
                   (select count(*) from trial_bookings b where b.session_id = ts.id
                      and b.status in ('scheduled', 'attended', 'absent')) as booked
            from trial_sessions ts
            where ts.group_id = $1 and ts.starts_at = $2 and ts.status = 'scheduled'
            """,
            group_id,
            o.starts_at,
        )
        result.append(
            TrialDate(
                starts_at=o.starts_at,
                ends_at=o.ends_at,
                room=o.slot.room,
                trial_session_id=session["id"] if session and session["booked"] < session["capacity"] else None,
                guests_booked=session["booked"] if session else 0,
                session_full=bool(session and session["booked"] >= session["capacity"]),
                free_seats=free,
                suggested_capacity=max(1, free if free is not None else 3),
            )
        )
    return result


def _attendance(marks: list[str]) -> ProfileAttendance:
    counts = {key: marks.count(key) for key in ("present", "late", "absent", "excused")}
    expected = len(marks) - counts["excused"]
    came = counts["present"] + counts["late"]
    return ProfileAttendance(
        **counts, total=len(marks), rate=round(came / expected, 4) if expected else None, recent=marks[-10:]
    )


@router.get("/{group_id}/profile", response_model=GroupProfile)
async def group_profile(group_id: int, scope: Scope = Depends(get_scope)):
    """The group's profile page: teacher, students, who paid, attendance, days
    and times, billing day, and what was collected of what was expected."""
    group = await _fetch_group(group_id, scope)
    today = clock.today()
    async with db.pool().acquire() as conn:
        subject_name = await conn.fetchval("select name from subjects where id = $1", group.subject_id)
        teacher = None
        if group.teacher_id is not None:
            row = await conn.fetchrow("select id, full_name, phone, photo from teachers where id = $1", group.teacher_id)
            teacher = GroupTeacher(**row) if row else None
        slots = await schedule.load_slots(conn, group_ids=[group_id], active_only=False)
        people = await conn.fetchrow(
            """
            select count(*) as students,
                   count(*) filter (where eb.owed > 0) as unpaid
            from enrollments e join enrollment_balances eb on eb.enrollment_id = e.id
            where e.group_id = $1 and e.status = 'active'
            """,
            group_id,
        )
        marks = await conn.fetch(
            """
            select a.status from attendance a join lessons l on l.id = a.lesson_id
            join enrollments e on e.id = a.enrollment_id
            where l.group_id = $1 and e.status = 'active' order by l.starts_at, a.id
            """,
            group_id,
        )
        money_row = await conn.fetchrow(
            """
            select coalesce(sum(cb.amount) filter (where cb.status = 'active'
                              and cb.period_start <= $2 and $2 < cb.period_end), 0) as expected,
                   coalesce(sum(cb.paid) filter (where cb.status = 'active'
                              and cb.period_start <= $2 and $2 < cb.period_end), 0) as collected,
                   coalesce(sum(cb.owed) filter (where cb.status = 'active' and cb.owed > 0), 0) as debt
            from charge_balances cb join enrollments e on e.id = cb.enrollment_id
            where cb.group_id = $1 and e.status = 'active'
            """,
            group_id,
            today,
        )
        waiting = await conn.fetch(
            f"{admissions.LEAD_SELECT} where l.group_id = $1 and l.stage = any($2::text[]) "
            "order by l.created_at desc limit 50",
            group_id,
            list(admissions.OPEN_STAGES),
        )
        lessons = await upcoming_trial_dates(conn, group_id, 3)
    next_billing = None
    if group.billing_mode == "fixed_day":
        next_billing = rules.next_due_date(
            group.billing_mode, group.billing_day, today - timedelta(days=400), today, None, group.prorate_first_period
        )
    students = people["students"]
    return GroupProfile(
        group=group,
        subject_name=subject_name,
        teacher=teacher,
        schedule=[ScheduleSlot(weekday=s.weekday, starts_at=s.starts_at, ends_at=s.ends_at, room=s.room) for s in slots],
        student_count=students,
        capacity=group.capacity,
        free_seats=None if group.capacity is None else max(group.capacity - students, 0),
        paid_count=students - people["unpaid"],
        unpaid_count=people["unpaid"],
        attendance=_attendance([m["status"] for m in marks]),
        expected=money_row["expected"],
        collected=money_row["collected"],
        debt_total=money_row["debt"],
        next_billing_date=next_billing,
        next_lessons=[lesson.starts_at for lesson in lessons],
        waiting=[
            GroupWaiting(
                lead_id=r["id"], full_name=r["full_name"], phone=r["phone"], created_at=r["created_at"],
                trial_at=r["next_trial_at"],
            )
            for r in waiting
        ],
    )


@router.get("/{group_id}", response_model=Group)
async def get_group(group_id: int, scope: Scope = Depends(get_scope)):
    return await _fetch_group(group_id, scope)


@router.patch("/{group_id}", response_model=Group)
async def update_group(group_id: int, payload: UpdateGroupRequest, scope: Scope = Depends(get_scope)):
    existing = await _fetch_group(group_id, scope)

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
    if "level" in updates:
        updates["level"] = (updates["level"] or "").strip() or None
    if updates.get("subject_id") is not None:
        await _require_subject(updates["subject_id"])
    if updates.get("teacher_id") is not None:
        await _require_teacher(updates["teacher_id"], existing.branch_id)

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
    return await _fetch_group(group_id, scope)


@router.get("/{group_id}/roster", response_model=list[RosterEntry])
async def get_roster(group_id: int, include_withdrawn: bool = False, scope: Scope = Depends(get_scope)):
    await require_group(db.pool(), scope, group_id)
    where = "" if include_withdrawn else "and e.status = 'active'"
    rows = await db.pool().fetch(
        f"""
        select e.id as enrollment_id, e.student_id, s.full_name as student_full_name,
               s.phone as student_phone, s.photo as student_photo, e.joined_at, e.status, eb.owed as balance,
               e.joined_at > current_date - 14 as is_new
        from enrollments e
        join students s on s.id = e.student_id
        join enrollment_balances eb on eb.enrollment_id = e.id
        where e.group_id = $1 {where}
        order by (e.joined_at > current_date - 14) desc, e.joined_at desc, s.full_name asc
        """,
        group_id,
    )
    due = await money.next_due_dates(db.pool(), [row["enrollment_id"] for row in rows])
    return [RosterEntry(**row, next_due_date=due.get(row["enrollment_id"])) for row in rows]
