"""Billing date math, shared by enrollment creation (first-charge proration)
and the recurring-charge job (full-fee monthly charges, jobs/recurring_charges.py).

Billing is "in advance": a charge's due_date always equals its
period_start -- the date payment is expected is the same date the paid-for
period begins.
"""

import calendar
from datetime import date


def clamp_day(year: int, month: int, day: int) -> date:
    """Handles a due_day like 31 falling in a 30/28/29-day month by
    clamping to that month's actual last day."""
    last_day = calendar.monthrange(year, month)[1]
    return date(year, month, min(day, last_day))


def _shift_month(year: int, month: int, delta: int) -> tuple[int, int]:
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def last_due_on_or_before(due_day: int, as_of: date) -> date:
    """The most recent occurrence of due_day that is <= as_of -- equal to
    as_of itself when as_of lands exactly on the due day."""
    candidate = clamp_day(as_of.year, as_of.month, due_day)
    if candidate <= as_of:
        return candidate
    year, month = _shift_month(as_of.year, as_of.month, -1)
    return clamp_day(year, month, due_day)


def next_due_after(due_day: int, as_of: date) -> date:
    """The next occurrence of due_day strictly after as_of."""
    candidate = clamp_day(as_of.year, as_of.month, due_day)
    if candidate > as_of:
        return candidate
    year, month = _shift_month(as_of.year, as_of.month, 1)
    return clamp_day(year, month, due_day)


def first_charge_for_enrollment(fee_amount: int, due_day: int, joined_at: date) -> tuple[int, bool]:
    """(amount, is_prorated) for the charge due immediately at enrollment.

    Full fee, not prorated, when joined_at lands exactly on the group's due
    day -- last_due_on_or_before then equals joined_at itself, so
    days_remaining == days_in_period and the formula naturally yields the
    full fee without a separate branch.
    """
    last_due = last_due_on_or_before(due_day, joined_at)
    next_due = next_due_after(due_day, last_due)
    days_remaining = (next_due - joined_at).days
    days_in_period = (next_due - last_due).days
    amount = round(fee_amount * days_remaining / days_in_period)
    is_prorated = joined_at != last_due
    return amount, is_prorated


def recurring_due_dates(due_day: int, last_charged: date, as_of: date, ended_at: date | None) -> list[date]:
    """Every due date after last_charged, up to and including as_of, that
    still needs its full-fee charge -- usually none or one, but more after
    the server has been down across a due day.

    Counts from the last charge actually made rather than from joined_at,
    so a group's due_day changing later never back-fills the old months
    under the new day. A period starting on or after ended_at isn't
    charged: a student who withdraws on the due day itself doesn't owe for
    the month they won't be starting.
    """
    dates = []
    due = next_due_after(due_day, last_charged)
    while due <= as_of and (ended_at is None or due < ended_at):
        dates.append(due)
        due = next_due_after(due_day, due)
    return dates


def oldest_unpaid_due(charges: list[tuple[date, int]], paid: int) -> date | None:
    """Due date of the oldest charge payments haven't fully covered yet, or
    None when everything's paid. Payments settle charges oldest-first --
    the same FIFO rule lib/core/utils/enrollment_ledger_calculator.dart
    applies on the client. charges must be sorted oldest-first."""
    remaining = paid
    for due_date, amount in charges:
        if remaining < amount:
            return due_date
        remaining -= amount
    return None


def discounted_fee(fee_amount: int, discount_kind: str | None, discount_value: int | None) -> int:
    """An enrollment's monthly fee after its discount: 'amount' takes that
    many so'm off, 'percent' that whole percent (so it follows the group's
    fee if that changes later). Never below zero -- an amount discount stays
    put if the group's fee is later lowered beneath it."""
    if discount_kind == "amount" and discount_value:
        return max(fee_amount - discount_value, 0)
    if discount_kind == "percent" and discount_value:
        return round(fee_amount * (100 - discount_value) / 100)
    return fee_amount


def first_period(due_day: int, joined_at: date) -> tuple[date, date]:
    """(start, end) of the billing period joined_at falls in -- the due day
    on or before it, and the next one after. end is where the second,
    full-fee charge lands."""
    start = last_due_on_or_before(due_day, joined_at)
    return start, next_due_after(due_day, start)
