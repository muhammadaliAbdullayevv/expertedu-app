"""Group lesson schedules: weekly slots in the center's calendar, the
lessons they produce, and the clashes between them.

A slot is (weekday, local start, local end, room). A lesson of a slot on
a given day starts at that day's date + start time in the center's time
zone -- that instant (with the group) is the lesson's identity, which is
what `lessons.starts_at` stores once the lesson gets a row.
"""

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from fastapi import HTTPException, status

from .config import settings

WEEKDAYS = ("", "Dushanba", "Seshanba", "Chorshanba", "Payshanba", "Juma", "Shanba", "Yakshanba")


def center_tz() -> ZoneInfo:
    return ZoneInfo(settings.center_timezone)


@dataclass(frozen=True)
class Slot:
    group_id: int
    weekday: int
    starts_at: time
    ends_at: time
    room: str | None


@dataclass(frozen=True)
class Occurrence:
    slot: Slot
    starts_at: datetime
    ends_at: datetime


def occurrences(slots: list[Slot], date_from: date, date_to: date) -> list[Occurrence]:
    """Every lesson the slots produce on date_from..date_to (inclusive)."""
    tz = center_tz()
    by_weekday: dict[int, list[Slot]] = {}
    for slot in slots:
        by_weekday.setdefault(slot.weekday, []).append(slot)
    result: list[Occurrence] = []
    day = date_from
    while day <= date_to:
        for slot in by_weekday.get(day.isoweekday(), ()):
            result.append(
                Occurrence(
                    slot=slot,
                    starts_at=datetime.combine(day, slot.starts_at, tz),
                    ends_at=datetime.combine(day, slot.ends_at, tz),
                )
            )
        day += timedelta(days=1)
    return result


def local(value: datetime) -> datetime:
    return value.astimezone(center_tz())


def slot_label(weekday: int, starts_at: time, ends_at: time) -> str:
    return f"{WEEKDAYS[weekday]} {starts_at:%H:%M}–{ends_at:%H:%M}"


def _overlaps(a: Slot, b: Slot) -> bool:
    return a.weekday == b.weekday and a.starts_at < b.ends_at and b.starts_at < a.ends_at


def validate_own_slots(slots: list[Slot]) -> None:
    for i, a in enumerate(slots):
        if a.ends_at <= a.starts_at:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                f"{slot_label(a.weekday, a.starts_at, a.ends_at)}: tugash vaqti boshlanishdan keyin bo'lsin.",
            )
        for b in slots[i + 1 :]:
            if _overlaps(a, b):
                raise HTTPException(
                    status.HTTP_400_BAD_REQUEST,
                    f"{slot_label(a.weekday, a.starts_at, a.ends_at)} va "
                    f"{slot_label(b.weekday, b.starts_at, b.ends_at)} ustma-ust tushadi.",
                )


async def load_slots(conn, *, group_ids: list[int] | None = None, active_only: bool = True) -> list[Slot]:
    where, args = [], []
    if active_only:
        where.append("g.is_active")
    if group_ids is not None:
        args.append(group_ids)
        where.append(f"gs.group_id = any(${len(args)}::bigint[])")
    rows = await conn.fetch(
        f"""
        select gs.group_id, gs.weekday, gs.starts_at, gs.ends_at, gs.room
        from group_schedules gs join groups g on g.id = gs.group_id
        {"where " + " and ".join(where) if where else ""}
        order by gs.weekday, gs.starts_at
        """,
        *args,
    )
    return [Slot(**row) for row in rows]


async def check_clashes(conn, *, group_id: int, teacher_id: int | None, slots: list[Slot]) -> None:
    """No other active group may have a lesson overlapping one of [slots]
    with the same teacher or in the same room. Serialized under one lock,
    so two schedules saved at once can't both take the same hour."""
    await conn.execute("select pg_advisory_xact_lock(hashtext('group_schedules'))")
    if not slots:
        return
    others = await conn.fetch(
        """
        select gs.weekday, gs.starts_at, gs.ends_at, gs.room, g.name, g.teacher_id,
               t.full_name as teacher_name
        from group_schedules gs
        join groups g on g.id = gs.group_id
        left join teachers t on t.id = g.teacher_id
        where g.is_active and g.id <> $1
        """,
        group_id,
    )
    for slot in slots:
        for other in others:
            if not (
                slot.weekday == other["weekday"]
                and slot.starts_at < other["ends_at"]
                and other["starts_at"] < slot.ends_at
            ):
                continue
            when = slot_label(other["weekday"], other["starts_at"], other["ends_at"])
            if teacher_id is not None and other["teacher_id"] == teacher_id:
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    f"O'qituvchi {other['teacher_name']} bu vaqtda band: {when}, \"{other['name']}\" guruhi.",
                )
            if slot.room and other["room"] and slot.room.lower() == other["room"].lower():
                raise HTTPException(
                    status.HTTP_409_CONFLICT,
                    f"\"{slot.room}\" xonasi bu vaqtda band: {when}, \"{other['name']}\" guruhi.",
                )


async def regular_lesson_clash(
    conn,
    *,
    starts_at: datetime,
    ends_at: datetime,
    teacher_id: int | None,
    room: str | None,
    exclude_group_id: int | None = None,
) -> str | None:
    """A message if a regular group lesson takes the teacher or room at that
    time (for trial sessions and extra lessons); None if free."""
    start, end = local(starts_at), local(ends_at)
    if start.date() != end.date():
        end_time = time.max
    else:
        end_time = end.time()
    row = await conn.fetchrow(
        """
        select g.name, gs.weekday, gs.starts_at, gs.ends_at, g.teacher_id = $4 as same_teacher,
               t.full_name as teacher_name
        from group_schedules gs
        join groups g on g.id = gs.group_id
        left join teachers t on t.id = g.teacher_id
        where g.is_active and gs.weekday = $1 and gs.starts_at < $3 and gs.ends_at > $2
          and (g.teacher_id = $4 or lower(gs.room) = lower($5))
          and g.id is distinct from $6
          and not exists (
            select 1 from lessons l
            where l.group_id = g.id and l.status = 'cancelled'
              and l.starts_at = ($7::date + gs.starts_at) at time zone $8
          )
        limit 1
        """,
        start.isoweekday(),
        start.time(),
        end_time,
        teacher_id,
        room,
        exclude_group_id,
        start.date(),
        settings.center_timezone,
    )
    if row is None:
        return None
    when = slot_label(row["weekday"], row["starts_at"], row["ends_at"])
    if row["same_teacher"]:
        return f"O'qituvchi {row['teacher_name']} bu vaqtda dars beradi: {when}, \"{row['name']}\" guruhi."
    return f"\"{room}\" xonasi bu vaqtda band: {when}, \"{row['name']}\" guruhi."


async def roster(conn, group_id: int, day: date) -> list[dict]:
    """The group's students on [day]: joined by then, not left before it."""
    rows = await conn.fetch(
        """
        select e.id as enrollment_id, s.id as student_id, s.full_name, s.phone
        from enrollments e join students s on s.id = e.student_id
        where e.group_id = $1 and e.joined_at <= $2 and (e.ended_at is null or e.ended_at > $2)
        order by s.full_name
        """,
        group_id,
        day,
    )
    return [dict(row) for row in rows]
