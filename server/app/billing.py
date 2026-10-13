"""Billing date math, shared by enrollment creation (first-charge proration)
and the future daily billing job (full-fee recurring charges).

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
