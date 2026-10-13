from datetime import date

from app.billing import clamp_day, first_charge_for_enrollment, last_due_on_or_before, next_due_after


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
