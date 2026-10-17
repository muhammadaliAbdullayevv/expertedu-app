"""The center's own calendar, independent of the server's timezone.

A server running in UTC would otherwise flip to "tomorrow" at 05:00 in
Tashkent and to "today" five hours late -- charging, withdrawing and
counting this month's payments against the wrong date in between.
"""

from datetime import date, datetime
from zoneinfo import ZoneInfo

from .config import settings


def today() -> date:
    return datetime.now(ZoneInfo(settings.center_timezone)).date()
