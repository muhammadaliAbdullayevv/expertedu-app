"""Queues the Telegram messages students get (telegram_outbox); the bot sends
them. Runs every few minutes and is safe to repeat: every message has a
dedupe key, so a thing is told once per chat however often this runs.

What a linked student hears about:
  - a payment due tomorrow, due today, and a reminder each week while it is overdue
  - a payment received (a receipt)
  - a lesson they were marked absent from
  - "welcome, you are a student now" for someone who asked through the bot and was then put into a group
  - on Sunday evening, how the week went: lessons attended out of those expected

Nothing is queued at night (before 08:00 or from 21:00 in the center's time):
a message that would have been sent then is queued in the morning instead.
"""

import asyncio
import json
import logging
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .. import db
from ..config import settings

logger = logging.getLogger(__name__)

_INTERVAL_SECONDS = 5 * 60
_FIRST_HOUR = 8
_LAST_HOUR = 21
_OVERDUE_AFTER_DAYS = 3
_OVERDUE_FOR_DAYS = 84


async def _queue(conn, rows: list[tuple]) -> int:
    """rows: (chat_id, student_id, kind, payload, dedupe_key). Returns how many were new."""
    made = 0
    for chat_id, student_id, kind, payload, key in rows:
        made += int(
            await conn.fetchval(
                "insert into telegram_outbox (chat_id, student_id, kind, payload, dedupe_key) "
                "values ($1, $2, $3, $4::jsonb, $5) on conflict (dedupe_key) do nothing returning 1",
                chat_id,
                student_id,
                kind,
                json.dumps(payload, default=str),
                key,
            )
            or 0
        )
    return made


async def generate(conn, now: datetime) -> int:
    """Queues what is due as of [now] (timezone-aware); returns how many messages."""
    local = now.astimezone(ZoneInfo(settings.center_timezone))
    from ..routes import bot_groups

    # The teacher's homework question belongs to the lesson's hour, whatever the hour is.
    made = await bot_groups.queue_prompts(conn, now)
    if not _FIRST_HOUR <= local.hour < _LAST_HOUR:
        return made
    today = local.date()

    made += await _welcome(conn)

    # Payments due tomorrow / today / overdue.
    charges = await conn.fetch(
        """
        select cb.charge_id, cb.due_date, cb.owed, g.name as group_name, tl.chat_id, tl.student_id
        from charge_balances cb
        join enrollments e on e.id = cb.enrollment_id and e.status = 'active'
        join groups g on g.id = e.group_id
        join telegram_links tl on tl.student_id = e.student_id and not tl.stopped
        where cb.status = 'active' and cb.owed > 0 and cb.due_date between $1 and $2
        """,
        today - timedelta(days=_OVERDUE_FOR_DAYS),
        today + timedelta(days=1),
    )
    iso = today.isocalendar()
    rows = []
    for c in charges:
        base = {"amount": c["owed"], "group_name": c["group_name"], "due_date": c["due_date"]}
        late_days = (today - c["due_date"]).days
        if c["due_date"] == today + timedelta(days=1):
            rows.append((c["chat_id"], c["student_id"], "due_tomorrow", base, f"due1:{c['charge_id']}:{c['chat_id']}"))
        elif c["due_date"] == today:
            rows.append((c["chat_id"], c["student_id"], "due_today", base, f"due0:{c['charge_id']}:{c['chat_id']}"))
        elif late_days >= _OVERDUE_AFTER_DAYS:
            rows.append(
                (
                    c["chat_id"], c["student_id"], "overdue", {**base, "days_overdue": late_days},
                    f"over:{c['charge_id']}:{iso.year}-{iso.week}:{c['chat_id']}",
                )
            )
    made += await _queue(conn, rows)

    # Payments received in the last day.
    paid = await conn.fetch(
        """
        select p.id, p.amount, p.method, p.receipt_no, g.name as group_name, tl.chat_id, tl.student_id
        from payments p
        join telegram_links tl on tl.student_id = p.student_id and not tl.stopped
        left join enrollments e on e.id = p.enrollment_id
        left join groups g on g.id = e.group_id
        where p.kind = 'payment' and p.status = 'valid' and p.received_at > $1
        """,
        now - timedelta(days=1),
    )
    made += await _queue(
        conn,
        [
            (
                p["chat_id"], p["student_id"], "paid",
                {"amount": p["amount"], "method": p["method"], "receipt_no": p["receipt_no"], "group_name": p["group_name"]},
                f"paid:{p['id']}:{p['chat_id']}",
            )
            for p in paid
        ],
    )

    # Marked absent from a lesson in the last day and a half.
    absent = await conn.fetch(
        """
        select a.id, l.starts_at, g.name as group_name, tl.chat_id, tl.student_id
        from attendance a
        join lessons l on l.id = a.lesson_id
        join groups g on g.id = l.group_id
        join enrollments e on e.id = a.enrollment_id
        join telegram_links tl on tl.student_id = e.student_id and not tl.stopped
        where a.status = 'absent' and l.starts_at > $1 and l.starts_at <= $2
        """,
        now - timedelta(hours=36),
        now,
    )
    made += await _queue(
        conn,
        [
            (
                a["chat_id"], a["student_id"], "absent",
                {"group_name": a["group_name"], "starts_at": a["starts_at"].astimezone(ZoneInfo(settings.center_timezone))},
                f"abs:{a['id']}:{a['chat_id']}",
            )
            for a in absent
        ],
    )

    # Sunday evening: how the week went.
    if local.isoweekday() == 7 and local.hour >= 18:
        made += await _weekly(conn, now, iso)
    return made


async def _welcome(conn) -> int:
    """People who asked through the bot and have since been put into a group: link
    their chat and congratulate them. (A phone that is a student with no group yet
    keeps waiting.)"""
    rows = await conn.fetch(
        """
        select p.chat_id, p.language, s.id as student_id, s.full_name,
               array_agg(distinct g.name) as groups
        from telegram_pending p
        join students s on s.phone = p.phone
        join enrollments e on e.student_id = s.id and e.status = 'active'
        join groups g on g.id = e.group_id
        group by p.chat_id, p.language, s.id, s.full_name
        """
    )
    made = 0
    for r in rows:
        async with conn.transaction():
            await conn.execute(
                """
                insert into telegram_links (chat_id, student_id, phone, language)
                select p.chat_id, $2, p.phone, p.language from telegram_pending p where p.chat_id = $1
                on conflict (chat_id) do update
                  set student_id = excluded.student_id, phone = excluded.phone, language = excluded.language, stopped = false
                """,
                r["chat_id"],
                r["student_id"],
            )
            await conn.execute("delete from telegram_pending where chat_id = $1", r["chat_id"])
            made += await _queue(
                conn,
                [
                    (
                        r["chat_id"], r["student_id"], "welcome",
                        {"student_name": r["full_name"], "groups": sorted(r["groups"])},
                        f"welcome:{r['student_id']}:{r['chat_id']}",
                    )
                ],
            )
    return made


async def _weekly(conn, now: datetime, iso) -> int:
    rows = await conn.fetch(
        """
        select tl.chat_id, tl.student_id,
               count(*) filter (where a.status = 'present') as present,
               count(*) filter (where a.status = 'late') as late,
               count(*) filter (where a.status = 'absent') as absent,
               count(*) filter (where a.status = 'excused') as excused
        from telegram_links tl
        join enrollments e on e.student_id = tl.student_id
        join attendance a on a.enrollment_id = e.id
        join lessons l on l.id = a.lesson_id
        where not tl.stopped and l.starts_at > $1 and l.starts_at <= $2
        group by tl.chat_id, tl.student_id
        """,
        now - timedelta(days=7),
        now,
    )
    out = []
    for r in rows:
        total = r["present"] + r["late"] + r["absent"] + r["excused"]
        expected = total - r["excused"]
        attended = r["present"] + r["late"]
        out.append(
            (
                r["chat_id"], r["student_id"], "weekly",
                {
                    "attended": attended, "late": r["late"], "absent": r["absent"], "excused": r["excused"],
                    "total": total, "rate": round(attended / expected, 4) if expected else None,
                },
                f"week:{r['student_id']}:{iso.year}-{iso.week}:{r['chat_id']}",
            )
        )
    return await _queue(conn, out)


async def run_forever() -> None:
    while True:
        try:
            async with db.pool().acquire() as conn:
                made = await generate(conn, datetime.now(ZoneInfo("UTC")))
            if made:
                logger.info("Queued %d Telegram message(s).", made)
        except Exception:
            logger.exception("Telegram notifier run failed.")
        await asyncio.sleep(_INTERVAL_SECONDS)
