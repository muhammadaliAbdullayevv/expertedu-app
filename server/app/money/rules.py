"""The money rules, as plain functions of numbers and dates -- no database,
no web. Everything here is money in whole so'm (int) and calendar months of
the center; service.py applies these to the stored rows.

Rounding is always half up (2.5 -> 3), never Python's banker's round().
"""

import calendar
from dataclasses import dataclass
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal

FIRST_MONTH_MODES = ("prorated", "full")
DEBT_BUCKETS = ("0-7", "8-30", "30+")


def half_up_div(numerator: int, denominator: int) -> int:
    """numerator / denominator rounded half up, for non-negative integers."""
    return (2 * numerator + denominator) // (2 * denominator)


def month_start(value: date) -> date:
    return value.replace(day=1)


def next_month(value: date) -> date:
    return date(value.year + value.month // 12, value.month % 12 + 1, 1)


def days_in_month(value: date) -> int:
    return calendar.monthrange(value.year, value.month)[1]


def clamp_day(year: int, month: int, day: int) -> date:
    """`day` of the month, or its last day when the month is shorter (the
    31st in a 30-day month, the 29th-31st in February)."""
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def add_months(value: date, months: int) -> date:
    index = value.year * 12 + value.month - 1 + months
    return date(index // 12, index % 12 + 1, 1)


def discounted_fee(fee: int, kind: str | None, value: int | None) -> int:
    """The monthly fee after an enrollment's discount ('amount' so'm off, or
    'percent'), never below zero."""
    if kind == "amount" and value:
        return max(fee - value, 0)
    if kind == "percent" and value:
        return half_up_div(fee * (100 - value), 100)
    return fee


BILLING_MODES = ("fixed_day", "student_anniversary")


@dataclass(frozen=True)
class Period:
    """One billing period of one enrollment: [start, end), charged on `start`.

    A prorated first period is charged `days` / `cycle_days` of the fee --
    the days from the student's start to the next billing day, over the
    days in the full cycle that contains the start."""

    start: date
    end: date
    is_first: bool = False
    prorated: bool = False
    days: int = 0
    cycle_days: int = 0

    def amount(self, fee: int) -> int:
        if self.prorated:
            return half_up_div(fee * self.days, self.cycle_days)
        return fee


def _fixed_day_billing_date(month_first: date, billing_day: int) -> date:
    return date(month_first.year, month_first.month, billing_day)


def _fixed_day_on_or_before(day: date, billing_day: int) -> date:
    this = _fixed_day_billing_date(month_start(day), billing_day)
    return this if this <= day else _fixed_day_billing_date(add_months(month_start(day), -1), billing_day)


def _fixed_day_after(day: date, billing_day: int) -> date:
    """The first billing date strictly after `day`."""
    this = _fixed_day_billing_date(month_start(day), billing_day)
    return this if this > day else _fixed_day_billing_date(add_months(month_start(day), 1), billing_day)


def billing_periods(
    mode: str,
    billing_day: int | None,
    start: date,
    until: date,
    ended_at: date | None = None,
    prorate_first: bool = True,
) -> list[Period]:
    """Every billing period of an enrollment that began by `until`.

    fixed_day: everyone in the group pays on `billing_day` (1-28) each
      month. A student who joins between billing days first pays for the
      stretch up to the next one -- prorated unless `prorate_first` is off,
      when the first charge is the full fee.
    student_anniversary: the enrollment bills on its own start day every
      month; no proration. A start day the month lacks (the 31st) falls on
      that month's last day, but the day itself is never lost: January 31
      is followed by February 28/29, then March 31.

    The first period is always listed. Later ones only while they begin
    before `ended_at` -- leaving ends billing from that day on."""
    if mode not in BILLING_MODES:
        raise ValueError(f"unknown billing mode {mode!r}")
    periods: list[Period] = []
    if mode == "fixed_day":
        if billing_day is None or not 1 <= billing_day <= 28:
            raise ValueError("fixed_day needs a billing day from 1 to 28")
        previous = _fixed_day_on_or_before(start, billing_day)
        end = _fixed_day_after(start, billing_day)
        mid_cycle = start != previous
        periods.append(
            Period(
                start,
                end,
                is_first=True,
                prorated=mid_cycle and prorate_first,
                days=(end - start).days,
                cycle_days=(end - previous).days,
            )
        )
        while True:
            begin = periods[-1].end
            if begin > until or (ended_at is not None and begin >= ended_at):
                break
            periods.append(Period(begin, _fixed_day_after(begin, billing_day)))
        return periods
    first_of_month = month_start(start)
    k = 0
    while True:
        begin = start if k == 0 else clamp_day(*_year_month(add_months(first_of_month, k)), start.day)
        if k > 0 and (begin > until or (ended_at is not None and begin >= ended_at)):
            return periods
        end = clamp_day(*_year_month(add_months(first_of_month, k + 1)), start.day)
        periods.append(Period(begin, end, is_first=k == 0))
        k += 1


def _year_month(value: date) -> tuple[int, int]:
    return value.year, value.month


def next_due_date(
    mode: str,
    billing_day: int | None,
    start: date,
    today: date,
    ended_at: date | None = None,
    prorate_first: bool = True,
) -> date | None:
    """The next day (today included) a charge falls due for the enrollment,
    or None once it has ended."""
    horizon = today + timedelta(days=62)
    for period in billing_periods(mode, billing_day, start, horizon, ended_at, prorate_first):
        if period.start >= today and (ended_at is None or period.start < ended_at or period.is_first):
            return period.start
    return None


def allocate(available: int, unpaid: list[tuple[int, int]]) -> tuple[list[tuple[int, int]], int]:
    """Spreads `available` over unpaid charges, oldest first.

    `unpaid` is [(charge_id, still_owed)] already in payment order; returns
    ([(charge_id, amount)], leftover). Whatever no charge takes is credit."""
    result = []
    for charge_id, owed in unpaid:
        if available <= 0:
            break
        if owed <= 0:
            continue
        take = min(available, owed)
        result.append((charge_id, take))
        available -= take
    return result, available


def balance(payments_total: int, charges_total: int) -> int:
    """Payments minus charges: negative is debt, positive is credit."""
    return payments_total - charges_total


def debt_bucket(days_overdue: int) -> str:
    """Age bucket of a debt, by days since its oldest unpaid charge was due."""
    if days_overdue <= 7:
        return "0-7"
    if days_overdue <= 30:
        return "8-30"
    return "30+"


def salary_share(collected: int, percent: Decimal | float | int | str | None) -> int:
    """A teacher's share of `collected` (may be negative for refunds), at
    `percent`; nothing when the teacher has no percent."""
    if percent is None:
        return 0
    exact = Decimal(collected) * Decimal(str(percent)) / 100
    return int(exact.quantize(Decimal(1), rounding=ROUND_HALF_UP))
