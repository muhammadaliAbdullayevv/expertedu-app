"""The Telegram bot in a course's group chat (see routes/bot.py for the bot's key and the
rest of its door):

  - a chat is connected to its CRM group by a one-time code the group's page hands out
    (`/connect CODE` in the chat, or the add-the-bot link that carries it);
  - who may answer the bot's questions is decided by Telegram user ids held in the CRM:
    the group's teacher (teachers.telegram_user_id), admins (staff_telegram -- an admin only
    in their own branch), and the owner (the bot says so for the ids in its OWNER_IDS);
  - a few minutes before each lesson ends the bot asks the teacher, student by student, how well
    they prepared (lesson_feedback), which the student's profile shows;
  - messages for a whole group (no names, no amounts) wait in telegram_group_outbox.
"""

import json
from datetime import date, datetime, timedelta
from typing import Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel

from .. import db, schedule
from ..config import settings
from ..phone import normalize
from .bot import require_bot_key

router = APIRouter(prefix="/bot", tags=["bot"], dependencies=[Depends(require_bot_key)])

HOMEWORK = ("great", "good", "weak", "bad", "none", "skipped")
# The bot asks this long before a lesson ends, and still may for this long after.
ASK_BEFORE_END = timedelta(minutes=5)
ASK_UNTIL_AFTER_END = timedelta(hours=2)
# A question still unanswered this long after it was posted is brought up once more (and never after a day).
REMIND_AFTER = timedelta(minutes=30)
REMIND_UNTIL = timedelta(hours=24)


# --- who is allowed ------------------------------------------------------------------------------------------


class _Actor:
    """A Telegram user as the CRM knows them: first by Telegram user id -- a teacher (teachers.telegram_user_id),
    staff (staff_telegram) or the owner (the bot vouches for the ids in its OWNER_IDS) -- and, failing that,
    by the number Telegram verified for them (a teacher's or a staff member's card)."""

    def __init__(self, *, is_owner: bool, teacher, staff, via: str | None, fallback_name: str | None = None):
        self.is_owner = is_owner
        self.teacher = teacher
        self.staff = staff
        self.via = via
        self._fallback_name = fallback_name

    @staticmethod
    async def of(
        conn, telegram_user_id: int, *, is_owner: bool = False, name: str | None = None, verified_phone: str | None = None
    ) -> "_Actor":
        teacher = await conn.fetchrow(
            "select id, full_name from teachers where telegram_user_id = $1 and is_active", telegram_user_id
        )
        staff = await conn.fetchrow(
            """
            select u.id, u.role, u.full_name, ub.branch_id
            from staff_telegram st
            join users u on u.id = st.user_id and u.is_active
            left join user_branches ub on ub.user_id = u.id
            where st.telegram_user_id = $1
            """,
            telegram_user_id,
        )
        via = "id" if (teacher or staff or is_owner) else None
        number = normalize(verified_phone or "")
        if via is None and number:
            teacher = await conn.fetchrow("select id, full_name from teachers where phone = $1 and is_active", number)
            staff = await conn.fetchrow(
                "select u.id, u.role, u.full_name, ub.branch_id from users u left join user_branches ub on ub.user_id = u.id "
                "where u.phone = $1 and u.is_active",
                number,
            )
            via = "phone" if (teacher or staff) else None
        return _Actor(is_owner=is_owner, teacher=teacher, staff=staff, via=via, fallback_name=name)

    @property
    def name(self) -> str | None:
        if self.staff:
            return self.staff["full_name"]
        if self.teacher:
            return self.teacher["full_name"]
        return self._fallback_name if self.is_owner else None

    def may_manage(self, group, *, teacher_ids: tuple[int | None, ...] = ()) -> bool:
        """The owner anywhere; an admin in their own branch; the group's teacher (or the lesson's)."""
        return self.role_for(group, teacher_ids=teacher_ids) is not None

    def role_for(self, group, *, teacher_ids: tuple[int | None, ...] = ()) -> str | None:
        """What lets them answer for this group: 'owner' | 'admin' | 'teacher', or None."""
        if self.is_owner or (self.staff and self.staff["role"] == "owner"):
            return "owner"
        if self.staff and self.staff["role"] == "admin" and self.staff["branch_id"] == group["branch_id"]:
            return "admin"
        if self.teacher is not None and self.teacher["id"] in ({group["teacher_id"], *teacher_ids} - {None}):
            return "teacher"
        return None


_GROUP_SQL = """
    select g.id as group_id, g.name, g.branch_id, g.teacher_id, s.name as subject_name,
           b.name as branch_name, t.full_name as teacher_name
    from groups g
    join subjects s on s.id = g.subject_id
    join branches b on b.id = g.branch_id
    left join teachers t on t.id = g.teacher_id
"""


# --- connecting a chat to a CRM group ------------------------------------------------------------------------


class GroupChat(BaseModel):
    connected: bool
    group_id: int | None = None
    group_name: str | None = None
    subject_name: str | None = None
    branch_name: str | None = None
    teacher_name: str | None = None


def _chat(row) -> GroupChat:
    return GroupChat(
        connected=True, group_id=row["group_id"], group_name=row["name"], subject_name=row["subject_name"],
        branch_name=row["branch_name"], teacher_name=row["teacher_name"],
    )


@router.get("/group-chat/{chat_id}", response_model=GroupChat)
async def group_chat(chat_id: int):
    row = await db.pool().fetchrow(
        _GROUP_SQL + " join telegram_groups tg on tg.group_id = g.id where tg.chat_id = $1", chat_id
    )
    return GroupChat(connected=False) if row is None else _chat(row)


class ConnectRequest(BaseModel):
    chat_id: int
    title: str | None = None
    # The one-time code from the group's page in the CRM.
    code: str


@router.post("/connect", response_model=GroupChat)
async def connect(payload: ConnectRequest):
    """Ties the chat to the group whose page issued [code]. A code works once and only for a day; a
    wrong, used or old one is just refused. One chat per group, one group per chat: connecting again moves it."""
    code = payload.code.strip().upper()
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                """
                select c.group_id, u.full_name as made_by from telegram_connect_codes c
                left join users u on u.id = c.created_by
                where c.code = $1 and c.used_at is null and c.expires_at > now() for update of c
                """,
                code,
            )
            if row is None:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Kod noto'g'ri yoki eskirgan.")
            group = await conn.fetchrow(_GROUP_SQL + " where g.id = $1 and g.is_active", row["group_id"])
            if group is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
            await conn.execute("delete from telegram_groups where chat_id = $1 or group_id = $2", payload.chat_id, group["group_id"])
            await conn.execute(
                "insert into telegram_groups (chat_id, group_id, title, connected_by) values ($1, $2, $3, $4)",
                payload.chat_id, group["group_id"], payload.title, row["made_by"],
            )
            await conn.execute("update telegram_connect_codes set used_at = now() where code = $1", code)
    return _chat(group)


# --- a Telegram account's place in the CRM -----------------------------------------------------------------------


class RegisterIdRequest(BaseModel):
    telegram_user_id: int
    # The number Telegram verified for this account (they shared their own contact).
    phone: str


class RegisteredId(BaseModel):
    role: Literal["owner", "admin", "teacher"] | None = None
    name: str | None = None


@router.post("/telegram-id", response_model=RegisteredId)
async def register_telegram_id(payload: RegisterIdRequest):
    """A convenience for the teacher or staff member who has no Telegram id on their card yet: when they
    share their own number with the bot and it matches, the id of that account is filled in. An id someone
    set by hand is never replaced (the CRM is the authority), nor taken from another person."""
    number = normalize(payload.phone)
    found = RegisteredId()
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            taken = await conn.fetchval(
                "select exists(select 1 from teachers where telegram_user_id = $1) "
                "or exists(select 1 from staff_telegram where telegram_user_id = $1)",
                payload.telegram_user_id,
            )
            teacher = await conn.fetchrow(
                "select id, full_name, telegram_user_id from teachers where phone = $1 and is_active", number
            )
            if teacher is not None:
                if teacher["telegram_user_id"] is None and not taken:
                    await conn.execute(
                        "update teachers set telegram_user_id = $2 where id = $1", teacher["id"], payload.telegram_user_id
                    )
                    taken = True
                found = RegisteredId(role="teacher", name=teacher["full_name"])
            user = await conn.fetchrow("select id, role, full_name from users where phone = $1 and is_active", number)
            if user is not None:
                has_one = await conn.fetchval("select exists(select 1 from staff_telegram where user_id = $1)", user["id"])
                if not has_one and not taken:
                    await conn.execute(
                        "insert into staff_telegram (user_id, telegram_user_id) values ($1, $2)", user["id"], payload.telegram_user_id
                    )
                found = RegisteredId(role=user["role"], name=user["full_name"])
    return found


# --- asking the teacher about the homework -----------------------------------------------------------------


class Question(BaseModel):
    enrollment_id: int
    student_name: str
    # "3 of 12": how many have been answered, and how many are asked about, in all.
    number: int
    total: int


class PendingRound(BaseModel):
    lesson_id: int
    chat_id: int
    group_name: str
    subject_name: str
    starts_at: datetime
    ends_at: datetime
    question: Question


def _local_day(moment: datetime):
    return moment.astimezone(ZoneInfo(settings.center_timezone)).date()


async def next_question(conn, lesson_id: int) -> tuple[Question | None, int, int]:
    """The next student to ask about for this lesson (alphabetical), how many are answered
    and how many are asked about in all. Students marked absent or excused are not asked."""
    lesson = await conn.fetchrow("select group_id, starts_at from lessons where id = $1", lesson_id)
    roster = await schedule.roster(conn, lesson["group_id"], _local_day(lesson["starts_at"]))
    skipped = {
        r["enrollment_id"]
        for r in await conn.fetch(
            "select enrollment_id from attendance where lesson_id = $1 and status in ('absent', 'excused')", lesson_id
        )
    }
    answered = {
        r["enrollment_id"] for r in await conn.fetch("select enrollment_id from lesson_feedback where lesson_id = $1", lesson_id)
    }
    asked_about = [r for r in roster if r["enrollment_id"] not in skipped]
    done = sum(1 for r in asked_about if r["enrollment_id"] in answered)
    todo = [r for r in asked_about if r["enrollment_id"] not in answered]
    if not todo:
        return None, done, len(asked_about)
    first = todo[0]
    return Question(
        enrollment_id=first["enrollment_id"], student_name=first["full_name"], number=done + 1, total=len(asked_about)
    ), done, len(asked_about)


async def queue_prompts(conn, now: datetime) -> int:
    """Called by the notifier job: for every connected group with a lesson ending in five minutes
    (or ended in the last two hours), one prompt for the bot to post. Safe to repeat."""
    from .timetable import _ensure_row, _timetable

    day = _local_day(now)
    made = 0
    for chat in await conn.fetch("select chat_id, group_id from telegram_groups"):
        for lesson in await _timetable(conn, day, day, group_id=chat["group_id"]):
            if lesson.status != "scheduled":
                continue
            if not lesson.ends_at - ASK_BEFORE_END <= now < lesson.ends_at + ASK_UNTIL_AFTER_END:
                continue
            lesson_id = lesson.lesson_id or await _ensure_row(conn, lesson, None)
            made += int(
                await conn.fetchval(
                    "insert into telegram_prompts (lesson_id, chat_id) values ($1, $2) on conflict (lesson_id) do nothing returning 1",
                    lesson_id, chat["chat_id"],
                )
                or 0
            )
    return made


@router.get("/feedback/pending", response_model=list[PendingRound])
async def feedback_pending(limit: int = Query(10, ge=1, le=50)):
    """Prompts waiting to be posted in their group chat, each with the first student to ask about."""
    out = []
    async with db.pool().acquire() as conn:
        for p in await conn.fetch(
            "select lesson_id, chat_id from telegram_prompts where status = 'pending' order by created_at limit $1", limit
        ):
            question, _, _ = await next_question(conn, p["lesson_id"])
            if question is None:  # everyone absent (or already answered): nothing to ask
                await conn.execute("update telegram_prompts set status = 'done' where lesson_id = $1", p["lesson_id"])
                continue
            lesson = await conn.fetchrow(
                "select l.starts_at, l.ends_at, g.name, s.name as subject_name from lessons l "
                "join groups g on g.id = l.group_id join subjects s on s.id = g.subject_id where l.id = $1",
                p["lesson_id"],
            )
            out.append(
                PendingRound(
                    lesson_id=p["lesson_id"], chat_id=p["chat_id"], group_name=lesson["name"],
                    subject_name=lesson["subject_name"], starts_at=lesson["starts_at"], ends_at=lesson["ends_at"],
                    question=question,
                )
            )
    return out


class AskedRequest(BaseModel):
    message_id: int


@router.post("/feedback/{lesson_id}/asked", status_code=status.HTTP_204_NO_CONTENT)
async def feedback_asked(lesson_id: int, payload: AskedRequest):
    await db.pool().execute(
        "update telegram_prompts set status = 'asked', message_id = $2 where lesson_id = $1 and status = 'pending'",
        lesson_id, payload.message_id,
    )


class FeedbackAnswer(BaseModel):
    chat_id: int
    lesson_id: int
    enrollment_id: int
    homework: Literal["great", "good", "weak", "bad", "none", "skipped"]
    # Who pressed the button: their Telegram user id, whether the bot's own config names them the
    # owner, and their Telegram name (kept with the answer when the CRM has no name for them).
    telegram_user_id: int
    is_owner: bool = False
    name: str | None = None
    # The number Telegram verified for them, if they shared one with the bot: the second way to be recognised.
    verified_phone: str | None = None


class FeedbackNext(BaseModel):
    group_name: str
    done: bool
    question: Question | None = None
    answered: int
    total: int
    # Who the answer was accepted from and how they were recognised ('id' or 'phone'), for the bot to say.
    recognized_as: Literal["owner", "admin", "teacher"] | None = None
    via: Literal["id", "phone"] | None = None


@router.post("/feedback/answer", response_model=FeedbackNext)
async def feedback_answer(payload: FeedbackAnswer):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            prompt = await conn.fetchrow(
                "select lesson_id from telegram_prompts where lesson_id = $1 and chat_id = $2 for update",
                payload.lesson_id, payload.chat_id,
            )
            if prompt is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "So'rov topilmadi.")
            group = await conn.fetchrow(
                _GROUP_SQL + " join lessons l on l.group_id = g.id where l.id = $1", payload.lesson_id
            )
            actor = await _Actor.of(
                conn, payload.telegram_user_id, is_owner=payload.is_owner, name=payload.name, verified_phone=payload.verified_phone
            )
            lesson_teacher = await conn.fetchval("select teacher_id from lessons where id = $1", payload.lesson_id)
            recognized_as = actor.role_for(group, teacher_ids=(lesson_teacher,))
            if recognized_as is None:
                raise HTTPException(status.HTTP_403_FORBIDDEN, "Faqat o'qituvchi yoki administrator javob bera oladi.")
            lesson = await conn.fetchrow("select group_id, starts_at from lessons where id = $1", payload.lesson_id)
            roster = await schedule.roster(conn, lesson["group_id"], _local_day(lesson["starts_at"]))
            if payload.enrollment_id not in {r["enrollment_id"] for r in roster}:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bu o'quvchi o'sha kuni guruhda emas edi.")
            await conn.execute(
                """
                insert into lesson_feedback (lesson_id, enrollment_id, homework, answered_by)
                values ($1, $2, $3, $4)
                on conflict (lesson_id, enrollment_id) do update
                  set homework = excluded.homework, answered_by = excluded.answered_by, answered_at = now()
                """,
                payload.lesson_id, payload.enrollment_id, payload.homework, actor.name or payload.name,
            )
            question, answered, total = await next_question(conn, payload.lesson_id)
            if question is None:
                await conn.execute("update telegram_prompts set status = 'done' where lesson_id = $1", payload.lesson_id)
    return FeedbackNext(
        group_name=group["name"], done=question is None, question=question, answered=answered, total=total,
        recognized_as=recognized_as, via=actor.via,
    )


class Reminder(BaseModel):
    lesson_id: int
    chat_id: int
    # The posted question: the reminder is a reply to it.
    message_id: int | None = None
    group_name: str
    remaining: int


@router.get("/feedback/reminders", response_model=list[Reminder])
async def feedback_reminders(limit: int = Query(10, ge=1, le=50)):
    """Questions posted a while ago that still have students nobody has answered about -- once each."""
    out = []
    async with db.pool().acquire() as conn:
        for p in await conn.fetch(
            """
            select p.lesson_id, p.chat_id, p.message_id, g.name as group_name
            from telegram_prompts p
            join lessons l on l.id = p.lesson_id
            join groups g on g.id = l.group_id
            where p.status = 'asked' and p.reminded_at is null
              and p.created_at < now() - $1::interval and p.created_at > now() - $2::interval
            order by p.created_at limit $3
            """,
            REMIND_AFTER, REMIND_UNTIL, limit,
        ):
            question, answered, total = await next_question(conn, p["lesson_id"])
            if question is None:  # everyone got answered in the meantime
                await conn.execute("update telegram_prompts set status = 'done' where lesson_id = $1", p["lesson_id"])
                continue
            out.append(
                Reminder(
                    lesson_id=p["lesson_id"], chat_id=p["chat_id"], message_id=p["message_id"],
                    group_name=p["group_name"], remaining=total - answered,
                )
            )
    return out


@router.post("/feedback/{lesson_id}/reminded", status_code=status.HTTP_204_NO_CONTENT)
async def feedback_reminded(lesson_id: int):
    await db.pool().execute("update telegram_prompts set reminded_at = now() where lesson_id = $1", lesson_id)


# --- messages for a whole group --------------------------------------------------------------------------------


async def queue_payment_soon(conn, today: date) -> int:
    """For each connected group with a payment due tomorrow or today: one general reminder in the chat
    -- no names, no amounts -- when at least one of those students has no private Telegram link (the
    others are told privately). Safe to repeat."""
    made = 0
    for when, day in (("tomorrow", today + timedelta(days=1)), ("today", today)):
        rows = await conn.fetch(
            """
            select tg.chat_id, g.name as group_name
            from telegram_groups tg
            join groups g on g.id = tg.group_id
            where exists (
              select 1 from charge_balances cb
              join enrollments e on e.id = cb.enrollment_id and e.status = 'active'
              where e.group_id = g.id and cb.status = 'active' and cb.owed > 0 and cb.due_date = $1
                and not exists (select 1 from telegram_links tl where tl.student_id = e.student_id and not tl.stopped)
            )
            """,
            day,
        )
        for r in rows:
            made += int(
                await conn.fetchval(
                    "insert into telegram_group_outbox (chat_id, kind, payload, dedupe_key) values ($1, 'payment_soon', $2::jsonb, $3) "
                    "on conflict (dedupe_key) do nothing returning 1",
                    r["chat_id"], json.dumps({"group_name": r["group_name"], "when": when, "due_date": str(day)}),
                    f"gpay:{r['chat_id']}:{day}:{when}",
                )
                or 0
            )
    return made


class GroupOutboxItem(BaseModel):
    id: int
    chat_id: int
    kind: str
    payload: dict


@router.get("/group-outbox", response_model=list[GroupOutboxItem])
async def group_outbox(limit: int = Query(30, ge=1, le=100)):
    rows = await db.pool().fetch(
        "select id, chat_id, kind, payload from telegram_group_outbox where status = 'pending' order by id limit $1", limit
    )
    return [
        GroupOutboxItem(
            id=r["id"], chat_id=r["chat_id"], kind=r["kind"],
            payload=json.loads(r["payload"]) if isinstance(r["payload"], str) else r["payload"],
        )
        for r in rows
    ]


class GroupOutboxResult(BaseModel):
    status: Literal["sent", "failed"]
    error: str | None = None


@router.post("/group-outbox/{item_id}/result", status_code=status.HTTP_204_NO_CONTENT)
async def group_outbox_result(item_id: int, payload: GroupOutboxResult):
    """'sent', or 'failed' (tried again, three times in all, then given up)."""
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow("select attempts from telegram_group_outbox where id = $1 for update", item_id)
            if row is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Xabar topilmadi.")
            if payload.status == "sent":
                await conn.execute(
                    "update telegram_group_outbox set status = 'sent', sent_at = now(), error = null, attempts = attempts + 1 where id = $1",
                    item_id,
                )
            else:
                attempts = row["attempts"] + 1
                await conn.execute(
                    "update telegram_group_outbox set status = $2, attempts = $3, error = $4 where id = $1",
                    item_id, "failed" if attempts >= 3 else "pending", attempts, payload.error,
                )
