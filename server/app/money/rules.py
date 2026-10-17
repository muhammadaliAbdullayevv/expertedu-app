"""The money rules, as plain functions of numbers and dates -- no database,
no web. Everything here is money in whole so'm (int) and calendar months of
the center; service.py applies these to the stored rows.

Rounding is always half up (2.5 -> 3), never Python's banker's round().
"""

import calendar
from datetime import date
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


def billing_date(month: date, billing_day: int) -> date:
    """The day charges for `month` are created -- clamped to the month's
    last day, though settings keep billing_day <= 28."""
    return date(month.year, month.month, min(billing_day, days_in_month(month)))


def discounted_fee(fee: int, kind: str | None, value: int | None) -> int:
    """The monthly fee after an enrollment's discount ('amount' so'm off, or
    'percent'), never below zero."""
    if kind == "amount" and value:
        return max(fee - value, 0)
    if kind == "percent" and value:
        return half_up_div(fee * (100 - value), 100)
    return fee


def first_month_charge(fee: int, start: date, mode: str) -> tuple[int, bool]:
    """(amount, is_prorated) for the month a student starts in.

    Prorated: the fee times the days left in the month, the start day
    included, over the days in the month. Starting on the 1st, or mode
    'full', is the whole fee."""
    if mode == "full" or start.day == 1:
        return fee, False
    remaining = days_in_month(start) - start.day + 1
    return half_up_div(fee * remaining, days_in_month(start)), True


def months_to_charge(start: date, as_of: date, billing_day: int, ended_at: date | None = None) -> list[date]:
    """Months after the start month that should be charged by `as_of`: each
    month whose billing date has arrived, up to the month the enrollment
    ended in (a month entirely after ending is not owed)."""
    months = []
    month = next_month(month_start(start))
    while billing_date(month, billing_day) <= as_of:
        if ended_at is not None and month > month_start(ended_at):
            break
        months.append(month)
        month = next_month(month)
    return months


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
