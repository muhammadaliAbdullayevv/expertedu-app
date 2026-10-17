from datetime import date

from app.billing import (
    clamp_day,
    discounted_fee,
    first_charge_for_enrollment,
    first_period,
    last_due_on_or_before,
    next_due_after,
    oldest_unpaid_due,
    recurring_due_dates,
)


def test_clamp_day_handles_short_february():
    assert clamp_day(2026, 2, 31) == date(2026, 2, 28)
    assert clamp_day(2024, 2, 31) == date(2024, 2, 29)  # leap year


def test_last_due_on_or_before_exact_day():
    assert last_due_on_or_before(5, date(2026, 10, 5)) == date(2026, 10, 5)


def test_last_due_on_or_before_goes_to_previous_month():
    assert last_due_on_or_before(31, date(2026, 2, 15)) == date(2026, 1, 31)


def test_next_due_after_exact_day_rolls_to_next_month():
    assert next_due_after(31, date(2026, 1, 31)) == date(2026, 2, 28)


def test_first_charge_full_fee_when_joining_exactly_on_due_day():
    amount, is_prorated = first_charge_for_enrollment(fee_amount=300000, due_day=5, joined_at=date(2026, 10, 5))
    assert amount == 300000
    assert is_prorated is False


def test_first_charge_prorated_mid_cycle():
    # due_day=31 group, joins Feb 15: last_due=Jan 31, next_due=Feb 28.
    # 13 days remaining out of a 28-day period.
    amount, is_prorated = first_charge_for_enrollment(fee_amount=280000, due_day=31, joined_at=date(2026, 2, 15))
    assert is_prorated is True
    assert amount == round(280000 * 13 / 28)


def test_first_charge_joining_one_day_after_due_day():
    amount, is_prorated = first_charge_for_enrollment(fee_amount=300000, due_day=5, joined_at=date(2026, 10, 6))
    assert is_prorated is True
    # last_due=Oct 5, next_due=Nov 5 -> October has 31 days, so the period
    # is 31 days long with 30 remaining after the join date.
    assert amount == round(300000 * 30 / 31)


def test_recurring_none_before_next_due_day():
    # Joined Oct 6 (prorated first charge dated Oct 6) -- next due is Nov 5.
    assert recurring_due_dates(5, date(2026, 10, 6), date(2026, 11, 4), None) == []


def test_recurring_charges_on_the_due_day_itself():
    assert recurring_due_dates(5, date(2026, 10, 6), date(2026, 11, 5), None) == [date(2026, 11, 5)]


def test_recurring_catches_up_every_missed_month():
    assert recurring_due_dates(5, date(2026, 10, 5), date(2027, 1, 20), None) == [
        date(2026, 11, 5),
        date(2026, 12, 5),
        date(2027, 1, 5),
    ]


def test_recurring_clamps_day_31_through_february():
    assert recurring_due_dates(31, date(2026, 1, 31), date(2026, 3, 31), None) == [
        date(2026, 2, 28),
        date(2026, 3, 31),
    ]


def test_recurring_never_charges_after_last_charge_twice():
    assert recurring_due_dates(5, date(2026, 11, 5), date(2026, 11, 5), None) == []


def test_recurring_skips_period_starting_on_withdrawal_day():
    assert recurring_due_dates(5, date(2026, 10, 5), date(2026, 12, 20), date(2026, 11, 5)) == []


def test_recurring_still_charges_periods_started_before_withdrawal():
    assert recurring_due_dates(5, date(2026, 10, 5), date(2026, 12, 20), date(2026, 11, 20)) == [date(2026, 11, 5)]


def test_oldest_unpaid_due_fifo():
    charges = [(date(2026, 9, 5), 300000), (date(2026, 10, 5), 300000), (date(2026, 11, 5), 300000)]
    assert oldest_unpaid_due(charges, 0) == date(2026, 9, 5)
    assert oldest_unpaid_due(charges, 300000) == date(2026, 10, 5)
    assert oldest_unpaid_due(charges, 450000) == date(2026, 10, 5)  # Oct only partly covered
    assert oldest_unpaid_due(charges, 900000) is None


def test_discounted_fee():
    assert discounted_fee(380000, None, None) == 380000
    assert discounted_fee(380000, "amount", 38000) == 342000
    assert discounted_fee(380000, "percent", 10) == 342000
    assert discounted_fee(380000, "percent", 100) == 0
    assert discounted_fee(300000, "amount", 400000) == 0  # fee lowered below the discount later


def test_first_period_mid_cycle():
    assert first_period(15, date(2026, 10, 14)) == (date(2026, 9, 15), date(2026, 10, 15))
    assert first_period(15, date(2026, 10, 15)) == (date(2026, 10, 15), date(2026, 11, 15))


def test_french_group_first_charge_is_one_day_of_thirty():
    # Fransuz tili: 380 000 so'm, due day 15. Joined Oct 14 -> the period is
    # Sep 15..Oct 15 (30 days) with 1 day left: 380 000 / 30 = 12 666.67 -> 12 667.
    # Then Oct 15 brings the full 380 000: 392 667 owed in total.
    amount, is_prorated = first_charge_for_enrollment(380000, 15, date(2026, 10, 14))
    assert (amount, is_prorated) == (12667, True)
