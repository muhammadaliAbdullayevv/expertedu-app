"""Group schedules, the timetable, and attendance. See app/schedule.py
for how lessons come from the weekly slots."""

from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, status

from .. import admissions, db, schedule
from ..config import settings
from ..deps import CurrentUser, Scope, get_current_user, get_scope
from ..scope import branch_filter, require_group
from ..schemas import (
    AttendanceReportRow,
    AttendanceSheet,
    CreateExtraLessonRequest,
    GroupSchedule,
    LessonRef,
    MarkAttendanceRequest,
    ScheduleSlot,
    SetGroupScheduleRequest,
    SheetStudent,
    SheetTrialGuest,
    TimetableLesson,
)

router = APIRouter(tags=["timetable"], dependencies=[Depends(get_current_user)])

_STATUSES = ("present", "late", "absent", "excused")
_MAX_RANGE = timedelta(days=62)


async def _group(conn, scope: Scope, group_id: int, *, lock: bool = False) -> dict:
    """The group, or 404 when it is not in the scope."""
    row = await conn.fetchrow(
        f"""
        select g.*, s.name as subject_name, t.full_name as teacher_name
        from groups g
        left join subjects s on s.id = g.subject_id
        left join teachers t on t.id = g.teacher_id
        where g.id = $1 and {branch_filter('g.branch_id', 2)} {"for update of g" if lock else ""}
        """,
        group_id,
        scope.ids,
    )
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
    return dict(row)


# --- Weekly schedule ---------------------------------------------------------


@router.get("/groups/{group_id}/schedule", response_model=GroupSchedule)
async def get_group_schedule(group_id: int, scope: Scope = Depends(get_scope)):
    async with db.pool().acquire() as conn:
        await _group(conn, scope, group_id)
        slots = await schedule.load_slots(conn, group_ids=[group_id], active_only=False)
    return GroupSchedule(
        group_id=group_id,
        slots=[ScheduleSlot(weekday=s.weekday, starts_at=s.starts_at, ends_at=s.ends_at, room=s.room) for s in slots],
    )


@router.put("/groups/{group_id}/schedule", response_model=GroupSchedule)
async def set_group_schedule(group_id: int, payload: SetGroupScheduleRequest, scope: Scope = Depends(get_scope)):
    """Replaces the group's weekly slots. Lessons already marked or
    cancelled keep their own times; only the future follows the new ones."""
    slots = []
    for item in payload.slots:
        if not 1 <= item.weekday <= 7:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hafta kuni noto'g'ri.")
        room = (item.room or "").strip() or None
        slots.append(schedule.Slot(group_id, item.weekday, item.starts_at, item.ends_at, room))
    schedule.validate_own_slots(slots)

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            group = await _group(conn, scope, group_id, lock=True)
            if group["is_active"]:
                await schedule.check_clashes(conn, group_id=group_id, teacher_id=group["teacher_id"], slots=slots)
            await conn.execute("delete from group_schedules where group_id = $1", group_id)
            for slot in slots:
                await conn.execute(
                    "insert into group_schedules (group_id, weekday, starts_at, ends_at, room) "
                    "values ($1, $2, $3, $4, $5)",
                    group_id,
                    slot.weekday,
                    slot.starts_at,
                    slot.ends_at,
                    slot.room,
                )
    return await get_group_schedule(group_id, scope)


# --- Timetable -----------------------------------------------------------------


def _day(value: datetime) -> date:
    return schedule.local(value).date()


async def _timetable(
    conn,
    date_from: date,
    date_to: date,
    *,
    group_id: int | None = None,
    teacher_id: int | None = None,
    ids: list[int] | None = None,
) -> list[TimetableLesson]:
    """`ids` are the branches in scope (None = all): only their groups' lessons."""
    group_filter = [group_id] if group_id is not None else None
    in_scope = None
    if ids is not None:
        in_scope = [r["id"] for r in await conn.fetch(f"select g.id from groups g where {branch_filter('g.branch_id', 1)}", ids)]
        group_filter = in_scope if group_id is None else [group_id] if group_id in in_scope else []
    slots = await schedule.load_slots(conn, group_ids=group_filter)
    tz = settings.center_timezone
    lesson_rows = await conn.fetch(
        """
        select l.*,
               count(a.id) as marked_count,
               count(a.id) filter (where a.status in ('present', 'late')) as present_count
        from lessons l
        left join attendance a on a.lesson_id = l.id
        where (l.starts_at at time zone $1)::date between $2 and $3
          and ($4::bigint is null or l.group_id = $4)
          and ($5::bigint[] is null or l.group_id = any($5::bigint[]))
        group by l.id
        """,
        tz,
        date_from,
        date_to,
        group_id,
        in_scope,
    )
    by_key = {(row["group_id"], row["starts_at"]): row for row in lesson_rows}

    entries: list[tuple[int, datetime, datetime, str | None, dict | None]] = []
    for occ in schedule.occurrences(slots, date_from, date_to):
        row = by_key.pop((occ.slot.group_id, occ.starts_at), None)
        entries.append((occ.slot.group_id, occ.starts_at, occ.ends_at, occ.slot.room, row))
    # Lessons with a row but no slot (any more): extra ones, and lessons
    # whose slot was moved after they were marked or cancelled.
    for row in by_key.values():
        entries.append((row["group_id"], row["starts_at"], row["ends_at"], row["room"], row))

    group_ids = sorted({entry[0] for entry in entries})
    groups = {
        row["id"]: row
        for row in await conn.fetch(
            """
            select g.id, g.name, g.teacher_id, s.name as subject_name, t.full_name as teacher_name
            from groups g
            left join subjects s on s.id = g.subject_id
            left join teachers t on t.id = g.teacher_id
            where g.id = any($1::bigint[])
            """,
            group_ids,
        )
    }
    enrollments = await conn.fetch(
        "select group_id, joined_at, ended_at from enrollments where group_id = any($1::bigint[])", group_ids
    )
    teacher_names = {
        row["id"]: row["full_name"]
        for row in await conn.fetch(
            "select id, full_name from teachers where id = any($1::bigint[])",
            [row["teacher_id"] for row in lesson_rows if row["teacher_id"] is not None],
        )
    }

    result: list[TimetableLesson] = []
    for gid, starts_at, ends_at, room, row in entries:
        group = groups[gid]
        lesson_teacher = row["teacher_id"] if row is not None and row["teacher_id"] is not None else None
        tid = lesson_teacher if lesson_teacher is not None else group["teacher_id"]
        if teacher_id is not None and tid != teacher_id:
            continue
        day = _day(starts_at)
        students = sum(
            1
            for e in enrollments
            if e["group_id"] == gid and e["joined_at"] <= day and (e["ended_at"] is None or e["ended_at"] > day)
        )
        result.append(
            TimetableLesson(
                group_id=gid,
                group_name=group["name"],
                subject_name=group["subject_name"],
                teacher_id=tid,
                teacher_name=teacher_names.get(tid) if lesson_teacher is not None else group["teacher_name"],
                room=row["room"] if row is not None else room,
                starts_at=starts_at,
                ends_at=row["ends_at"] if row is not None else ends_at,
                lesson_id=row["id"] if row is not None else None,
                status="cancelled" if row is not None and row["status"] == "cancelled" else "scheduled",
                cancel_reason=row["cancel_reason"] if row is not None else None,
                is_extra=row["is_extra"] if row is not None else False,
                student_count=students,
                marked_count=row["marked_count"] if row is not None else 0,
                present_count=row["present_count"] if row is not None else 0,
            )
        )
    result.sort(key=lambda lesson: (lesson.starts_at, lesson.group_name))
    return result


def _check_range(date_from: date, date_to: date) -> None:
    if date_to < date_from:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sana oralig'i noto'g'ri.")
    if date_to - date_from > _MAX_RANGE:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Oraliq 2 oydan oshmasin.")


@router.get("/timetable", response_model=list[TimetableLesson])
async def get_timetable(
    date_from: date,
    date_to: date,
    group_id: int | None = None,
    teacher_id: int | None = None,
    scope: Scope = Depends(get_scope),
):
    """Lessons on date_from..date_to (inclusive, center days)."""
    _check_range(date_from, date_to)
    async with db.pool().acquire() as conn:
        return await _timetable(conn, date_from, date_to, group_id=group_id, teacher_id=teacher_id, ids=scope.ids)


async def _find_lesson(conn, group_id: int, starts_at: datetime) -> TimetableLesson:
    """The lesson of [group_id] starting at [starts_at] -- from the
    schedule or an existing row; 404 if the group has none then."""
    starts_at = admissions.aware(starts_at)
    day = _day(starts_at)
    for lesson in await _timetable(conn, day, day, group_id=group_id):
        if lesson.starts_at == starts_at:
            return lesson
    raise HTTPException(status.HTTP_404_NOT_FOUND, "Bu vaqtda guruhning darsi yo'q.")


async def _ensure_row(conn, lesson: TimetableLesson, user_id: int) -> int:
    """The lesson's row, created (as of now: teacher, room, times) the
    first time it's needed."""
    if lesson.lesson_id is not None:
        return lesson.lesson_id
    return await conn.fetchval(
        """
        insert into lessons (group_id, starts_at, ends_at, room, teacher_id, created_by)
        values ($1, $2, $3, $4, $5, $6)
        on conflict (group_id, starts_at) do update set updated_at = now()
        returning id
        """,
        lesson.group_id,
        lesson.starts_at,
        lesson.ends_at,
        lesson.room,
        lesson.teacher_id,
        user_id,
    )


@router.get("/lessons/sheet", response_model=AttendanceSheet)
async def get_attendance_sheet(group_id: int, starts_at: datetime, scope: Scope = Depends(get_scope)):
    """The class list for one lesson, with any marks already made, and the
    trial guests booked into it (their attendance is kept on the trial)."""
    async with db.pool().acquire() as conn:
        await _group(conn, scope, group_id)
        lesson = await _find_lesson(conn, group_id, starts_at)
        students = {s["enrollment_id"]: s for s in await schedule.roster(conn, group_id, _day(lesson.starts_at))}
        if lesson.lesson_id is not None:
            marks = await conn.fetch(
                """
                select a.enrollment_id, a.status, a.note, s.id as student_id, s.full_name, s.phone
                from attendance a
                join enrollments e on e.id = a.enrollment_id
                join students s on s.id = e.student_id
                where a.lesson_id = $1
                """,
                lesson.lesson_id,
            )
            for mark in marks:
                students[mark["enrollment_id"]] = dict(mark)
        guests = await conn.fetch(
            """
            select b.id as booking_id, b.lead_id, l.full_name, b.status
            from trial_bookings b
            join trial_sessions ts on ts.id = b.session_id
            join leads l on l.id = b.lead_id
            where ts.group_id = $1 and ts.status = 'scheduled'
              and ts.starts_at < $3 and ts.ends_at > $2
              and b.status not in ('cancelled', 'rescheduled')
            order by l.full_name
            """,
            group_id,
            lesson.starts_at,
            lesson.ends_at,
        )
    return AttendanceSheet(
        lesson=lesson,
        students=sorted((SheetStudent(**s) for s in students.values()), key=lambda s: s.full_name),
        trial_guests=[SheetTrialGuest(**row) for row in guests],
    )


@router.put("/lessons/attendance", response_model=AttendanceSheet)
async def mark_attendance(
    payload: MarkAttendanceRequest, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    """Saves marks for one lesson (creating its row the first time).
    Re-sending the same marks changes nothing; a later mark for the same
    student replaces the earlier one."""
    for mark in payload.marks:
        if mark.status not in _STATUSES:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Davomat holati noto'g'ri.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _group(conn, scope, payload.group_id, lock=True)
            lesson = await _find_lesson(conn, payload.group_id, payload.starts_at)
            if lesson.status == "cancelled":
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu dars bekor qilingan.")
            if lesson.starts_at > datetime.now(lesson.starts_at.tzinfo):
                raise HTTPException(status.HTTP_409_CONFLICT, "Dars hali boshlanmagan.")
            allowed = {s["enrollment_id"] for s in await schedule.roster(conn, payload.group_id, _day(lesson.starts_at))}
            lesson_id = await _ensure_row(conn, lesson, user.id)
            already = {
                row["enrollment_id"]
                for row in await conn.fetch("select enrollment_id from attendance where lesson_id = $1", lesson_id)
            }
            for mark in payload.marks:
                if mark.enrollment_id not in allowed and mark.enrollment_id not in already:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu o'quvchi o'sha kuni guruhda emas edi.")
                await conn.execute(
                    """
                    insert into attendance (lesson_id, enrollment_id, status, note, marked_by)
                    values ($1, $2, $3, $4, $5)
                    on conflict (lesson_id, enrollment_id) do update
                    set status = excluded.status, note = excluded.note,
                        marked_by = excluded.marked_by, marked_at = now()
                    """,
                    lesson_id,
                    mark.enrollment_id,
                    mark.status,
                    (mark.note or "").strip() or None,
                    user.id,
                )
    return await get_attendance_sheet(payload.group_id, lesson.starts_at, scope)


@router.post("/lessons/cancel", response_model=TimetableLesson)
async def cancel_lesson(
    payload: LessonRef, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    """The lesson doesn't take place (holiday, teacher ill). Not allowed
    once attendance has been marked for it."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _group(conn, scope, payload.group_id, lock=True)
            lesson = await _find_lesson(conn, payload.group_id, payload.starts_at)
            if lesson.marked_count:
                raise HTTPException(status.HTTP_409_CONFLICT, "Davomat belgilangan darsni bekor qilib bo'lmaydi.")
            lesson_id = await _ensure_row(conn, lesson, user.id)
            await conn.execute(
                "update lessons set status = 'cancelled', cancel_reason = $2, updated_at = now() where id = $1",
                lesson_id,
                (payload.reason or "").strip() or None,
            )
            return await _find_lesson(conn, payload.group_id, lesson.starts_at)


@router.post("/lessons/restore", response_model=TimetableLesson)
async def restore_lesson(payload: LessonRef, scope: Scope = Depends(get_scope)):
    """Undoes a cancellation."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            await _group(conn, scope, payload.group_id, lock=True)
            lesson = await _find_lesson(conn, payload.group_id, payload.starts_at)
            if lesson.status == "cancelled":
                await conn.execute(
                    "update lessons set status = 'active', cancel_reason = null, updated_at = now() where id = $1",
                    lesson.lesson_id,
                )
            return await _find_lesson(conn, payload.group_id, lesson.starts_at)


@router.post("/lessons", response_model=TimetableLesson, status_code=status.HTTP_201_CREATED)
async def create_extra_lesson(
    payload: CreateExtraLessonRequest, user: CurrentUser = Depends(get_current_user), scope: Scope = Depends(get_scope)
):
    """A lesson outside the weekly schedule (a make-up, an exam)."""
    starts_at, ends_at = admissions.aware(payload.starts_at), admissions.aware(payload.ends_at)
    if ends_at <= starts_at or ends_at - starts_at > timedelta(hours=8):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Dars vaqti noto'g'ri.")
    room = (payload.room or "").strip() or None
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            group = await _group(conn, scope, payload.group_id, lock=True)
            if not group["is_active"]:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu guruh faol emas.")
            day = _day(starts_at)
            for existing in await _timetable(conn, day, day, group_id=payload.group_id):
                if existing.starts_at < ends_at and existing.ends_at > starts_at:
                    raise HTTPException(status.HTTP_409_CONFLICT, "Bu guruhning shu vaqtda darsi bor.")
            clash = await schedule.regular_lesson_clash(
                conn,
                starts_at=starts_at,
                ends_at=ends_at,
                teacher_id=group["teacher_id"],
                room=room,
                exclude_group_id=payload.group_id,
            )
            if clash:
                raise HTTPException(status.HTTP_409_CONFLICT, clash)
            await conn.execute(
                """
                insert into lessons (group_id, starts_at, ends_at, room, teacher_id, is_extra, note, created_by)
                values ($1, $2, $3, $4, $5, true, $6, $7)
                """,
                payload.group_id,
                starts_at,
                ends_at,
                room,
                group["teacher_id"],
                (payload.note or "").strip() or None,
                user.id,
            )
            return await _find_lesson(conn, payload.group_id, starts_at)


@router.get("/attendance/report", response_model=list[AttendanceReportRow])
async def attendance_report(
    date_from: date, date_to: date, group_id: int | None = None, scope: Scope = Depends(get_scope)
):
    """Per student and group: marked lessons on date_from..date_to and how
    they went -- most absences first."""
    _check_range(date_from, date_to)
    rows = await db.pool().fetch(
        """
        select e.id as enrollment_id, s.id as student_id, s.full_name, s.phone,
               g.id as group_id, g.name as group_name,
               count(*) as lessons,
               count(*) filter (where a.status = 'present') as present,
               count(*) filter (where a.status = 'late') as late,
               count(*) filter (where a.status = 'absent') as absent,
               count(*) filter (where a.status = 'excused') as excused
        from attendance a
        join lessons l on l.id = a.lesson_id
        join enrollments e on e.id = a.enrollment_id
        join students s on s.id = e.student_id
        join groups g on g.id = e.group_id
        where l.status = 'active'
          and (l.starts_at at time zone $1)::date between $2 and $3
          and ($4::bigint is null or g.id = $4)
          and ($5::bigint[] is null or g.branch_id = any($5::bigint[]))
        group by e.id, s.id, g.id
        order by count(*) filter (where a.status = 'absent') desc, s.full_name
        """,
        settings.center_timezone,
        date_from,
        date_to,
        group_id,
        scope.ids,
    )
    return [
        AttendanceReportRow(
            **row,
            rate=round((row["present"] + row["late"]) / row["lessons"], 4) if row["lessons"] else None,
        )
        for row in rows
    ]
