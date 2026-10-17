import pytest

"""The money rules as plain functions -- no database."""

from datetime import date
from decimal import Decimal

from app.money import rules


def test_half_up_rounds_ties_up_not_to_even():
    assert rules.half_up_div(5, 2) == 3
    assert rules.half_up_div(7, 2) == 4
    assert rules.half_up_div(1, 3) == 0
    assert rules.half_up_div(2, 3) == 1


def test_discounts():
    assert rules.discounted_fee(400000, "amount", 50000) == 350000
    assert rules.discounted_fee(400000, "amount", 999999) == 0
    assert rules.discounted_fee(400000, "percent", 25) == 300000
    assert rules.discounted_fee(100005, "percent", 50) == 50003  # 50002.5 up
    assert rules.discounted_fee(400000, None, None) == 400000


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


def starts(periods):
    return [p.start for p in periods]


def test_fixed_day_first_period_is_prorated_from_the_start_to_the_next_billing_day():
    first = rules.billing_periods("fixed_day", 1, date(2026, 10, 16), date(2026, 10, 16))[0]
    assert (first.start, first.end, first.days, first.cycle_days, first.prorated) == (
        date(2026, 10, 16), date(2026, 11, 1), 16, 31, True
    )
    assert first.amount(310_000) == 160_000
    # February: 28 days in the cycle, 2028's leap February 29.
    assert rules.billing_periods("fixed_day", 1, date(2026, 2, 15), date(2026, 2, 15))[0].amount(280_000) == 140_000
    assert rules.billing_periods("fixed_day", 1, date(2028, 2, 15), date(2028, 2, 15))[0].amount(290_000) == 150_000
    # Half up, not banker's: 100001 * 15 / 30 = 50000.5 -> 50001.
    assert rules.billing_periods("fixed_day", 1, date(2026, 11, 16), date(2026, 11, 16))[0].amount(100_001) == 50_001


def test_fixed_day_joining_on_a_billing_day_or_with_proration_off_is_the_full_fee():
    on_day = rules.billing_periods("fixed_day", 14, date(2026, 10, 14), date(2026, 10, 14))[0]
    assert (on_day.prorated, on_day.amount(300_000), on_day.end) == (False, 300_000, date(2026, 11, 14))
    off = rules.billing_periods("fixed_day", 1, date(2026, 10, 16), date(2026, 10, 16), prorate_first=False)[0]
    assert (off.prorated, off.amount(300_000), off.end) == (False, 300_000, date(2026, 11, 1))


def test_fixed_day_periods_follow_each_other_without_gaps():
    periods = rules.billing_periods("fixed_day", 14, date(2026, 10, 5), date(2027, 1, 20))
    assert starts(periods) == [date(2026, 10, 5), date(2026, 10, 14), date(2026, 11, 14), date(2026, 12, 14), date(2027, 1, 14)]
    for before, after in zip(periods, periods[1:]):
        assert before.end == after.start


def test_anniversary_periods_never_prorate_and_keep_the_day():
    periods = rules.billing_periods("student_anniversary", None, date(2027, 1, 31), date(2027, 5, 1))
    assert starts(periods) == [date(2027, 1, 31), date(2027, 2, 28), date(2027, 3, 31), date(2027, 4, 30)]
    assert not any(p.prorated for p in periods) and all(p.amount(400_000) == 400_000 for p in periods)
    assert [p.end for p in periods][:2] == [date(2027, 2, 28), date(2027, 3, 31)]
    leap = rules.billing_periods("student_anniversary", None, date(2028, 1, 31), date(2028, 3, 31))
    assert starts(leap) == [date(2028, 1, 31), date(2028, 2, 29), date(2028, 3, 31)]


def test_leaving_ends_billing_from_that_day_but_the_first_period_is_always_listed():
    left = rules.billing_periods("fixed_day", 1, date(2026, 9, 10), date(2027, 1, 1), ended_at=date(2026, 11, 20))
    assert starts(left) == [date(2026, 9, 10), date(2026, 10, 1), date(2026, 11, 1)]
    same_day = rules.billing_periods("student_anniversary", None, date(2026, 9, 14), date(2027, 1, 1), ended_at=date(2026, 9, 14))
    assert starts(same_day) == [date(2026, 9, 14)]


def test_next_due_date():
    # Fixed 14th: today counts when it is the day.
    assert rules.next_due_date("fixed_day", 14, date(2026, 10, 5), date(2026, 10, 14)) == date(2026, 10, 14)
    assert rules.next_due_date("fixed_day", 14, date(2026, 10, 5), date(2026, 10, 15)) == date(2026, 11, 14)
    assert rules.next_due_date("student_anniversary", None, date(2026, 10, 14), date(2026, 10, 20)) == date(2026, 11, 14)
    assert rules.next_due_date("student_anniversary", None, date(2027, 1, 31), date(2027, 2, 1)) == date(2027, 2, 28)
    # Nothing after the student left.
    assert rules.next_due_date("fixed_day", 1, date(2026, 9, 1), date(2026, 12, 5), ended_at=date(2026, 11, 20)) is None


def test_bad_billing_rules_are_refused():
    with pytest.raises(ValueError):
        rules.billing_periods("weekly", 1, date(2026, 1, 1), date(2026, 2, 1))
    for day in (None, 0, 29):
        with pytest.raises(ValueError):
            rules.billing_periods("fixed_day", day, date(2026, 1, 1), date(2026, 2, 1))
