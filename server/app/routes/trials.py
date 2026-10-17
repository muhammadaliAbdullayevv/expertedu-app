"""Trial lessons: sessions (a time slot with a teacher, room and seats) and
bookings (one lead's seat in one session).

Nothing here touches enrollments, groups' rosters or transactions -- a lead
at a trial, even as a guest at a regular group's lesson, is never enrolled
and never charged.
"""

from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Header, HTTPException, status

from .. import admissions, db, idempotency, schedule
from ..config import settings
from ..deps import CurrentUser, get_current_user
from ..money import service as money
from ..schemas import (
    CancelRequest,
    CreateTrialBookingRequest,
    CreateTrialSessionRequest,
    RescheduleTrialBookingRequest,
    TrialAttendanceRequest,
    TrialBooking,
    TrialFeedbackRequest,
    TrialSession,
    TrialSessionBooking,
    UpdateTrialSessionRequest,
)

router = APIRouter(tags=["trials"], dependencies=[Depends(get_current_user)])

_MAX_LENGTH = timedelta(hours=8)
_MAX_CAPACITY = 100
# Seats a booking holds: a no-show still took one.
_SEAT_STATUSES = ("scheduled", "attended", "absent")

_SESSION_SELECT = """
select ts.*, s.name as subject_name, g.name as group_name, t.full_name as teacher_name,
       (select count(*) from trial_bookings b
         where b.session_id = ts.id and b.status in ('scheduled', 'attended', 'absent')) as booked
from trial_sessions ts
left join subjects s on s.id = ts.subject_id
left join groups g on g.id = ts.group_id
left join teachers t on t.id = ts.teacher_id
"""


def _local(value: datetime) -> datetime:
    return value.astimezone(ZoneInfo(settings.center_timezone))


def describe_time(starts_at: datetime, ends_at: datetime | None = None) -> str:
    start = _local(starts_at)
    text = start.strftime("%d.%m.%Y %H:%M")
    if ends_at is not None:
        text += _local(ends_at).strftime("–%H:%M")
    return text


async def fetch_sessions(conn, where: str, *args) -> list[TrialSession]:
    rows = await conn.fetch(f"{_SESSION_SELECT} {where} order by ts.starts_at, ts.id", *args)
    if not rows:
        return []
    bookings = await conn.fetch(
        """
        select b.id, b.session_id, b.lead_id, l.full_name as lead_full_name, l.phone as lead_phone,
               b.status, b.feedback
        from trial_bookings b
        join leads l on l.id = b.lead_id
        where b.session_id = any($1::bigint[])
        order by l.full_name, b.id
        """,
        [row["id"] for row in rows],
    )
    by_session: dict[int, list[TrialSessionBooking]] = {}
    for booking in bookings:
        by_session.setdefault(booking["session_id"], []).append(TrialSessionBooking(**booking))
    return [TrialSession(**row, bookings=by_session.get(row["id"], [])) for row in rows]


async def fetch_session(conn, session_id: int) -> TrialSession:
    sessions = await fetch_sessions(conn, "where ts.id = $1", session_id)
    if not sessions:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov darsi topilmadi.")
    return sessions[0]


async def fetch_bookings(conn, where: str, *args) -> list[TrialBooking]:
    rows = await conn.fetch(f"select * from trial_bookings b {where} order by b.created_at, b.id", *args)
    if not rows:
        return []
    sessions = await fetch_sessions(
        conn, "where ts.id = any($1::bigint[])", list({row["session_id"] for row in rows})
    )
    by_id = {session.id: session for session in sessions}
    return [TrialBooking(**row, session=by_id.get(row["session_id"])) for row in rows]


async def fetch_booking(conn, booking_id: int) -> TrialBooking:
    bookings = await fetch_bookings(conn, "where b.id = $1", booking_id)
    if not bookings:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov yozuvi topilmadi.")
    return bookings[0]


async def _check_conflicts(
    conn,
    *,
    starts_at: datetime,
    ends_at: datetime,
    teacher_id: int | None,
    room: str | None,
    group_id: int | None,
    exclude_id: int | None = None,
) -> None:
    """No two scheduled sessions at overlapping times with the same teacher,
    room or group. Checked under one lock for all sessions, so two people
    booking the same teacher at once can't both get through -- (the app's
    database role can't install btree_gist for an exclusion constraint)."""
    await conn.execute("select pg_advisory_xact_lock(hashtext('trial_sessions'))")
    clash = await conn.fetchrow(
        """
        select ts.starts_at, ts.ends_at, ts.teacher_id = $3 as same_teacher,
               ts.group_id = $5 as same_group, t.full_name as teacher_name
        from trial_sessions ts
        left join teachers t on t.id = ts.teacher_id
        where ts.status = 'scheduled'
          and ts.id is distinct from $6
          and ts.starts_at < $2 and ts.ends_at > $1
          and (ts.teacher_id = $3 or lower(ts.room) = lower($4) or ts.group_id = $5)
        order by ts.starts_at
        limit 1
        """,
        starts_at,
        ends_at,
        teacher_id,
        room,
        group_id,
        exclude_id,
    )
    if clash is None:
        # Regular group lessons take teachers and rooms too.
        message = await schedule.regular_lesson_clash(
            conn,
            starts_at=starts_at,
            ends_at=ends_at,
            teacher_id=teacher_id,
            room=room,
            exclude_group_id=group_id,
        )
        if message:
            raise HTTPException(status.HTTP_409_CONFLICT, message)
        return
    when = describe_time(clash["starts_at"], clash["ends_at"])
    if clash["same_teacher"]:
        message = f"O'qituvchi {clash['teacher_name']} bu vaqtda band: {when} sinov darsi."
    elif clash["same_group"]:
        message = f"Bu guruh darsiga {when} uchun sinov allaqachon bor — o'shanga yozing."
    else:
        message = f"\"{room}\" xonasi bu vaqtda band: {when} sinov darsi."
    raise HTTPException(status.HTTP_409_CONFLICT, message)


def _validate_times(starts_at: datetime, ends_at: datetime) -> None:
    if ends_at <= starts_at:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Tugash vaqti boshlanishdan keyin bo'lishi kerak.")
    if ends_at - starts_at > _MAX_LENGTH:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov darsi 8 soatdan uzun bo'lishi mumkin emas.")
    if ends_at <= datetime.now(starts_at.tzinfo):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu vaqt o'tib ketgan.")


def _validate_capacity(capacity: int) -> None:
    if not 1 <= capacity <= _MAX_CAPACITY:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Joylar soni 1 dan 100 gacha bo'lishi kerak.")


async def _require_teacher(conn, teacher_id: int | None) -> None:
    if teacher_id is None:
        return
    active = await conn.fetchval("select is_active from teachers where id = $1", teacher_id)
    if active is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "O'qituvchi topilmadi.")
    if not active:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu o'qituvchi faol emas.")


async def create_session(conn, payload: CreateTrialSessionRequest, user_id: int) -> int:
    if payload.kind not in ("dedicated", "group_lesson"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov turi noto'g'ri.")
    starts_at, ends_at = admissions.aware(payload.starts_at), admissions.aware(payload.ends_at)
    _validate_times(starts_at, ends_at)
    _validate_capacity(payload.capacity)
    room = (payload.room or "").strip() or None

    subject_id, teacher_id, group_id = payload.subject_id, payload.teacher_id, None
    if payload.kind == "group_lesson":
        if payload.group_id is None:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Guruhni tanlang.")
        group = await conn.fetchrow("select * from groups where id = $1", payload.group_id)
        if group is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
        if not group["is_active"]:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu guruh faol emas.")
        group_id = group["id"]
        # A guest at a group's lesson is taught by that group's teacher.
        subject_id = subject_id or group["subject_id"]
        teacher_id = teacher_id or group["teacher_id"]
    if subject_id is not None and not await conn.fetchval("select 1 from subjects where id = $1", subject_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fan topilmadi.")
    await _require_teacher(conn, teacher_id)

    await _check_conflicts(
        conn, starts_at=starts_at, ends_at=ends_at, teacher_id=teacher_id, room=room, group_id=group_id
    )
    return await conn.fetchval(
        """
        insert into trial_sessions
            (kind, subject_id, group_id, teacher_id, room, starts_at, ends_at, capacity, note, created_by)
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        returning id
        """,
        payload.kind,
        subject_id,
        group_id,
        teacher_id,
        room,
        starts_at,
        ends_at,
        payload.capacity,
        (payload.note or "").strip() or None,
        user_id,
    )


async def _session_for(conn, session_id: int | None, session: CreateTrialSessionRequest | None, user_id: int) -> int:
    if (session_id is None) == (session is None):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sinov darsini tanlang yoki yangisini kiriting.")
    if session is not None:
        return await create_session(conn, session, user_id)
    return session_id


async def _check_trial_allowance(conn, lead, user_id: int, is_owner: bool) -> None:
    """A trial lesson is free, and a person gets one (the limit is a
    setting): the same phone counts across subjects. Only the owner may
    book another. Trials that were cancelled, moved or missed don't count;
    moving a booking isn't a new trial at all (the caller skips this)."""
    limit = (await money.get_settings(conn)).trial_limit_per_person
    used = await conn.fetchval(
        """
        select count(*) from trial_bookings b join leads l on l.id = b.lead_id
        where l.phone = $1 and b.status in ('scheduled', 'attended')
        """,
        lead["phone"],
    )
    if used < limit:
        return
    if not is_owner:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN,
            "Bu odam allaqachon sinov darsiga yozilgan. Yana bir sinovni faqat egasi belgilay oladi.",
        )
    await money.audit(
        conn, user_id, "lead", lead["id"], "extra_trial", reason="Egasi qo'shimcha sinovga ruxsat berdi",
        after={"trials_before": used, "limit": limit},
    )


async def book(
    conn, *, lead_id: int, session_id: int, user_id: int, rescheduled_from_id: int | None = None, is_owner: bool = False
) -> int:
    # Session before lead -- the same order cancelling a session locks them in.
    session = await conn.fetchrow("select * from trial_sessions where id = $1 for update", session_id)
    if session is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov darsi topilmadi.")
    if session["status"] == "cancelled":
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu sinov darsi bekor qilingan.")
    if session["ends_at"] <= datetime.now(session["ends_at"].tzinfo):
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu sinov darsi allaqachon tugagan.")

    lead = await admissions.lock_lead(conn, lead_id)
    if lead["stage"] == "enrolled":
        raise HTTPException(status.HTTP_409_CONFLICT, "Bu so'rov bo'yicha o'quvchi allaqachon yozilgan.")
    if lead["stage"] in admissions.CLOSED_STAGES:
        raise HTTPException(status.HTTP_409_CONFLICT, "So'rov yopilgan — avval uni qayta oching.")

    booked_at = await conn.fetchval(
        """
        select ts.starts_at from trial_bookings b join trial_sessions ts on ts.id = b.session_id
        where b.lead_id = $1 and b.status = 'scheduled'
        """,
        lead_id,
    )
    if booked_at is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Bu so'rovda rejalashtirilgan sinov bor: {describe_time(booked_at)}. Uni ko'chiring yoki bekor qiling.",
        )

    if rescheduled_from_id is None:
        await _check_trial_allowance(conn, lead, user_id, is_owner)

    taken = await conn.fetchval(
        "select count(*) from trial_bookings where session_id = $1 and status = any($2::text[])",
        session_id,
        list(_SEAT_STATUSES),
    )
    if taken >= session["capacity"]:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Sinov darsida joy yo'q ({taken}/{session['capacity']}).")

    booking_id = await conn.fetchval(
        """
        insert into trial_bookings (lead_id, session_id, rescheduled_from_id, created_by)
        values ($1, $2, $3, $4)
        returning id
        """,
        lead_id,
        session_id,
        rescheduled_from_id,
        user_id,
    )
    teacher = await conn.fetchval("select full_name from teachers where id = $1", session["teacher_id"])
    details = ", ".join(
        part for part in (describe_time(session["starts_at"], session["ends_at"]), teacher, session["room"]) if part
    )
    verb = "Sinov ko'chirildi" if rescheduled_from_id else "Sinov darsiga yozildi"
    await admissions.log(conn, lead_id, f"{verb}: {details}", user_id=user_id, booking_id=booking_id)
    await admissions.set_stage(conn, lead, "trial_scheduled", user_id=user_id, booking_id=booking_id)
    return booking_id


async def add_trial_reminder(conn, lead_id: int, session_id: int, user_id: int) -> None:
    """A task for the evening before the lesson (or right away if that has passed)."""
    starts_at = await conn.fetchval("select starts_at from trial_sessions where id = $1", session_id)
    tz = ZoneInfo(settings.center_timezone)
    evening_before = datetime.combine(
        (starts_at.astimezone(tz) - timedelta(days=1)).date(), datetime.min.time().replace(hour=18), tz
    )
    due_at = max(evening_before, datetime.now(tz))
    lead = await conn.fetchrow("select * from leads where id = $1", lead_id)
    await admissions.add_task(conn, lead, "Sinov darsi haqida eslatish", due_at, user_id=user_id)


async def _lock_booking(conn, booking_id: int) -> dict:
    booking = await conn.fetchrow("select * from trial_bookings where id = $1 for update", booking_id)
    if booking is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov yozuvi topilmadi.")
    return booking


@router.get("/trial-sessions", response_model=list[TrialSession])
async def list_sessions(date_from: date, date_to: date, include_cancelled: bool = False):
    """Sessions starting on date_from..date_to (inclusive, center days)."""
    if date_to < date_from:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sana oralig'i noto'g'ri.")
    where = "where (ts.starts_at at time zone $1)::date between $2 and $3"
    if not include_cancelled:
        where += " and ts.status = 'scheduled'"
    async with db.pool().acquire() as conn:
        return await fetch_sessions(conn, where, settings.center_timezone, date_from, date_to)


@router.post("/trial-sessions", response_model=TrialSession, status_code=status.HTTP_201_CREATED)
async def create_trial_session(
    payload: CreateTrialSessionRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    async def work(conn):
        return await fetch_session(conn, await create_session(conn, payload, user.id))

    return await idempotency.run(
        key=idempotency_key, user=user, endpoint="POST /trial-sessions", payload=payload, work=work
    )


@router.patch("/trial-sessions/{session_id}", response_model=TrialSession)
async def update_trial_session(
    session_id: int, payload: UpdateTrialSessionRequest, user: CurrentUser = Depends(get_current_user)
):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            session = await conn.fetchrow("select * from trial_sessions where id = $1 for update", session_id)
            if session is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov darsi topilmadi.")
            admissions.check_version(session["version"], payload.version)
            if session["status"] == "cancelled":
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu sinov darsi bekor qilingan.")

            changes = payload.model_dump(exclude_unset=True)
            changes.pop("version")
            starts_at = admissions.aware(changes.get("starts_at") or session["starts_at"])
            ends_at = admissions.aware(changes.get("ends_at") or session["ends_at"])
            teacher_id = changes["teacher_id"] if "teacher_id" in changes else session["teacher_id"]
            room = (changes["room"] or "").strip() or None if "room" in changes else session["room"]
            capacity = changes.get("capacity") or session["capacity"]

            time_changed = starts_at != session["starts_at"] or ends_at != session["ends_at"]
            if time_changed:
                _validate_times(starts_at, ends_at)
            _validate_capacity(capacity)
            await _require_teacher(conn, teacher_id)
            taken = await conn.fetchval(
                "select count(*) from trial_bookings where session_id = $1 and status = any($2::text[])",
                session_id,
                list(_SEAT_STATUSES),
            )
            if capacity < taken:
                raise HTTPException(
                    status.HTTP_409_CONFLICT, f"Bu darsga {taken} kishi yozilgan — joylar undan kam bo'lmasin."
                )
            await _check_conflicts(
                conn,
                starts_at=starts_at,
                ends_at=ends_at,
                teacher_id=teacher_id,
                room=room,
                group_id=session["group_id"],
                exclude_id=session_id,
            )
            await conn.execute(
                """
                update trial_sessions
                set starts_at = $2, ends_at = $3, teacher_id = $4, room = $5, capacity = $6,
                    note = $7, version = version + 1, updated_at = now()
                where id = $1
                """,
                session_id,
                starts_at,
                ends_at,
                teacher_id,
                room,
                capacity,
                changes["note"] if "note" in changes else session["note"],
            )
            if time_changed:
                leads = await conn.fetch(
                    "select id, lead_id from trial_bookings where session_id = $1 and status = 'scheduled'",
                    session_id,
                )
                for row in leads:
                    await admissions.log(
                        conn,
                        row["lead_id"],
                        f"Sinov vaqti o'zgardi: {describe_time(starts_at, ends_at)}",
                        user_id=user.id,
                        booking_id=row["id"],
                    )
            return await fetch_session(conn, session_id)


@router.post("/trial-sessions/{session_id}/cancel", response_model=TrialSession)
async def cancel_trial_session(
    session_id: int, payload: CancelRequest, user: CurrentUser = Depends(get_current_user)
):
    """Cancels the session and every booking in it; each lead goes back to
    'contacted' with a task to agree a new time."""
    reason = (payload.reason or "").strip() or "Sinov darsi bekor qilindi"
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            session = await conn.fetchrow("select * from trial_sessions where id = $1 for update", session_id)
            if session is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Sinov darsi topilmadi.")
            if session["status"] == "scheduled":
                await conn.execute(
                    "update trial_sessions set status = 'cancelled', version = version + 1, updated_at = now() "
                    "where id = $1",
                    session_id,
                )
                bookings = await conn.fetch(
                    "select * from trial_bookings where session_id = $1 and status = 'scheduled' for update",
                    session_id,
                )
                for booking in bookings:
                    await _cancel_booking(conn, booking, reason, user.id)
            return await fetch_session(conn, session_id)


@router.post("/trial-bookings", response_model=TrialBooking, status_code=status.HTTP_201_CREATED)
async def create_trial_booking(
    payload: CreateTrialBookingRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    """Books a lead into a trial -- an existing session, or a new one made
    in the same transaction. Creates no enrollment and no charge."""

    async def work(conn):
        session_id = await _session_for(conn, payload.session_id, payload.session, user.id)
        booking_id = await book(
            conn, lead_id=payload.lead_id, session_id=session_id, user_id=user.id, is_owner=user.role == "owner"
        )
        if payload.remind:
            await add_trial_reminder(conn, payload.lead_id, session_id, user.id)
        return await fetch_booking(conn, booking_id)

    return await idempotency.run(
        key=idempotency_key, user=user, endpoint="POST /trial-bookings", payload=payload, work=work
    )


@router.post("/trial-bookings/{booking_id}/reschedule", response_model=TrialBooking, status_code=status.HTTP_201_CREATED)
async def reschedule_trial_booking(
    booking_id: int,
    payload: RescheduleTrialBookingRequest,
    user: CurrentUser = Depends(get_current_user),
    idempotency_key: UUID | None = Header(default=None),
):
    """Moves a scheduled trial: the old booking is kept as 'rescheduled',
    and the new one points back at it."""

    async def work(conn):
        old = await _lock_booking(conn, booking_id)
        if old["status"] != "scheduled":
            raise HTTPException(status.HTTP_409_CONFLICT, "Faqat rejalashtirilgan sinovni ko'chirish mumkin.")
        await conn.execute(
            "update trial_bookings set status = 'rescheduled', cancel_reason = $2, version = version + 1, "
            "updated_at = now() where id = $1",
            booking_id,
            (payload.reason or "").strip() or None,
        )
        session_id = await _session_for(conn, payload.session_id, payload.session, user.id)
        if session_id == old["session_id"]:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Boshqa vaqtni tanlang.")
        new_id = await book(
            conn, lead_id=old["lead_id"], session_id=session_id, user_id=user.id, rescheduled_from_id=booking_id
        )
        return await fetch_booking(conn, new_id)

    return await idempotency.run(
        key=idempotency_key,
        user=user,
        endpoint=f"POST /trial-bookings/{booking_id}/reschedule",
        payload=payload,
        work=work,
    )


@router.post("/trial-bookings/{booking_id}/attendance", response_model=TrialBooking)
async def mark_trial_attendance(
    booking_id: int, payload: TrialAttendanceRequest, user: CurrentUser = Depends(get_current_user)
):
    """Trial attendance -- stored on the booking only, never in anything
    about regular groups. Can be corrected (attended <-> absent)."""
    if payload.status not in ("attended", "absent"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Davomat holati noto'g'ri.")
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            booking = await _lock_booking(conn, booking_id)
            if booking["status"] not in _SEAT_STATUSES:
                raise HTTPException(status.HTTP_409_CONFLICT, "Bu sinov bekor qilingan yoki ko'chirilgan.")
            if booking["status"] == payload.status:
                return await fetch_booking(conn, booking_id)
            session = await conn.fetchrow("select * from trial_sessions where id = $1", booking["session_id"])
            if session["starts_at"] > datetime.now(session["starts_at"].tzinfo):
                raise HTTPException(status.HTTP_409_CONFLICT, "Dars hali boshlanmagan.")

            await conn.execute(
                """
                update trial_bookings
                set status = $2, attendance_marked_at = now(), attendance_marked_by = $3,
                    feedback = case when $2 = 'attended' then feedback end,
                    recommended_level = case when $2 = 'attended' then recommended_level end,
                    version = version + 1, updated_at = now()
                where id = $1
                """,
                booking_id,
                payload.status,
                user.id,
            )
            lead_id = booking["lead_id"]
            if payload.status == "attended":
                await admissions.log(conn, lead_id, "Sinov darsiga keldi", user_id=user.id, booking_id=booking_id)
                lead = await admissions.lock_lead(conn, lead_id)
                if lead["stage"] in ("new", "contacted", "trial_scheduled", "follow_up_later"):
                    await admissions.set_stage(conn, lead, "trial_completed", user_id=user.id, booking_id=booking_id)
            else:
                await admissions.log(conn, lead_id, "Sinov darsiga kelmadi", user_id=user.id, booking_id=booking_id)
                await admissions.trial_fell_through(
                    conn, lead_id, user_id=user.id, reason="Sinovga kelmadi", booking_id=booking_id
                )
            return await fetch_booking(conn, booking_id)


@router.post("/trial-bookings/{booking_id}/feedback", response_model=TrialBooking)
async def record_trial_feedback(
    booking_id: int, payload: TrialFeedbackRequest, user: CurrentUser = Depends(get_current_user)
):
    feedback = payload.feedback.strip()
    if not feedback:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Fikrni yozing.")
    level = (payload.recommended_level or "").strip() or None
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            booking = await _lock_booking(conn, booking_id)
            if booking["status"] != "attended":
                raise HTTPException(status.HTTP_409_CONFLICT, "Fikr faqat sinovga kelgan o'quvchi uchun yoziladi.")
            await conn.execute(
                """
                update trial_bookings
                set feedback = $2, recommended_level = $3, feedback_at = now(), feedback_by = $4,
                    version = version + 1, updated_at = now()
                where id = $1
                """,
                booking_id,
                feedback,
                level,
                user.id,
            )
            body = f"O'qituvchi fikri: {feedback}"
            if level:
                body += f" (daraja: {level})"
            await admissions.log(conn, booking["lead_id"], body, user_id=user.id, booking_id=booking_id)
            return await fetch_booking(conn, booking_id)


async def _cancel_booking(conn, booking: dict, reason: str, user_id: int) -> None:
    await conn.execute(
        "update trial_bookings set status = 'cancelled', cancel_reason = $2, version = version + 1, "
        "updated_at = now() where id = $1",
        booking["id"],
        reason,
    )
    await admissions.log(conn, booking["lead_id"], f"Sinov bekor qilindi: {reason}", user_id=user_id, booking_id=booking["id"])
    await admissions.trial_fell_through(
        conn, booking["lead_id"], user_id=user_id, reason="Sinov bekor qilindi", booking_id=booking["id"]
    )


@router.post("/trial-bookings/{booking_id}/cancel", response_model=TrialBooking)
async def cancel_trial_booking(booking_id: int, payload: CancelRequest, user: CurrentUser = Depends(get_current_user)):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            booking = await _lock_booking(conn, booking_id)
            if booking["status"] == "cancelled":
                return await fetch_booking(conn, booking_id)
            if booking["status"] != "scheduled":
                raise HTTPException(status.HTTP_409_CONFLICT, "Faqat rejalashtirilgan sinovni bekor qilish mumkin.")
            await _cancel_booking(conn, booking, (payload.reason or "").strip() or "Sabab ko'rsatilmagan", user.id)
            return await fetch_booking(conn, booking_id)
