"""The Telegram bot's door into the CRM (experteducenteraibot).

The bot is not a user: it has one key (BOT_API_KEY, sent as X-Bot-Key) and can
do only what is listed here -- show the public course list, take a request
from someone who asked about a course, link a student's chat to their record
(by the phone number Telegram verified), answer a linked student's own
questions, and send the messages queued for them. It never sees another
student's data and never gets a login.
"""

import hmac
from datetime import date, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
from pydantic import BaseModel

from .. import admissions, db
from ..config import settings
from ..phone import normalize
from .leads import lock_phone, open_lead_for
from .students import valid_phone


async def require_bot_key(x_bot_key: str | None = Header(default=None)) -> None:
    if not settings.bot_api_key:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Bot API o'chirilgan.")
    if not x_bot_key or not hmac.compare_digest(x_bot_key, settings.bot_api_key):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Kalit noto'g'ri.")


router = APIRouter(prefix="/bot", tags=["bot"], dependencies=[Depends(require_bot_key)])

LANGUAGES = ("uz", "en")
_MAX_REQUESTS_PER_DAY = 4


class Slot(BaseModel):
    weekday: int
    starts_at: str
    ends_at: str


class BotCourse(BaseModel):
    group_id: int
    name: str
    level: str | None = None
    fee_amount: int
    branch_id: int
    branch_name: str
    subject_id: int
    subject_name: str
    # "Madina K." -- a first name and an initial is all a stranger needs.
    teacher: str | None = None
    slots: list[Slot]
    # None = no seat limit.
    free_seats: int | None = None
    start_date: date | None = None


def _short(name: str | None) -> str | None:
    if not name:
        return None
    parts = name.split()
    return parts[0] if len(parts) == 1 else f"{parts[0]} {parts[1][0]}."


def _hhmm(value) -> str:
    return value.strftime("%H:%M")


@router.get("/courses", response_model=list[BotCourse])
async def courses():
    """Every group that is running, in every branch, with its price, days and
    free seats -- the public list the bot shows and the AI answers from."""
    rows = await db.pool().fetch(
        """
        select g.id as group_id, g.name, g.level, g.fee_amount, g.capacity, g.start_date,
               b.id as branch_id, b.name as branch_name, s.id as subject_id, s.name as subject_name,
               t.full_name as teacher_name,
               (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as enrolled
        from groups g
        join branches b on b.id = g.branch_id and b.is_active
        join subjects s on s.id = g.subject_id
        left join teachers t on t.id = g.teacher_id
        where g.is_active
        order by b.is_headquarters desc, b.name, s.name, g.name
        """
    )
    slots: dict[int, list[Slot]] = {}
    for r in await db.pool().fetch(
        "select group_id, weekday, starts_at, ends_at from group_schedules order by group_id, weekday"
    ):
        slots.setdefault(r["group_id"], []).append(
            Slot(weekday=r["weekday"], starts_at=_hhmm(r["starts_at"]), ends_at=_hhmm(r["ends_at"]))
        )
    return [
        BotCourse(
            group_id=r["group_id"],
            name=r["name"],
            level=r["level"],
            fee_amount=r["fee_amount"],
            branch_id=r["branch_id"],
            branch_name=r["branch_name"],
            subject_id=r["subject_id"],
            subject_name=r["subject_name"],
            teacher=_short(r["teacher_name"]),
            slots=slots.get(r["group_id"], []),
            free_seats=None if r["capacity"] is None else max(r["capacity"] - r["enrolled"], 0),
            start_date=r["start_date"],
        )
        for r in rows
    ]


# --- who is this number? ------------------------------------------------------------------------------------


class BotBranch(BaseModel):
    id: int
    name: str


@router.get("/branches", response_model=list[BotBranch])
async def branches():
    """Every active branch (also ones with no group yet): the owner sets their
    address and pictures in the bot."""
    rows = await db.pool().fetch("select id, name from branches where is_active order by is_headquarters desc, name")
    return [BotBranch(id=r["id"], name=r["name"]) for r in rows]


class Who(BaseModel):
    # 'owner' | 'admin' | 'teacher' | None -- what the center knows this person as, apart from
    # being a student (that is /link).
    role: Literal["owner", "admin", "teacher"] | None = None
    name: str | None = None
    teacher_id: int | None = None
    # How they were recognised: 'id' (their Telegram user id is on a card in the CRM, or the bot's owner
    # list) or 'phone' (the number Telegram verified is on a card). The id is checked first.
    via: Literal["id", "phone"] | None = None
    # Recognised by id, and the number Telegram verified is given: is it the number on the card?
    # (None when no number was given.) A different number does not matter -- the id decides.
    phone_matches: bool | None = None
    # The active groups they teach (a teacher), or the branch they work in (an admin).
    groups: list[str] = []
    branch_name: str | None = None


@router.get("/who", response_model=Who)
async def who(
    phone: str | None = Query(None),
    telegram_user_id: int | None = Query(None),
    is_owner: bool = Query(False),
):
    """Tells staff apart. First by Telegram user id -- the id on a teacher's or staff member's card, or
    [is_owner] when the bot's own list names them -- then, failing that, by the number Telegram verified (the
    owner and admins by their login number, teachers by the number on their record). Only active people count."""
    number = normalize(phone) if phone else None
    pool = db.pool()
    teacher = staff = None
    via = None
    if telegram_user_id is not None:
        teacher = await pool.fetchrow(
            "select id, full_name, phone from teachers where telegram_user_id = $1 and is_active", telegram_user_id
        )
        staff = await pool.fetchrow(
            "select u.role, u.full_name, u.phone, ub.branch_id from staff_telegram st "
            "join users u on u.id = st.user_id and u.is_active left join user_branches ub on ub.user_id = u.id "
            "where st.telegram_user_id = $1",
            telegram_user_id,
        )
        if teacher is not None or staff is not None or is_owner:
            via = "id"
    if via is None and number:
        staff = await pool.fetchrow(
            "select u.role, u.full_name, u.phone, ub.branch_id from users u left join user_branches ub on ub.user_id = u.id "
            "where u.phone = $1 and u.is_active order by u.role = 'owner' desc limit 1",
            number,
        )
        teacher = await pool.fetchrow(
            "select id, full_name, phone from teachers where phone = $1 and is_active order by id limit 1", number
        )
        if teacher is not None or staff is not None:
            via = "phone"
    if via is None:
        return Who()
    role = "owner" if is_owner or (staff and staff["role"] == "owner") else "admin" if staff else "teacher"
    name = staff["full_name"] if staff else teacher["full_name"] if teacher else None
    matches = None
    if via == "id" and number:
        on_cards = {c["phone"] for c in (teacher, staff) if c is not None}
        if is_owner and not on_cards:
            on_cards = {await pool.fetchval("select phone from users where role = 'owner' and is_active limit 1")}
        matches = number in on_cards
    groups = []
    if teacher is not None:
        groups = [
            r["name"]
            for r in await pool.fetch(
                "select name from groups where teacher_id = $1 and is_active order by name limit 12", teacher["id"]
            )
        ]
    branch = None
    if staff is not None and staff["role"] == "admin" and staff["branch_id"] is not None:
        branch = await pool.fetchval("select name from branches where id = $1", staff["branch_id"])
    return Who(
        role=role, name=name, teacher_id=teacher["id"] if teacher else None, via=via, phone_matches=matches,
        groups=groups, branch_name=branch,
    )


# --- someone asks about a course ------------------------------------------------------------------------------


class BotLeadRequest(BaseModel):
    chat_id: int
    username: str | None = None
    full_name: str
    phone: str
    group_id: int | None = None
    subject_id: int | None = None
    branch_id: int | None = None
    note: str | None = None


class BotLeadResult(BaseModel):
    # 'created' | 'duplicate' (they already have an open request for it)
    status: str
    lead_id: int


@router.post("/leads", response_model=BotLeadResult, status_code=status.HTTP_201_CREATED)
async def create_lead(payload: BotLeadRequest):
    """A request from the bot: lands in Qabul of the group's branch (else the
    chosen one, else Bosh ofis) as a new request from Telegram, for an admin to
    call. No student, no enrollment, no money. A chat may ask a few times a
    day, no more."""
    full_name = payload.full_name.strip()
    if not full_name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Ism kiritilishi shart.")
    phone = valid_phone(payload.phone)
    marker = f"(chat {payload.chat_id})"
    who = f"Telegram: @{payload.username} {marker}" if payload.username else f"Telegram {marker}"
    note = "\n".join(part for part in [(payload.note or "").strip(), who] if part)

    async with db.pool().acquire() as conn:
        async with conn.transaction():
            group = None
            subject_id = payload.subject_id
            branch_id = payload.branch_id
            if payload.group_id is not None:
                group = await conn.fetchrow("select * from groups where id = $1 and is_active", payload.group_id)
                if group is None:
                    raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
                branch_id = group["branch_id"]
                subject_id = subject_id or group["subject_id"]
            if subject_id is not None and not await conn.fetchval("select 1 from subjects where id = $1", subject_id):
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Fan topilmadi.")
            if branch_id is None or not await conn.fetchval(
                "select 1 from branches where id = $1 and is_active", branch_id
            ):
                branch_id = await conn.fetchval("select id from branches where is_headquarters")

            asked_today = await conn.fetchval(
                "select count(*) from leads where source = 'telegram' and note like $1 "
                "and created_at > now() - interval '1 day'",
                f"%{marker}%",
            )
            if asked_today >= _MAX_REQUESTS_PER_DAY:
                raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Bugun juda ko'p so'rov yubordingiz. Ertaga urinib ko'ring.")

            await lock_phone(conn, phone)
            existing = await open_lead_for(conn, phone, subject_id, branch_id)
            if existing is not None:
                await admissions.log(
                    conn, existing["id"], f"Telegram orqali qayta murojaat qildi. {who}", user_id=None, kind="telegram"
                )
                return BotLeadResult(status="duplicate", lead_id=existing["id"])

            student_id = await conn.fetchval("select id from students where phone = $1", phone)
            lead_id = await conn.fetchval(
                """
                insert into leads (full_name, phone, subject_id, source, note, student_id, group_id, branch_id)
                values ($1, $2, $3, 'telegram', $4, $5, $6, $7)
                returning id
                """,
                full_name,
                phone,
                subject_id,
                note,
                student_id,
                group["id"] if group else None,
                branch_id,
            )
            await admissions.log(
                conn, lead_id, "Telegram bot orqali so'rov yaratildi", user_id=None, kind="telegram", new_stage="new"
            )
            return BotLeadResult(status="created", lead_id=lead_id)


# --- linking a student's chat ----------------------------------------------------------------------------------


class LinkRequest(BaseModel):
    chat_id: int
    # The number Telegram verified (the contact the person shared themselves).
    phone: str
    language: Literal["uz", "en"] = "uz"


class LinkResult(BaseModel):
    linked: bool
    student_name: str | None = None


@router.post("/link", response_model=LinkResult)
async def link(payload: LinkRequest):
    """Links this chat to the student who has this phone number. Nothing
    is revealed when there is none: just linked = false (and the chat waits
    in telegram_pending to be welcomed once they are accepted)."""
    phone = normalize(payload.phone)
    row = await db.pool().fetchrow("select id, full_name from students where phone = $1", phone)
    if row is None:
        # Not a student (yet): remember the chat, so the bot can welcome them
        # when the center accepts them into a group.
        await db.pool().execute(
            """
            insert into telegram_pending (chat_id, phone, language) values ($1, $2, $3)
            on conflict (chat_id) do update set phone = excluded.phone, language = excluded.language
            """,
            payload.chat_id,
            phone,
            payload.language,
        )
        return LinkResult(linked=False)
    await db.pool().execute("delete from telegram_pending where chat_id = $1", payload.chat_id)
    await db.pool().execute(
        """
        insert into telegram_links (chat_id, student_id, phone, language)
        values ($1, $2, $3, $4)
        on conflict (chat_id) do update
          set student_id = excluded.student_id, phone = excluded.phone, language = excluded.language, stopped = false
        """,
        payload.chat_id,
        row["id"],
        phone,
        payload.language,
    )
    return LinkResult(linked=True, student_name=row["full_name"])


class SettingsRequest(BaseModel):
    chat_id: int
    language: Literal["uz", "en"] | None = None
    # True = /stop, False = turn the messages back on.
    stopped: bool | None = None


@router.post("/settings", response_model=LinkResult)
async def settings_(payload: SettingsRequest):
    row = await db.pool().fetchrow(
        """
        update telegram_links set language = coalesce($2, language), stopped = coalesce($3, stopped)
        where chat_id = $1 returning student_id
        """,
        payload.chat_id,
        payload.language,
        payload.stopped,
    )
    if row is None:
        return LinkResult(linked=False)
    name = await db.pool().fetchval("select full_name from students where id = $1", row["student_id"])
    return LinkResult(linked=True, student_name=name)


@router.post("/unlink", status_code=status.HTTP_204_NO_CONTENT)
async def unlink(chat_id: int = Query(...)):
    await db.pool().execute("delete from telegram_links where chat_id = $1", chat_id)


# --- a linked student asks about themselves --------------------------------------------------------------------


class MeGroup(BaseModel):
    group_name: str
    subject_name: str
    branch_name: str
    teacher: str | None = None
    slots: list[Slot]
    # What is still owed for this group (0 = paid up) and the oldest unpaid due date.
    owed: int
    next_due: date | None = None


class MeWeek(BaseModel):
    attended: int
    late: int
    absent: int
    excused: int
    total: int
    rate: float | None = None


class NextLesson(BaseModel):
    group_name: str
    starts_at: datetime


class MeHomeworkEntry(BaseModel):
    group_name: str
    at: datetime
    # 'great' | 'good' | 'weak' | 'bad' | 'none'
    homework: str


class MeHomework(BaseModel):
    """How well they prepared for lessons, from the teacher's answers to the bot's question."""

    great: int = 0
    good: int = 0
    weak: int = 0
    bad: int = 0
    none: int = 0
    total: int = 0
    # 0 (no homework at all) .. 4 (great); null until there is an answer.
    score: float | None = None
    recent: list[MeHomeworkEntry] = []


_HOMEWORK_SCORE = {"great": 4, "good": 3, "weak": 2, "bad": 1, "none": 0}


class Me(BaseModel):
    student_name: str
    language: str
    stopped: bool
    groups: list[MeGroup]
    total_owed: int
    week: MeWeek
    next_lessons: list[NextLesson]
    homework: MeHomework = MeHomework()


def week_numbers(rows) -> MeWeek:
    """Attendance of the last seven days: how many lessons they came to
    (on time or late) out of those they were expected at -- an excused absence
    is not held against them."""
    counts = {"present": 0, "late": 0, "absent": 0, "excused": 0}
    for r in rows:
        counts[r["status"]] += 1
    total = sum(counts.values())
    expected = total - counts["excused"]
    attended = counts["present"] + counts["late"]
    return MeWeek(
        attended=attended,
        late=counts["late"],
        absent=counts["absent"],
        excused=counts["excused"],
        total=total,
        rate=round(attended / expected, 4) if expected else None,
    )


@router.get("/me/{chat_id}", response_model=Me)
async def me(chat_id: int):
    async with db.pool().acquire() as conn:
        link_row = await conn.fetchrow(
            "select tl.language, tl.stopped, s.id, s.full_name from telegram_links tl "
            "join students s on s.id = tl.student_id where tl.chat_id = $1",
            chat_id,
        )
        if link_row is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Ulanmagan.")
        student_id = link_row["id"]
        group_rows = await conn.fetch(
            """
            select e.id as enrollment_id, g.id as group_id, g.name as group_name, s.name as subject_name,
                   b.name as branch_name, t.full_name as teacher_name,
                   coalesce((select sum(cb.owed) from charge_balances cb
                             where cb.enrollment_id = e.id and cb.status = 'active' and cb.owed > 0), 0)::bigint as owed,
                   (select min(cb.due_date) from charge_balances cb
                     where cb.enrollment_id = e.id and cb.status = 'active' and cb.owed > 0) as next_due
            from enrollments e
            join groups g on g.id = e.group_id
            join subjects s on s.id = g.subject_id
            join branches b on b.id = g.branch_id
            left join teachers t on t.id = g.teacher_id
            where e.student_id = $1 and e.status = 'active'
            order by g.name
            """,
            student_id,
        )
        group_ids = [r["group_id"] for r in group_rows]
        slot_rows = await conn.fetch(
            "select group_id, weekday, starts_at, ends_at from group_schedules where group_id = any($1::bigint[]) "
            "order by weekday",
            group_ids,
        )
        week_rows = await conn.fetch(
            """
            select a.status from attendance a
            join lessons l on l.id = a.lesson_id
            join enrollments e on e.id = a.enrollment_id
            where e.student_id = $1 and l.starts_at >= now() - interval '7 days' and l.starts_at <= now()
            """,
            student_id,
        )
        homework_rows = await conn.fetch(
            """
            select f.homework, l.starts_at, g.name as group_name
            from lesson_feedback f
            join lessons l on l.id = f.lesson_id
            join enrollments e on e.id = f.enrollment_id
            join groups g on g.id = e.group_id
            where e.student_id = $1 and f.homework <> 'skipped'
            order by l.starts_at desc, f.id desc
            """,
            student_id,
        )
    slots: dict[int, list[Slot]] = {}
    for r in slot_rows:
        slots.setdefault(r["group_id"], []).append(
            Slot(weekday=r["weekday"], starts_at=_hhmm(r["starts_at"]), ends_at=_hhmm(r["ends_at"]))
        )
    groups = [
        MeGroup(
            group_name=r["group_name"],
            subject_name=r["subject_name"],
            branch_name=r["branch_name"],
            teacher=_short(r["teacher_name"]),
            slots=slots.get(r["group_id"], []),
            owed=r["owed"],
            next_due=r["next_due"],
        )
        for r in group_rows
    ]
    return Me(
        student_name=link_row["full_name"],
        language=link_row["language"],
        stopped=link_row["stopped"],
        groups=groups,
        total_owed=sum(g.owed for g in groups),
        week=week_numbers(week_rows),
        next_lessons=_next_lessons(group_rows, slot_rows),
        homework=_homework(homework_rows),
    )


def _homework(rows) -> MeHomework:
    ratings = [r["homework"] for r in rows if r["homework"] in _HOMEWORK_SCORE]
    return MeHomework(
        **{key: ratings.count(key) for key in _HOMEWORK_SCORE},
        total=len(ratings),
        score=round(sum(_HOMEWORK_SCORE[r] for r in ratings) / len(ratings), 2) if ratings else None,
        recent=[MeHomeworkEntry(group_name=r["group_name"], at=r["starts_at"], homework=r["homework"]) for r in rows[:5]],
    )


def _next_lessons(group_rows, slot_rows, *, days: int = 7, limit: int = 6) -> list[NextLesson]:
    """The coming lessons from the weekly schedule, soonest first."""
    from zoneinfo import ZoneInfo

    tz = ZoneInfo(settings.center_timezone)
    now = datetime.now(tz)
    names = {r["group_id"]: r["group_name"] for r in group_rows}
    out = []
    for offset in range(days + 1):
        day = now.date() + timedelta(days=offset)
        for s in slot_rows:
            if s["weekday"] != day.isoweekday():
                continue
            starts = datetime.combine(day, s["starts_at"], tzinfo=tz)
            if starts > now:
                out.append(NextLesson(group_name=names[s["group_id"]], starts_at=starts))
    return sorted(out, key=lambda n: n.starts_at)[:limit]


# --- the messages to send ---------------------------------------------------------------------------------------


class OutboxItem(BaseModel):
    id: int
    chat_id: int
    language: str
    kind: str
    payload: dict


@router.get("/outbox", response_model=list[OutboxItem])
async def outbox(limit: int = Query(30, ge=1, le=100)):
    """What is waiting to be sent, oldest first -- only for chats that have
    not stopped."""
    rows = await db.pool().fetch(
        """
        select o.id, o.chat_id, o.kind, o.payload, tl.language
        from telegram_outbox o join telegram_links tl on tl.chat_id = o.chat_id
        where o.status = 'pending' and not tl.stopped
        order by o.id limit $1
        """,
        limit,
    )
    import json

    return [
        OutboxItem(
            id=r["id"],
            chat_id=r["chat_id"],
            language=r["language"],
            kind=r["kind"],
            payload=json.loads(r["payload"]) if isinstance(r["payload"], str) else r["payload"],
        )
        for r in rows
    ]


class OutboxResult(BaseModel):
    # 'sent' | 'failed' (try again later) | 'blocked' (the person blocked the bot)
    status: Literal["sent", "failed", "blocked"]
    error: str | None = None


_MAX_ATTEMPTS = 3


@router.post("/outbox/{item_id}/result", status_code=status.HTTP_204_NO_CONTENT)
async def outbox_result(item_id: int, payload: OutboxResult):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow("select chat_id, attempts from telegram_outbox where id = $1 for update", item_id)
            if row is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Xabar topilmadi.")
            if payload.status == "sent":
                await conn.execute(
                    "update telegram_outbox set status = 'sent', sent_at = now(), error = null, attempts = attempts + 1 "
                    "where id = $1",
                    item_id,
                )
            elif payload.status == "blocked":
                await conn.execute(
                    "update telegram_outbox set status = 'blocked', error = $2, attempts = attempts + 1 where id = $1",
                    item_id,
                    payload.error,
                )
                # They do not want it: nothing more is queued for this chat.
                await conn.execute("update telegram_links set stopped = true where chat_id = $1", row["chat_id"])
                await conn.execute(
                    "update telegram_outbox set status = 'blocked' where chat_id = $1 and status = 'pending'",
                    row["chat_id"],
                )
            else:
                attempts = row["attempts"] + 1
                await conn.execute(
                    "update telegram_outbox set status = $2, attempts = $3, error = $4 where id = $1",
                    item_id,
                    "failed" if attempts >= _MAX_ATTEMPTS else "pending",
                    attempts,
                    payload.error,
                )
