"""Creates every enrollment's monthly charge once its billing day has come.

Runs once at startup -- catching up on any days missed while the server was
down -- and then hourly, so a month is charged within an hour of the
center's midnight on the billing day. Every run is safe to repeat and to run
from several workers: a month already charged (even if cancelled) is
skipped, and the unique index on (enrollment, month) backs that up.

The rules live in app/money; this is only the clock.

Billing follows the enrollment, not the group: an active enrollment is
charged even if its group is archived, so archiving a group must withdraw
its students too.
"""

import asyncio
import logging
from datetime import date

from .. import clock, db
from ..money import service as money

logger = logging.getLogger(__name__)

_INTERVAL_SECONDS = 60 * 60


async def create_due_charges(as_of: date) -> int:
    """Creates all charges due on or before as_of; returns how many."""
    async with db.pool().acquire() as conn:
        return await money.generate_charges(conn, as_of)


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
