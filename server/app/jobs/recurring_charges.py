"""Creates every enrollment's full-fee monthly charge on its group's due day.

Runs once at startup -- catching up on any due days missed while the server
was down -- and then hourly, so a due day is charged within an hour of the
center's midnight. Every run is safe to repeat, and safe to run from several
worker processes at once: the partial unique index on (enrollment_id,
due_date) for charges makes a double charge impossible, and conflicting
inserts are simply skipped.

Billing follows the enrollment, not the group: an active enrollment is
charged even if its group is archived, so archiving a group must withdraw
its students too. (Skipping archived groups instead would back-charge every
missed month the moment one was reactivated.)
"""

import asyncio
import logging
from datetime import date

from .. import billing, clock, db

logger = logging.getLogger(__name__)

_INTERVAL_SECONDS = 60 * 60


async def create_due_charges(as_of: date) -> int:
    """Creates all charges due on or before as_of; returns how many."""
    rows = await db.pool().fetch(
        """
        select e.id, e.joined_at, e.ended_at, e.discount_kind, e.discount_value,
               g.fee_amount, g.due_day, max(t.due_date) as last_charged
        from enrollments e
        join groups g on g.id = e.group_id
        left join transactions t on t.enrollment_id = e.id and t.kind = 'charge'
        where e.status = 'active' or e.ended_at is not null
        group by e.id, g.fee_amount, g.due_day
        """
    )

    enrollment_ids: list[int] = []
    amounts: list[int] = []
    due_dates: list[date] = []
    for row in rows:
        # Every enrollment gets its first charge, dated joined_at, the
        # moment it's created -- joined_at only stands in if that charge
        # was removed by a same-day withdrawal.
        last_charged = row["last_charged"] or row["joined_at"]
        # Each month at the group's current fee, less this enrollment's own
        # discount. A 0 still gets a row, so the month counts as charged.
        fee = billing.discounted_fee(row["fee_amount"], row["discount_kind"], row["discount_value"])
        for due in billing.recurring_due_dates(row["due_day"], last_charged, as_of, row["ended_at"]):
            enrollment_ids.append(row["id"])
            amounts.append(fee)
            due_dates.append(due)

    if not enrollment_ids:
        return 0

    created = await db.pool().fetch(
        """
        insert into transactions
            (enrollment_id, kind, amount, period_start, due_date, is_prorated, source)
        select enrollment_id, 'charge', amount, due_date, due_date, false, 'auto_recurring'
        from unnest($1::bigint[], $2::bigint[], $3::date[]) as pending(enrollment_id, amount, due_date)
        on conflict do nothing
        returning id
        """,
        enrollment_ids,
        amounts,
        due_dates,
    )
    return len(created)


async def run_forever() -> None:
    while True:
        try:
            created = await create_due_charges(clock.today())
            if created:
                logger.info("Created %d recurring charge(s).", created)
        except Exception:
            # Never let one bad run kill the loop -- the next one catches up.
            logger.exception("Recurring charge run failed.")
        await asyncio.sleep(_INTERVAL_SECONDS)
