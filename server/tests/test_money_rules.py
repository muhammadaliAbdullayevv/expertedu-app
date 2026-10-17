"""The money rules as plain functions -- no database."""

from datetime import date
from decimal import Decimal

from app.money import rules


def test_half_up_rounds_ties_up_not_to_even():
    assert rules.half_up_div(5, 2) == 3
    assert rules.half_up_div(7, 2) == 4
    assert rules.half_up_div(1, 3) == 0
    assert rules.half_up_div(2, 3) == 1


def test_first_month_prorates_remaining_days_including_the_start_day():
    # October has 31 days; starting on the 16th leaves 16 days (16..31).
    assert rules.first_month_charge(310000, date(2026, 10, 16), "prorated") == (160000, True)
    # The last day of the month is one day.
    assert rules.first_month_charge(310000, date(2026, 10, 31), "prorated") == (10000, True)


def test_first_month_on_the_1st_or_in_full_mode_is_the_whole_fee():
    assert rules.first_month_charge(300000, date(2026, 10, 1), "prorated") == (300000, False)
    assert rules.first_month_charge(300000, date(2026, 10, 16), "full") == (300000, False)


def test_first_month_proration_in_february_and_a_leap_february():
    # 2026: 28 days; 2028: 29 days.
    assert rules.first_month_charge(280000, date(2026, 2, 15), "prorated") == (140000, True)
    assert rules.first_month_charge(290000, date(2028, 2, 15), "prorated") == (150000, True)


def test_proration_rounds_half_up():
    # 100001 * 15 / 30 = 50000.5 -> 50001 (banker's rounding would give 50000).
    assert rules.first_month_charge(100001, date(2026, 11, 16), "prorated")[0] == 50001


def test_discounts():
    assert rules.discounted_fee(400000, "amount", 50000) == 350000
    assert rules.discounted_fee(400000, "amount", 999999) == 0
    assert rules.discounted_fee(400000, "percent", 25) == 300000
    assert rules.discounted_fee(100005, "percent", 50) == 50003  # 50002.5 up
    assert rules.discounted_fee(400000, None, None) == 400000


def test_billing_date_is_clamped_to_the_month():
    assert rules.billing_date(date(2026, 2, 1), 1) == date(2026, 2, 1)
    assert rules.billing_date(date(2026, 2, 1), 28) == date(2026, 2, 28)
    assert rules.billing_date(date(2026, 2, 1), 31) == date(2026, 2, 28)


def test_months_to_charge_follow_the_billing_day():
    start = date(2026, 10, 16)
    assert rules.months_to_charge(start, date(2026, 10, 31), 1) == []
    assert rules.months_to_charge(start, date(2026, 11, 1), 1) == [date(2026, 11, 1)]
    # Billing day 5: not yet on the 4th.
    assert rules.months_to_charge(start, date(2026, 11, 4), 5) == []
    assert rules.months_to_charge(start, date(2026, 11, 5), 5) == [date(2026, 11, 1)]
    # A server down for months catches up on every month.
    assert rules.months_to_charge(start, date(2027, 1, 1), 1) == [
        date(2026, 11, 1), date(2026, 12, 1), date(2027, 1, 1)
    ]


def test_months_to_charge_stop_after_the_month_they_left_in():
    start = date(2026, 9, 10)
    assert rules.months_to_charge(start, date(2027, 1, 1), 1, ended_at=date(2026, 11, 20)) == [
        date(2026, 10, 1), date(2026, 11, 1)
    ]


def test_allocate_pays_the_oldest_charge_first():
    unpaid = [(1, 100), (2, 100), (3, 100)]
    assert rules.allocate(150, unpaid) == ([(1, 100), (2, 50)], 0)
    assert rules.allocate(40, unpaid) == ([(1, 40)], 0)
    assert rules.allocate(0, unpaid) == ([], 0)


def test_allocate_leftover_is_credit():
    assert rules.allocate(350, [(1, 100), (2, 100)]) == ([(1, 100), (2, 100)], 150)
    assert rules.allocate(100, []) == ([], 100)


def test_allocate_skips_fully_paid_charges():
    assert rules.allocate(50, [(1, 0), (2, 80)]) == ([(2, 50)], 0)


def test_balance_negative_is_debt():
    assert rules.balance(payments_total=300, charges_total=500) == -200
    assert rules.balance(payments_total=500, charges_total=300) == 200


def test_debt_age_buckets():
    assert [rules.debt_bucket(d) for d in (0, 7, 8, 30, 31, 200)] == ["0-7", "0-7", "8-30", "8-30", "30+", "30+"]


def test_salary_share_at_30_percent_rounds_half_up():
    assert rules.salary_share(1_000_000, Decimal("30")) == 300_000
    assert rules.salary_share(1_000_005, 30) == 300_002  # 300001.5 up
    assert rules.salary_share(333_333, Decimal("30.00")) == 100_000  # 99999.9
    assert rules.salary_share(500_000, None) == 0
    assert rules.salary_share(0, 30) == 0
    assert rules.salary_share(-1_000_000, 30) == -300_000
