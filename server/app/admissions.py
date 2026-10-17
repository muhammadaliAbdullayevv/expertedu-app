"""Lead rules shared by the lead, trial and follow-up routes.

Stages:

    new -> contacted -> trial_scheduled -> trial_completed -> decision_pending -> enrolled

plus follow_up_later (still open, with a call-back task) and the two
closed outcomes, not_interested and unreachable. A no-show or a cancelled
trial is a booking status, not a lead stage: the lead goes back to
'contacted' with a follow-up task, and stays open.

Only the server moves a lead into trial_scheduled / trial_completed (from
bookings and attendance) and enrolled (from POST /leads/{id}/enroll). Every
change is logged to lead_interactions as a 'system' row.
"""

from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status

from . import clock
from .config import settings

OPEN_STAGES = (
    "new",
    "contacted",
    "trial_scheduled",
    "trial_completed",
    "decision_pending",
    "follow_up_later",
)
CLOSED_STAGES = ("not_interested", "unreachable")
ALL_STAGES = (*OPEN_STAGES, "enrolled", *CLOSED_STAGES)

# What an operator may pick by hand. The rest follow from trials and
# enrollment, so the board can't claim a trial that isn't booked.
MANUAL_STAGES = ("contacted", "decision_pending", "follow_up_later", "not_interested", "unreachable")

STAGE_LABELS = {
    "new": "Yangi",
    "contacted": "Bog'lanildi",
    "trial_scheduled": "Sinov rejalashtirildi",
    "trial_completed": "Sinov o'tdi",
    "decision_pending": "Qaror kutilmoqda",
    "follow_up_later": "Keyinroq bog'lanish",
    "enrolled": "O'quvchi bo'ldi",
    "not_interested": "Qiziqmadi",
    "unreachable": "Bog'lanib bo'lmadi",
}

SOURCES = ("instagram", "telegram", "referral", "walk_in", "other")
INTERACTION_KINDS = ("call_in", "call_out", "sms", "telegram", "visit", "note")

LEAD_SELECT = """
select l.*, s.name as subject_name, u.full_name as assigned_to_name,
       nt.starts_at as next_trial_at, nt.booking_id as next_trial_booking_id,
       ft.due_at as next_task_due_at, lc.last_at as last_contact_at
from leads l
left join subjects s on s.id = l.subject_id
left join users u on u.id = l.assigned_to
left join lateral (
  select b.id as booking_id, ts.starts_at
  from trial_bookings b join trial_sessions ts on ts.id = b.session_id
  where b.lead_id = l.id and b.status = 'scheduled'
  limit 1
) nt on true
left join lateral (
  select min(due_at) as due_at from follow_up_tasks where lead_id = l.id and status = 'open'
) ft on true
left join lateral (
  select max(created_at) as last_at from lead_interactions where lead_id = l.id and kind <> 'system'
) lc on true
"""


def stale_version() -> HTTPException:
    return HTTPException(
        status.HTTP_409_CONFLICT,
        "Bu ma'lumotni boshqa foydalanuvchi o'zgartirdi. Yangilab, qaytadan urinib ko'ring.",
    )


def check_version(current: int, expected: int | None) -> None:
    if expected is not None and current != expected:
        raise stale_version()


def aware(value: datetime) -> datetime:
    """A time without a UTC offset is the center's local time."""
    if value.tzinfo is None:
        return value.replace(tzinfo=ZoneInfo(settings.center_timezone))
    return value


def tomorrow_morning() -> datetime:
    """When an automatic follow-up is due: 10:00 tomorrow, center time."""
    return datetime.combine(clock.today() + timedelta(days=1), time(10), ZoneInfo(settings.center_timezone))


async def lock_lead(conn, lead_id: int) -> dict:
    lead = await conn.fetchrow("select * from leads where id = $1 for update", lead_id)
    if lead is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")
    return lead


async def log(
    conn,
    lead_id: int,
    body: str,
    *,
    user_id: int | None,
    kind: str = "system",
    old_stage: str | None = None,
    new_stage: str | None = None,
    booking_id: int | None = None,
    task_id: int | None = None,
) -> None:
    await conn.execute(
        """
        insert into lead_interactions
            (lead_id, kind, body, old_stage, new_stage, booking_id, task_id, created_by)
        values ($1, $2, $3, $4, $5, $6, $7, $8)
        """,
        lead_id,
        kind,
        body,
        old_stage,
        new_stage,
        booking_id,
        task_id,
        user_id,
    )


async def set_stage(
    conn,
    lead: dict,
    new_stage: str,
    *,
    user_id: int | None,
    reason: str | None = None,
    booking_id: int | None = None,
) -> None:
    """Moves a locked lead to new_stage and logs it. Closing sets
    closed_at; reopening clears it."""
    old_stage = lead["stage"]
    if old_stage == new_stage:
        return
    closed = new_stage in CLOSED_STAGES or new_stage == "enrolled"
    await conn.execute(
        """
        update leads
        set stage = $2,
            closed_at = case when $3 then coalesce(closed_at, now()) else null end,
            lost_reason = case when $3 then coalesce($4, lost_reason) else null end,
            version = version + 1,
            updated_at = now()
        where id = $1
        """,
        lead["id"],
        new_stage,
        closed,
        reason if new_stage in CLOSED_STAGES else None,
    )
    # Plain words, no arrow: the app's bundled font has no arrow glyph.
    body = f"Bosqich: {STAGE_LABELS[new_stage]} (avval: {STAGE_LABELS[old_stage]})"
    if reason:
        body += f". {reason}"
    await log(
        conn,
        lead["id"],
        body,
        user_id=user_id,
        old_stage=old_stage,
        new_stage=new_stage,
        booking_id=booking_id,
    )


async def add_task(
    conn,
    lead: dict,
    title: str,
    due_at: datetime,
    *,
    user_id: int | None,
    assigned_to: int | None = None,
) -> int:
    task_id = await conn.fetchval(
        """
        insert into follow_up_tasks (lead_id, title, due_at, assigned_to, created_by)
        values ($1, $2, $3, $4, $5)
        returning id
        """,
        lead["id"],
        title,
        due_at,
        assigned_to if assigned_to is not None else lead["assigned_to"],
        user_id,
    )
    await log(conn, lead["id"], f"Vazifa qo'shildi: {title}", user_id=user_id, task_id=task_id)
    return task_id


async def trial_fell_through(conn, lead_id: int, *, user_id: int | None, reason: str, booking_id: int) -> None:
    """After a no-show or cancelled trial: the lead stays open, back at
    'contacted', with a task to call them -- unless it has moved on
    already or has another trial booked."""
    lead = await lock_lead(conn, lead_id)
    if lead["stage"] not in ("trial_scheduled", "trial_completed"):
        return
    still_booked = await conn.fetchval(
        "select 1 from trial_bookings where lead_id = $1 and status = 'scheduled'", lead_id
    )
    if still_booked:
        return
    await set_stage(conn, lead, "contacted", user_id=user_id, reason=reason, booking_id=booking_id)
    await add_task(conn, lead, f"{reason} — qayta bog'laning", tomorrow_morning(), user_id=user_id)
