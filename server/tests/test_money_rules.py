"""The money rules as plain functions -- no database."""

from datetime import date, timedelta
from decimal import Decimal

import pytest

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


FEES = (1, 99, 100, 100_001, 300_000, 350_000, 380_000, 1_234_567)


def test_a_prorated_charge_never_exceeds_the_full_price():
    """Every billing day, every start date for two years, awkward fees and
    discounts: a part of a month is never more than the month."""
    checked = 0
    for billing_day in range(1, 29):
        for offset in range(0, 731):
            start = date(2026, 1, 1) + timedelta(days=offset)
            first = rules.billing_periods("fixed_day", billing_day, start, start)[0]
            for fee in FEES:
                for discount in (None, ("percent", 30), ("amount", 70)):
                    price = rules.discounted_fee(fee, *(discount or (None, None)))
                    amount = first.amount(price)
                    assert 0 <= amount <= price, (billing_day, start, fee, discount, amount, price)
                    if first.prorated:
                        assert first.days < first.cycle_days
                    checked += 1
    assert checked > 100_000


def test_a_later_start_in_the_same_cycle_never_costs_more():
    for billing_day in (1, 5, 14, 28):
        previous = None
        for offset in range(0, 31):
            start = date(2026, 10, 1) + timedelta(days=offset)
            first = rules.billing_periods("fixed_day", billing_day, start, start)[0]
            same_cycle = (first.start, first.end)
            amount = first.amount(380_000)
            cycle_end = first.end
            if previous and previous[0] == cycle_end:
                assert amount <= previous[1], (billing_day, start)
            previous = (cycle_end, amount)


def test_periods_never_overlap_and_leave_no_gap_in_either_mode():
    for mode, day in (("fixed_day", 1), ("fixed_day", 14), ("fixed_day", 28), ("student_anniversary", None)):
        for offset in range(0, 400, 7):
            start = date(2026, 1, 1) + timedelta(days=offset)
            periods = rules.billing_periods(mode, day, start, start + timedelta(days=500))
            assert periods[0].start == start
            for before, after in zip(periods, periods[1:]):
                assert before.end == after.start, (mode, day, start)
            assert all(p.end > p.start for p in periods)
            # Charged once per period start: no two periods share a start.
            assert len({p.start for p in periods}) == len(periods)


def test_joining_the_day_before_the_billing_day_is_two_periods_in_one_month():
    """Not a duplicate: one day of the old cycle, then the new cycle."""
    periods = rules.billing_periods("fixed_day", 15, date(2026, 10, 14), date(2026, 10, 17))
    assert [(p.start, p.end) for p in periods] == [
        (date(2026, 10, 14), date(2026, 10, 15)), (date(2026, 10, 15), date(2026, 11, 15)),
    ]
    assert [p.amount(380_000) for p in periods] == [12_667, 380_000]
    assert periods[0].days == 1 and periods[0].cycle_days == 30
