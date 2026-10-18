"""The Telegram bot in a course's group chat (see routes/bot.py for the bot's key and the
rest of its door):

  - a group chat is connected to its CRM group by the teacher / an admin / the owner;
  - a person who joined the chat proves who they are in a private chat -- their
    Telegram contact, or, when their Telegram number differs from the one they
    registered with, the registered number typed in (accepted only for someone who is
    in *this* group, so it cannot be used to claim anybody else);
  - a few minutes before each lesson ends the bot asks the teacher, student by student,
    how well they prepared (lesson_feedback), which the student's profile shows.
"""

from datetime import datetime, timedelta
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
    """What the CRM knows about a phone number: staff by login number (only when
    Telegram verified the number), a teacher by the number on their record."""

    def __init__(self, user, teacher):
        self.user = user
        self.teacher = teacher

    @staticmethod
    async def of(conn, phone: str | None, verified: bool) -> "_Actor":
        number = normalize(phone or "")
        user = None
        if verified and number:
            user = await conn.fetchrow(
                "select u.id, u.role, u.full_name, ub.branch_id from users u "
                "left join user_branches ub on ub.user_id = u.id where u.phone = $1 and u.is_active",
                number,
            )
        teacher = (
            await conn.fetchrow("select id, full_name from teachers where phone = $1 and is_active", number)
            if number
            else None
        )
        return _Actor(user, teacher)

    @property
    def name(self) -> str | None:
        if self.user:
            return self.user["full_name"]
        return self.teacher["full_name"] if self.teacher else None

    def may_manage(self, group) -> bool:
        """The owner, the admin of the group's branch, the group's own teacher."""
        if self.user and (
            self.user["role"] == "owner" or (self.user["role"] == "admin" and self.user["branch_id"] == group["branch_id"])
        ):
            return True
        return self.teacher is not None and group["teacher_id"] == self.teacher["id"]


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


@router.get("/group-chat/{chat_id}", response_model=GroupChat)
async def group_chat(chat_id: int):
    row = await db.pool().fetchrow(
        _GROUP_SQL + " join telegram_groups tg on tg.group_id = g.id where tg.chat_id = $1", chat_id
    )
    if row is None:
        return GroupChat(connected=False)
    return GroupChat(
        connected=True, group_id=row["group_id"], group_name=row["name"], subject_name=row["subject_name"],
        branch_name=row["branch_name"], teacher_name=row["teacher_name"],
    )


class ConnectableGroup(BaseModel):
    group_id: int
    name: str
    subject_name: str
    branch_name: str


@router.get("/connectable", response_model=list[ConnectableGroup])
async def connectable(phone: str = Query(...), verified: bool = Query(True)):
    """The CRM groups this person may connect a chat to: all of them for the owner, those of
    their branch for an admin, their own for a teacher."""
    async with db.pool().acquire() as conn:
        actor = await _Actor.of(conn, phone, verified)
        rows = await conn.fetch(_GROUP_SQL + " where g.is_active order by b.name, s.name, g.name")
    return [
        ConnectableGroup(group_id=r["group_id"], name=r["name"], subject_name=r["subject_name"], branch_name=r["branch_name"])
        for r in rows
        if actor.may_manage(r)
    ]


class ConnectRequest(BaseModel):
    chat_id: int
    title: str | None = None
    group_id: int
    phone: str
    verified: bool = True


@router.post("/connect", response_model=GroupChat)
async def connect(payload: ConnectRequest):
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            actor = await _Actor.of(conn, payload.phone, payload.verified)
            group = await conn.fetchrow(_GROUP_SQL + " where g.id = $1 and g.is_active", payload.group_id)
            if group is None:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Guruh topilmadi.")
            if not actor.may_manage(group):
                raise HTTPException(status.HTTP_403_FORBIDDEN, "Bu guruhni ulashga ruxsatingiz yo'q.")
            # One chat per group, one group per chat: connecting again moves it.
            await conn.execute("delete from telegram_groups where chat_id = $1 or group_id = $2", payload.chat_id, payload.group_id)
            await conn.execute(
                "insert into telegram_groups (chat_id, group_id, title, connected_by) values ($1, $2, $3, $4)",
                payload.chat_id, payload.group_id, payload.title, actor.name,
            )
    return GroupChat(
        connected=True, group_id=group["group_id"], group_name=group["name"], subject_name=group["subject_name"],
        branch_name=group["branch_name"], teacher_name=group["teacher_name"],
    )


@router.delete("/connect", status_code=status.HTTP_204_NO_CONTENT)
async def disconnect(chat_id: int = Query(...), phone: str = Query(...), verified: bool = Query(True)):
    async with db.pool().acquire() as conn:
        actor = await _Actor.of(conn, phone, verified)
        group = await conn.fetchrow(
            _GROUP_SQL + " join telegram_groups tg on tg.group_id = g.id where tg.chat_id = $1", chat_id
        )
        if group is None:
            return
        if not actor.may_manage(group):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Bu guruhni uzishga ruxsatingiz yo'q.")
        await conn.execute("delete from telegram_groups where chat_id = $1", chat_id)


# --- who is this person in the group? --------------------------------------------------------------------------


class GroupLinkRequest(BaseModel):
    # The person's private chat with the bot, the group chat they joined, and the
    # number they typed (the one they registered with at the center).
    chat_id: int
    group_chat_id: int
    phone: str
    language: Literal["uz", "en"] = "uz"


class GroupLinkResult(BaseModel):
    # 'student' (linked now) | 'teacher' (this group's teacher) | 'none'
    status: Literal["student", "teacher", "none"]
    name: str | None = None


@router.post("/link-in-group", response_model=GroupLinkResult)
async def link_in_group(payload: GroupLinkRequest):
    """The registered number someone typed, accepted only if it belongs to a current student
    of the CRM group this chat is connected to (or to that group's teacher). Nothing else is
    revealed: anything else is just 'none'."""
    number = normalize(payload.phone)
    async with db.pool().acquire() as conn:
        async with conn.transaction():
            group = await conn.fetchrow(
                "select g.id, g.teacher_id from groups g join telegram_groups tg on tg.group_id = g.id where tg.chat_id = $1",
                payload.group_chat_id,
            )
            if group is None:
                return GroupLinkResult(status="none")
            teacher = await conn.fetchrow(
                "select id, full_name from teachers where phone = $1 and is_active and id = $2", number, group["teacher_id"]
            )
            if teacher is not None:
                return GroupLinkResult(status="teacher", name=teacher["full_name"])
            student = await conn.fetchrow(
                """
                select s.id, s.full_name from students s
                join enrollments e on e.student_id = s.id and e.group_id = $2 and e.status = 'active'
                where s.phone = $1 limit 1
                """,
                number,
                group["id"],
            )
            if student is None:
                return GroupLinkResult(status="none")
            await conn.execute(
                """
                insert into telegram_links (chat_id, student_id, phone, language, method)
                values ($1, $2, $3, $4, 'group')
                on conflict (chat_id) do update
                  set student_id = excluded.student_id, phone = excluded.phone, language = excluded.language,
                      stopped = false, method = 'group'
                """,
                payload.chat_id, student["id"], number, payload.language,
            )
            await conn.execute("delete from telegram_pending where chat_id = $1", payload.chat_id)
    return GroupLinkResult(status="student", name=student["full_name"])


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
    # Who pressed the button (their number as the bot knows it) and whether Telegram verified it.
    actor_phone: str
    verified: bool = True


class FeedbackNext(BaseModel):
    group_name: str
    done: bool
    question: Question | None = None
    answered: int
    total: int


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
            actor = await _Actor.of(conn, payload.actor_phone, payload.verified)
            if not actor.may_manage(group):
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
                payload.lesson_id, payload.enrollment_id, payload.homework, actor.name,
            )
            question, answered, total = await next_question(conn, payload.lesson_id)
            if question is None:
                await conn.execute("update telegram_prompts set status = 'done' where lesson_id = $1", payload.lesson_id)
    return FeedbackNext(group_name=group["name"], done=question is None, question=question, answered=answered, total=total)


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
