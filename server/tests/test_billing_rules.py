"""The center's real money rules: per-group billing (fixed day or student
anniversary), mixed teacher pay (percent or fixed, per teacher with a group
override), the owner/admin split and the one-free-trial rule. Dates are fixed
so none of these depends on today, except where noted."""

from datetime import date, timedelta

import pytest

from app import clock
from app.money import rules, service as money
from test_admissions import PHONE, book, move_to_past, new_lead, seed as seed_admissions, session_payload

pytestmark = pytest.mark.anyio

FEE = 400_000


class Center:
    def __init__(self, api):
        self.api, self.pool = api, api.pool

    async def build(self):
        self.subject = await self.pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
        self.teacher = await self.pool.fetchval(
            "insert into teachers (full_name, salary_method, salary_percent) values ('Dilnoza', 'percent', 30) returning id"
        )
        self.s1 = await self.student("Aziz", "998901000001")
        self.s2 = await self.student("Bobur", "998901000002")
        return self

    async def student(self, name, phone):
        return await self.pool.fetchval("insert into students (full_name, phone) values ($1, $2) returning id", name, phone)

    async def group(self, mode="fixed_day", day=1, fee=FEE, prorate=True, teacher=None, name="Guruh"):
        return await self.pool.fetchval(
            "insert into groups (subject_id, name, teacher_id, fee_amount, billing_mode, billing_day, prorate_first_period) "
            "values ($1, $2, $3, $4, $5, $6, $7) returning id",
            self.subject, name, teacher or self.teacher, fee, mode, day if mode == "fixed_day" else None, prorate,
        )

    async def enroll(self, student, group, joined: date, first_charge=True, mode=None):
        e = await self.pool.fetchval(
            "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, $3) returning id", student, group, joined
        )
        if first_charge:
            async with self.pool.acquire() as conn:
                g = dict(await conn.fetchrow("select * from groups where id = $1", group))
                row = dict(await conn.fetchrow("select * from enrollments where id = $1", e))
                await money.issue_first_charge(conn, row, g, self.api.owner_id, mode)
        return e

    async def generate(self, as_of: date) -> int:
        async with self.pool.acquire() as conn:
            return await money.generate_charges(conn, as_of)

    async def charges(self, enrollment):
        rows = await self.pool.fetch(
            "select period_start, period_end, amount, is_prorated, status from charges "
            "where enrollment_id = $1 order by period_start", enrollment,
        )
        return [(r["period_start"], r["period_end"], r["amount"], r["is_prorated"]) for r in rows if r["status"] == "active"]


@pytest.fixture
async def c(api):
    return await Center(api).build()


async def record(c, **kwargs):
    async with c.pool.acquire() as conn:
        return await money.record_payment(conn, **kwargs)


def d(y, m, day):
    return date(y, m, day)


# --- fixed_day --------------------------------------------------------------------------------------


async def test_fixed_day_1st_joining_mid_month_is_prorated_then_full(c):
    g = await c.group("fixed_day", 1)
    e = await c.enroll(c.s1, g, d(2026, 10, 16))
    # 16 of October's 31 days (Oct 16 .. Oct 31), rounded half up.
    assert await c.charges(e) == [(d(2026, 10, 16), d(2026, 11, 1), rules.half_up_div(FEE * 16, 31), True)]
    assert await c.generate(d(2026, 12, 2)) == 2
    got = await c.charges(e)
    assert got[1:] == [(d(2026, 11, 1), d(2026, 12, 1), FEE, False), (d(2026, 12, 1), d(2027, 1, 1), FEE, False)]
    # Running it again changes nothing.
    assert await c.generate(d(2026, 12, 2)) == 0
    assert await c.generate(d(2026, 12, 31)) == 0


async def test_fixed_day_joining_on_the_1st_pays_the_full_fee(c):
    g = await c.group("fixed_day", 1)
    e = await c.enroll(c.s1, g, d(2026, 10, 1))
    assert await c.charges(e) == [(d(2026, 10, 1), d(2026, 11, 1), FEE, False)]


async def test_fixed_day_14th_joining_on_the_5th_pays_nine_of_thirty_days(c):
    g = await c.group("fixed_day", 14)
    e = await c.enroll(c.s1, g, d(2026, 10, 5))
    # The cycle Sep 14 .. Oct 14 has 30 days; Oct 5 .. Oct 14 is 9 of them.
    assert await c.charges(e) == [(d(2026, 10, 5), d(2026, 10, 14), FEE * 9 // 30, True)]
    await c.generate(d(2026, 11, 20))
    assert (await c.charges(e))[1:] == [
        (d(2026, 10, 14), d(2026, 11, 14), FEE, False),
        (d(2026, 11, 14), d(2026, 12, 14), FEE, False),
    ]


async def test_fixed_day_joining_exactly_on_the_billing_day_is_a_full_period(c):
    g = await c.group("fixed_day", 14)
    e = await c.enroll(c.s1, g, d(2026, 10, 14))
    assert await c.charges(e) == [(d(2026, 10, 14), d(2026, 11, 14), FEE, False)]


async def test_prorate_first_period_off_charges_the_full_price(c):
    g = await c.group("fixed_day", 1, prorate=False)
    e = await c.enroll(c.s1, g, d(2026, 10, 16))
    # Still covers only Oct 16 .. Nov 1, but costs the whole fee.
    assert await c.charges(e) == [(d(2026, 10, 16), d(2026, 11, 1), FEE, False)]
    await c.generate(d(2026, 11, 2))
    assert (await c.charges(e))[1] == (d(2026, 11, 1), d(2026, 12, 1), FEE, False)


async def test_discounts_apply_to_every_period_and_proration(c):
    g = await c.group("fixed_day", 1)
    e = await c.pool.fetchval(
        "insert into enrollments (student_id, group_id, joined_at, discount_kind, discount_value) "
        "values ($1, $2, '2026-10-16', 'percent', 50) returning id", c.s1, g,
    )
    async with c.pool.acquire() as conn:
        group = dict(await conn.fetchrow("select * from groups where id = $1", g))
        enrollment = dict(await conn.fetchrow("select * from enrollments where id = $1", e))
        await money.issue_first_charge(conn, enrollment, group, None)
    await c.generate(d(2026, 11, 2))
    amounts = [row[2] for row in await c.charges(e)]
    assert amounts == [rules.half_up_div(200_000 * 16, 31), 200_000]


# --- student_anniversary ----------------------------------------------------------------------------


async def test_anniversary_billing_follows_each_students_own_day_without_proration(c):
    g = await c.group("student_anniversary")
    e = await c.enroll(c.s1, g, d(2026, 10, 14))
    assert await c.charges(e) == [(d(2026, 10, 14), d(2026, 11, 14), FEE, False)]
    await c.generate(d(2026, 12, 20))
    assert [(a, b) for a, b, *_ in await c.charges(e)] == [
        (d(2026, 10, 14), d(2026, 11, 14)), (d(2026, 11, 14), d(2026, 12, 14)), (d(2026, 12, 14), d(2027, 1, 14)),
    ]
    assert all(amount == FEE and not pro for _, _, amount, pro in await c.charges(e))
    # Two students in one anniversary group bill on different days.
    e2 = await c.enroll(c.s2, g, d(2026, 10, 25))
    await c.generate(d(2026, 11, 20))
    assert [a for a, *_ in await c.charges(e2)] == [d(2026, 10, 25)]


async def test_anniversary_from_the_31st_uses_the_last_day_of_short_months(c):
    g = await c.group("student_anniversary")
    e = await c.enroll(c.s1, g, d(2027, 1, 31))
    await c.generate(d(2027, 4, 30))
    assert [a for a, *_ in await c.charges(e)] == [d(2027, 1, 31), d(2027, 2, 28), d(2027, 3, 31), d(2027, 4, 30)]
    # A leap year gives February 29, and the 31st comes back after it.
    e2 = await c.enroll(c.s2, g, d(2028, 1, 31))
    await c.generate(d(2028, 3, 31))
    assert [a for a, *_ in await c.charges(e2)][-3:] == [d(2028, 1, 31), d(2028, 2, 29), d(2028, 3, 31)]


# --- two groups, two modes ----------------------------------------------------------------------------


async def test_a_student_in_two_groups_with_different_billing_modes(c):
    fixed = await c.group("fixed_day", 1, name="Belgilangan kun")
    anniversary = await c.group("student_anniversary", fee=300_000, name="Yil kuni")
    ea = await c.enroll(c.s1, fixed, d(2026, 10, 16))
    eb = await c.enroll(c.s1, anniversary, d(2026, 10, 20))
    await c.generate(d(2026, 11, 25))
    first = rules.half_up_div(FEE * 16, 31)
    assert await c.charges(ea) == [
        (d(2026, 10, 16), d(2026, 11, 1), first, True), (d(2026, 11, 1), d(2026, 12, 1), FEE, False),
    ]
    assert await c.charges(eb) == [
        (d(2026, 10, 20), d(2026, 11, 20), 300_000, False), (d(2026, 11, 20), d(2026, 12, 20), 300_000, False),
    ]
    # One balance for the student; a payment pays the oldest period first,
    # whichever group it belongs to: Oct 16 (A), Oct 20 (B), Nov 1 (A), Nov 20 (B).
    total = first + 300_000 + FEE + 300_000
    assert (await money.student_balance(c.pool, c.s1))["balance"] == -total
    await record(c, student_id=c.s1, amount=first + 100_000, method="cash", user_id=None)
    owed = {r["enrollment_id"]: r["owed"] for r in await c.pool.fetch(
        "select enrollment_id, sum(owed) as owed from charge_balances where status = 'active' group by 1")}
    assert owed == {ea: FEE, eb: 200_000 + 300_000}
    # Each enrollment's next due date comes from its own group's rule.
    async with c.pool.acquire() as conn:
        due = await money.next_due_dates(conn, [ea, eb], today=d(2026, 11, 25))
    assert due == {ea: d(2026, 12, 1), eb: d(2026, 12, 20)}


# --- leaving ---------------------------------------------------------------------------------------------


async def test_leaving_mid_cycle_stops_future_charges_and_keeps_the_old_ones(c):
    g = await c.group("fixed_day", 1)
    e = await c.enroll(c.s1, g, d(2026, 9, 20))
    await c.generate(d(2026, 12, 5))  # Oct 1, Nov 1, Dec 1 as well
    assert len(await c.charges(e)) == 4
    before = await c.pool.fetchval("select count(*) from charges")

    # Leaves on Nov 10: November (already started) stays owed; December goes.
    await c.pool.execute("update enrollments set status = 'withdrawn', ended_at = $2 where id = $1", e, d(2026, 11, 10))
    async with c.pool.acquire() as conn:
        cancelled = await money.cancel_charges_after(conn, e, d(2026, 11, 10), "O'quvchi guruhdan chiqdi", None)
    assert cancelled == 1
    assert [a for a, *_ in await c.charges(e)] == [d(2026, 9, 20), d(2026, 10, 1), d(2026, 11, 1)]
    # Nothing was deleted: the cancelled charge is still there, with its reason.
    assert await c.pool.fetchval("select count(*) from charges") == before
    row = await c.pool.fetchrow("select status, cancel_reason from charges where period_start = '2026-12-01'")
    assert (row["status"], row["cancel_reason"]) == ("cancelled", "O'quvchi guruhdan chiqdi")
    # And no further charges come, however long the server runs.
    assert await c.generate(d(2027, 6, 1)) == 0
    assert await c.pool.fetchval("select count(*) from charges") == before


async def test_leaving_an_anniversary_group_mid_cycle_works_the_same(c):
    g = await c.group("student_anniversary")
    e = await c.enroll(c.s1, g, d(2026, 9, 14))
    await c.generate(d(2026, 12, 20))  # Oct 14, Nov 14, Dec 14
    await c.pool.execute("update enrollments set status = 'withdrawn', ended_at = $2 where id = $1", e, d(2026, 11, 20))
    async with c.pool.acquire() as conn:
        await money.cancel_charges_after(conn, e, d(2026, 11, 20), "chiqdi", None)
    assert [a for a, *_ in await c.charges(e)] == [d(2026, 9, 14), d(2026, 10, 14), d(2026, 11, 14)]


async def test_a_paid_charge_that_is_cancelled_returns_the_money_as_credit(c):
    g = await c.group("fixed_day", 1)
    e = await c.enroll(c.s1, g, d(2026, 10, 1))
    await c.generate(d(2026, 11, 2))
    await record(c, student_id=c.s1, amount=2 * FEE, method="cash", user_id=None)
    assert (await money.student_balance(c.pool, c.s1))["balance"] == 0
    async with c.pool.acquire() as conn:
        await money.cancel_charges_after(conn, e, d(2026, 11, 1), "chiqdi", None)
    assert (await money.student_balance(c.pool, c.s1))["balance"] == FEE  # credit


async def test_changing_the_billing_grid_never_bills_old_periods_again(c):
    # A group that billed on the 30th (carried over from before) now bills on
    # the 28th: the periods already charged are not charged a second time.
    g = await c.group("fixed_day", 28)
    e = await c.enroll(c.s1, g, d(2026, 9, 3), first_charge=False)
    async with c.pool.acquire() as conn:
        for start, end in ((d(2026, 9, 3), d(2026, 9, 30)), (d(2026, 9, 30), d(2026, 10, 30))):
            await money.create_charge(conn, enrollment_id=e, period_start=start, period_end=end, amount=FEE, base_fee=FEE)
    await c.generate(d(2026, 11, 29))
    assert [a for a, *_ in await c.charges(e)] == [d(2026, 9, 3), d(2026, 9, 30), d(2026, 11, 28)]


# --- next due date --------------------------------------------------------------------------------------


async def test_enrollments_expose_next_due_date(c):
    g = await c.group("fixed_day", 14)
    e = await c.enroll(c.s1, g, clock.today() - timedelta(days=100), first_charge=False)
    expected = rules.next_due_date("fixed_day", 14, clock.today() - timedelta(days=100), clock.today())
    listed = (await c.api.client.get(f"/enrollments/by-student/{c.s1}")).json()
    assert listed[0]["next_due_date"] == expected.isoformat()
    roster = (await c.api.client.get(f"/groups/{g}/roster")).json()
    assert roster[0]["next_due_date"] == expected.isoformat()
    assert e


async def test_a_student_whose_day_is_today_counts_on_the_dashboard(c):
    today = clock.today()
    if today.day > 28:
        pytest.skip("a fixed billing day only goes up to the 28th")
    g = await c.group("fixed_day", today.day)
    await c.enroll(c.s1, g, today - timedelta(days=45), first_charge=False)
    await c.generate(today)
    summary = (await c.api.client.get("/dashboard")).json()
    assert summary["due_today_count"] == 1 and summary["due_today_amount"] == FEE


# --- groups API --------------------------------------------------------------------------------------------


async def test_group_billing_is_validated_and_locked_once_charged(c):
    payload = {"subject_id": c.subject, "name": "Yangi", "fee_amount": FEE}
    for bad in ({"billing_mode": "weekly"}, {"billing_mode": "fixed_day"}, {"billing_mode": "fixed_day", "billing_day": 29},
                {"billing_mode": "fixed_day", "billing_day": 0}):
        assert (await c.api.client.post("/groups", json={**payload, **bad})).status_code == 400, bad
    fixed = await c.api.client.post("/groups", json={**payload, "billing_mode": "fixed_day", "billing_day": 14})
    assert fixed.status_code == 201, fixed.text
    assert (fixed.json()["billing_mode"], fixed.json()["billing_day"], fixed.json()["prorate_first_period"]) == ("fixed_day", 14, True)
    anniversary = await c.api.client.post("/groups", json={**payload, "name": "Yil", "billing_mode": "student_anniversary"})
    assert anniversary.status_code == 201 and anniversary.json()["billing_day"] is None
    # Older builds send due_day: it becomes the billing day (capped at 28).
    legacy = await c.api.client.post("/groups", json={**payload, "name": "Eski", "due_day": 31})
    assert legacy.json()["billing_day"] == 28

    gid = fixed.json()["id"]
    assert (await c.api.client.patch(f"/groups/{gid}", json={"billing_day": 20})).status_code == 200  # no charges yet
    await c.enroll(c.s1, gid, d(2026, 10, 16))
    refused = await c.api.client.patch(f"/groups/{gid}", json={"billing_day": 5})
    assert refused.status_code == 409
    assert (await c.api.client.patch(f"/groups/{gid}", json={"prorate_first_period": False})).status_code == 200


# --- teacher pay ---------------------------------------------------------------------------------------------


def this_month() -> date:
    return clock.today().replace(day=1)


async def pay_for(c, student, group, amount):
    e = await c.enroll(student, group, this_month() - timedelta(days=40), first_charge=False)
    async with c.pool.acquire() as conn:
        await money.create_charge(
            conn, enrollment_id=e, period_start=this_month(), period_end=rules.next_month(this_month()),
            amount=amount, base_fee=amount,
        )
    await record(c, student_id=student, amount=amount, method="cash", user_id=None)
    return e


async def month(c, m=None):
    async with c.pool.acquire() as conn:
        report = await money.salary_month(conn, m or this_month())
    return {t["teacher_id"]: t for t in report["teachers"]}, report


async def set_rule(c, kind, id_, method, percent=None, fixed=None):
    async with c.pool.acquire() as conn:
        fn = money.set_teacher_rule if kind == "teacher" else money.set_group_rule
        await fn(conn, id_, method, percent, fixed, c.api.owner_id)


async def test_percent_pay_is_a_share_of_what_was_paid(c):
    g = await c.group()
    await pay_for(c, c.s1, g, FEE)
    teachers, _ = await month(c)
    assert teachers[c.teacher]["earned"] == 120_000  # 30% of 400 000
    assert teachers[c.teacher]["salary_method"] == "percent"


async def test_fixed_pay_is_the_same_whatever_was_paid(c):
    g = await c.group()
    await set_rule(c, "teacher", c.teacher, "fixed", fixed=3_000_000)
    # Nobody has paid: the fixed amount still accrues.
    teachers, report = await month(c)
    t = teachers[c.teacher]
    assert (t["earned"], t["collected"], t["salary_method"], t["salary_fixed"]) == (3_000_000, 0, "fixed", 3_000_000)
    assert [(l["method"], l["student_name"], l["share"]) for l in t["lines"]] == [("fixed", "Qat'iy oylik", 3_000_000)]
    # Students paying adds nothing on top of a fixed salary.
    await pay_for(c, c.s1, g, FEE)
    teachers, _ = await month(c)
    assert teachers[c.teacher]["earned"] == 3_000_000
    assert teachers[c.teacher]["collected"] == FEE
    # Two groups, still one fixed amount a month for the teacher.
    g2 = await c.group(name="Ikkinchi")
    await pay_for(c, c.s2, g2, FEE)
    assert (await month(c))[0][c.teacher]["earned"] == 3_000_000
    # Months that haven't come don't accrue.
    assert (await month(c, rules.next_month(this_month())))[0][c.teacher]["earned"] == 0
    # Nor an inactive teacher.
    await c.pool.execute("update teachers set is_active = false where id = $1", c.teacher)
    assert (await month(c))[0][c.teacher]["earned"] == 0


async def test_a_group_percent_wins_over_a_fixed_teacher_and_adds_to_it(c):
    g1 = await c.group(name="Birinchi")
    g2 = await c.group(name="Ikkinchi")
    await set_rule(c, "teacher", c.teacher, "fixed", fixed=3_000_000)
    await set_rule(c, "group", g1, "percent", percent=50)
    await pay_for(c, c.s1, g1, FEE)  # 50% of 400 000 by the group's own rule
    await pay_for(c, c.s2, g2, FEE)  # the teacher is fixed: this earns nothing extra
    t = (await month(c))[0][c.teacher]
    assert t["earned"] == 3_000_000 + 200_000
    by_group = {(l["group_id"], l["method"]): l["share"] for l in t["lines"]}
    assert by_group[(g1, "percent")] == 200_000
    assert by_group[(g2, "percent")] == 0
    assert by_group[(None, "fixed")] == 3_000_000


async def test_a_group_fixed_amount_wins_over_the_teachers_percent(c):
    g1 = await c.group(name="Birinchi")
    g2 = await c.group(name="Ikkinchi")
    await set_rule(c, "group", g1, "fixed", fixed=500_000)
    await pay_for(c, c.s1, g1, FEE)  # the group is fixed: its payments earn no percent
    await pay_for(c, c.s2, g2, FEE)  # the teacher's 30% applies here
    t = (await month(c))[0][c.teacher]
    assert t["earned"] == 500_000 + 120_000
    # Clearing the group's rule goes back to the teacher's.
    await set_rule(c, "group", g1, None)
    assert (await month(c))[0][c.teacher]["earned"] == 240_000


async def test_a_mixed_center_teachers_paid_each_their_own_way(c):
    fixed_teacher = await c.pool.fetchval(
        "insert into teachers (full_name, salary_method, salary_fixed) values ('Jasur', 'fixed', 2000000) returning id"
    )
    g_percent = await c.group(name="Foizli")
    g_fixed = await c.group(name="Qat'iy", teacher=fixed_teacher)
    await pay_for(c, c.s1, g_percent, FEE)
    await pay_for(c, c.s2, g_fixed, FEE)
    teachers, report = await month(c)
    assert teachers[c.teacher]["earned"] == 120_000
    assert teachers[fixed_teacher]["earned"] == 2_000_000
    assert report["total_earned"] == 2_120_000


async def test_closing_the_month_freezes_percent_and_fixed_lines(c):
    g1 = await c.group(name="Birinchi")
    await set_rule(c, "teacher", c.teacher, "fixed", fixed=3_000_000)
    await set_rule(c, "group", g1, "percent", percent=50)
    await pay_for(c, c.s1, g1, FEE)
    async with c.pool.acquire() as conn:
        closed = await money.close_month(conn, this_month(), c.api.owner_id)
    assert closed["closed"] and closed["total_earned"] == 3_200_000
    # Whatever changes afterwards, the closed month stays.
    await set_rule(c, "teacher", c.teacher, "percent", percent=10)
    await set_rule(c, "group", g1, "fixed", fixed=1)
    t = (await month(c))[0][c.teacher]
    assert t["earned"] == 3_200_000
    assert sorted((l["method"], l["share"]) for l in t["lines"]) == [("fixed", 3_000_000), ("percent", 200_000)]
    assert [l["percent"] for l in t["lines"] if l["method"] == "percent"] == [50.0]


async def test_pay_rules_are_validated_and_owner_only(c):
    for method, percent, fixed in (("weekly", None, None), ("percent", None, None), ("percent", 101, None),
                                   ("fixed", None, None), ("fixed", None, -5)):
        async with c.pool.acquire() as conn:
            with pytest.raises(Exception):
                await money.set_teacher_rule(conn, c.teacher, method, percent, fixed, None)
    g = await c.group()
    owner = await c.api.client.put(f"/finance/teachers/{c.teacher}/salary", json={"method": "fixed", "fixed": 1_500_000})
    assert owner.status_code == 200, owner.text
    assert (owner.json()["salary_method"], owner.json()["salary_fixed"]) == ("fixed", 1_500_000)
    assert (await c.api.client.put(f"/finance/groups/{g}/salary", json={"method": "percent", "percent": 40})).status_code == 204
    async with c.api.as_admin() as admin:
        assert (await admin.put(f"/finance/teachers/{c.teacher}/salary", json={"method": None})).status_code == 403
        assert (await admin.put(f"/finance/groups/{g}/salary", json={"method": None})).status_code == 403
        assert (await admin.post("/finance/salaries/close", params={"month": this_month().isoformat()})).status_code == 403
        # Seeing the pay is open to the admin.
        shown = (await admin.get("/finance/salaries")).json()
        assert next(t for t in shown["teachers"] if t["teacher_id"] == c.teacher)["salary_fixed"] == 1_500_000
    assert await c.pool.fetchval("select count(*) from audit_log where action = 'set_salary_rule'") == 2


# --- the free trial ---------------------------------------------------------------------------------------------


async def attend(api, booking):
    await move_to_past(api.pool, booking["session"]["id"])
    response = await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})
    assert response.status_code == 200, response.text


async def test_one_free_trial_per_person_and_only_the_owner_allows_a_second(api):
    ids = await seed_admissions(api)
    other_subject = {"subject_id": ids["other_subject_id"]}
    lead = await new_lead(api, subject_id=ids["subject_id"])
    first = await book(api, lead["id"], ids["teacher_id"])
    await attend(api, first)
    # A trial is free: no charge, no debt, no student.
    assert await api.pool.fetchval("select count(*) from charges") == 0
    assert await api.pool.fetchval("select count(*) from students") == 0

    # The same person (same phone) for another subject: the admin is refused...
    again = await new_lead(api, subject_id=ids["other_subject_id"])
    async with api.as_admin() as admin:
        refused = await admin.post(
            "/trial-bookings", json={"lead_id": again["id"], "session": session_payload(ids["other_teacher_id"], hours=48)}
        )
        assert refused.status_code == 403
        assert "egasi" in refused.json()["detail"]
    assert other_subject
    # ...the owner can, and it is on the record.
    second = await book(api, again["id"], ids["other_teacher_id"], hours=48)
    assert second["status"] == "scheduled"
    audit = await api.pool.fetchrow("select user_id, action from audit_log where action = 'extra_trial'")
    assert audit["user_id"] == api.owner_id


async def test_cancelled_moved_or_missed_trials_do_not_use_up_the_free_one(api):
    ids = await seed_admissions(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    first = await book(api, lead["id"], ids["teacher_id"])
    # Moving it is not a new trial, even for the admin.
    async with api.as_admin() as admin:
        moved = await admin.post(
            f"/trial-bookings/{first['id']}/reschedule", json={"session": session_payload(ids["teacher_id"], hours=72)}
        )
        assert moved.status_code == 201, moved.text
        # Cancelled: the person still has their free trial.
        cancelled = await admin.post(f"/trial-bookings/{moved.json()['id']}/cancel", json={"reason": "Kela olmaydi"})
        assert cancelled.status_code == 200
        retry = await admin.post(
            "/trial-bookings", json={"lead_id": lead["id"], "session": session_payload(ids["teacher_id"], hours=96)}
        )
        assert retry.status_code == 201, retry.text
        # Missed it (absent): still free to try again.
        await move_to_past(api.pool, retry.json()["session"]["id"])
        missed = await admin.post(f"/trial-bookings/{retry.json()['id']}/attendance", json={"status": "absent"})
        assert missed.status_code == 200
        once_more = await admin.post(
            "/trial-bookings", json={"lead_id": lead["id"], "session": session_payload(ids["teacher_id"], hours=120)}
        )
        assert once_more.status_code == 201, once_more.text


async def test_the_trial_limit_is_a_setting(api):
    ids = await seed_admissions(api)
    async with api.pool.acquire() as conn:
        await money.update_settings(conn, api.owner_id, trial_limit_per_person=2)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    first = await book(api, lead["id"], ids["teacher_id"])
    await attend(api, first)
    async with api.as_admin() as admin:
        second = await admin.post(
            "/trial-bookings", json={"lead_id": lead["id"], "session": session_payload(ids["teacher_id"], hours=48)}
        )
        assert second.status_code == 201, second.text
    assert PHONE
