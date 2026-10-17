"""Kurs qidirish: which groups fit what a client asked for.

A client says the subject, the level, the weekdays they can come and the
part of the day. Every active group of that subject and level whose
lessons all fall in the part of the day is a candidate, then:

  exact  every one of the group's lesson days is a day the client can come
  near   some, or none, of them are (the client asked Mon-Wed-Fri, the
         group meets Tue-Thu-Sat) -- shown with how many days match, best first

With no days given every candidate is exact. Free seats are the capacity
minus the active enrollments (null when the group has no limit).
"""

from datetime import time

from . import schedule

TIME_OF_DAY = {
    "morning": (time(0, 0), time(12, 0)),
    "afternoon": (time(12, 0), time(17, 0)),
    "evening": (time(17, 0), time(23, 59, 59)),
}


def in_part_of_day(slot_starts: time, part: str) -> bool:
    start, end = TIME_OF_DAY[part]
    return start <= slot_starts < end or (part == "evening" and slot_starts >= start)


def classify(group_days: set[int], wanted: set[int] | None) -> tuple[bool, int]:
    """(is_exact, matched_days) for a group's lesson days against the days
    the client can come."""
    if not wanted:
        return True, len(group_days)
    matched = len(group_days & wanted)
    return bool(group_days) and group_days <= wanted, matched


async def search(
    conn,
    *,
    subject_id: int | None,
    level: str | None,
    weekdays: set[int] | None,
    time_of_day: str | None,
) -> dict[str, list[dict]]:
    where, args = ["g.is_active"], []
    if subject_id is not None:
        args.append(subject_id)
        where.append(f"g.subject_id = ${len(args)}")
    if level:
        args.append(level.strip().lower())
        where.append(f"lower(g.level) = ${len(args)}")
    groups = await conn.fetch(
        f"""
        select g.id, g.name, g.level, g.fee_amount, g.capacity, g.start_date, g.billing_mode, g.billing_day,
               g.prorate_first_period, g.teacher_id, t.full_name as teacher_name, s.name as subject_name,
               (select count(*) from enrollments e where e.group_id = g.id and e.status = 'active') as enrolled
        from groups g
        left join teachers t on t.id = g.teacher_id
        left join subjects s on s.id = g.subject_id
        where {' and '.join(where)}
        order by g.name
        """,
        *args,
    )
    slots = await schedule.load_slots(conn, group_ids=[g["id"] for g in groups])
    by_group: dict[int, list[schedule.Slot]] = {}
    for slot in slots:
        by_group.setdefault(slot.group_id, []).append(slot)

    exact, near = [], []
    for group in groups:
        group_slots = by_group.get(group["id"], [])
        if time_of_day and not all(in_part_of_day(s.starts_at, time_of_day) for s in group_slots):
            continue
        days = {s.weekday for s in group_slots}
        is_exact, matched = classify(days, weekdays)
        capacity = group["capacity"]
        item = {
            "group_id": group["id"],
            "name": group["name"],
            "subject_name": group["subject_name"],
            "level": group["level"],
            "teacher_name": group["teacher_name"],
            "fee_amount": group["fee_amount"],
            "billing_mode": group["billing_mode"],
            "billing_day": group["billing_day"],
            "prorate_first_period": group["prorate_first_period"],
            "start_date": group["start_date"],
            "capacity": capacity,
            "enrolled": group["enrolled"],
            "free_seats": None if capacity is None else max(capacity - group["enrolled"], 0),
            "slots": [
                {"weekday": s.weekday, "starts_at": s.starts_at, "ends_at": s.ends_at, "room": s.room}
                for s in sorted(group_slots, key=lambda s: (s.weekday, s.starts_at))
            ],
            "weekdays": sorted(days),
            "matched_days": matched,
            "total_days": len(days),
        }
        (exact if is_exact else near).append(item)
    # Open seats first; full groups last. Near ones: most matching days first.
    full_last = lambda i: (i["free_seats"] == 0, -(i["free_seats"] or 0) if i["free_seats"] is not None else 0)
    exact.sort(key=full_last)
    near.sort(key=lambda i: (i["free_seats"] == 0, -i["matched_days"]))
    return {"exact": exact, "near": near}
