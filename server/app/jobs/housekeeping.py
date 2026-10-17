"""Daily clean-up: drops idempotency keys too old for any client to still
be retrying with (see idempotency.py)."""

import asyncio
import logging

from .. import idempotency

logger = logging.getLogger(__name__)

_INTERVAL_SECONDS = 24 * 60 * 60


async def run_forever() -> None:
    while True:
        try:
            purged = await idempotency.purge_expired()
            if purged:
                logger.info("Purged %d expired idempotency key(s).", purged)
        except Exception:
            logger.exception("Housekeeping run failed.")
        await asyncio.sleep(_INTERVAL_SECONDS)
