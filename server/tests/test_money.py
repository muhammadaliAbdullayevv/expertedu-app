"""Charges, payments, allocation, balances and teacher salary against a real
database. Salary tests use a 30% teacher percent."""

import asyncio
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import asyncpg
import pytest

from app import clock
from app.money import rules, service as money

pytestmark = pytest.mark.anyio

M = clock.today().replace(day=1)  # this month
P = (M - timedelta(days=1)).replace(day=1)  # last month
N = rules.next_month(M)  # next month


def at(month: date, day: int = 15) -> datetime:
    """Noon in Tashkent on that day, as a timestamp."""
    return datetime(month.year, month.month, day, 7, 0, tzinfo=timezone.utc)


class World:
    """Two teachers at 30%, a group each, two students."""

    def __init__(self, api):
        self.api = api
        self.pool = api.pool

    async def build(self):
        pool = self.pool
        subject = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
        self.t1 = await pool.fetchval("insert into teachers (full_name, salary_method, salary_percent) values ('Dilnoza', 'percent', 30) returning id")
        self.t2 = await pool.fetchval("insert into teachers (full_name, salary_method, salary_percent) values ('Jasur', 'percent', 30) returning id")
        self.t3 = await pool.fetchval("insert into teachers (full_name, salary_method, salary_percent) values ('Bahor', 'percent', 30) returning id")
        self.g1 = await self.group(subject, "IELTS", self.t1, 400000)
        self.g2 = await self.group(subject, "Speaking", self.t2, 300000)
        self.s1 = await self.student("Aziz", "998901000001")
        self.s2 = await self.student("Bobur", "998901000002")
        return self

    async def group(self, subject, name, teacher, fee):
        return await self.pool.fetchval(
            "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) values ($1, $2, $3, $4, 1) returning id",
            subject, name, teacher, fee,
        )

    async def student(self, name, phone):
        return await self.pool.fetchval(
            "insert into students (full_name, phone) values ($1, $2) returning id", name, phone
        )

    async def enroll(self, student, group, joined=None):
        return await self.pool.fetchval(
            "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, $3) returning id",
            student, group, joined or (P - timedelta(days=40)),
        )

    async def charge(self, enrollment, month, amount, due=None):
        async with self.pool.acquire() as conn:
            return await money.create_charge(
                conn, enrollment_id=enrollment, period_start=due or month,
                period_end=(due or month) + timedelta(days=30), amount=amount, base_fee=amount
            )

    async def pay(self, student, amount, received_at=None, method="cash"):
        async with self.pool.acquire() as conn:
            return await money.record_payment(
                conn, student_id=student, amount=amount, method=method, user_id=self.api.owner_id, received_at=received_at
            )

    async def balance(self, student):
        async with self.pool.acquire() as conn:
            return await money.student_balance(conn, student)

    async def salary(self, month):
        async with self.pool.acquire() as conn:
            report = await money.salary_month(conn, month)
        return {t["teacher_id"]: t for t in report["teachers"]}

    async def owed(self, charge):
        return await self.pool.fetchval("select owed from charge_balances where charge_id = $1", charge)


@pytest.fixture
async def w(api):
    return await World(api).build()


# --- Charges ------------------------------------------------------------------------------------


async def test_a_period_is_charged_once_per_enrollment(w):
    e = await w.enroll(w.s1, w.g1)
    assert await w.charge(e, M, 400000) is not None
    assert await w.charge(e, M, 999) is None
    assert await w.pool.fetchval("select count(*) from charges") == 1
    # Another period is its own charge.
    assert await w.charge(e, N, 400000) is not None


async def test_generating_charges_is_idempotent_and_applies_discounts(w):
    joined = P.replace(day=10)
    e = await w.enroll(w.s1, w.g1, joined)
    await w.pool.execute("update enrollments set discount_kind = 'percent', discount_value = 25 where id = $1", e)
    async with w.pool.acquire() as conn:
        first = await money.generate_charges(conn, clock.today())
        again = await money.generate_charges(conn, clock.today())
    # Group billing day is 1: the first stretch (Prorated, joined on the 10th)
    # and this month's period.
    assert first == 2 and again == 0
    rows = await w.pool.fetch(
        "select period_start, period_end, amount, base_fee, discount_amount, is_prorated from charges order by period_start"
    )
    cycle = (M - P).days
    expected_first = rules.half_up_div(300000 * (M - joined).days, cycle)
    assert [(r["period_start"], r["period_end"], r["amount"], r["is_prorated"]) for r in rows] == [
        (joined, M, expected_first, True),
        (M, rules.next_month(M), 300000, False),
    ]
    assert (rows[1]["base_fee"], rows[1]["discount_amount"]) == (400000, 100000)


async def test_a_cancelled_charge_is_not_generated_again(w):
    e = await w.enroll(w.s1, w.g1, P.replace(day=10))
    async with w.pool.acquire() as conn:
        await money.generate_charges(conn, clock.today())
        charge_id = await conn.fetchval("select id from charges where period_start = $1", M)
        await money.cancel_charge(conn, charge_id, "Xato yaratilgan", w.api.owner_id)
        assert await money.generate_charges(conn, clock.today()) == 0
    row = await w.pool.fetchrow("select status, cancel_reason from charges where id = $1", charge_id)
    assert (row["status"], row["cancel_reason"]) == ("cancelled", "Xato yaratilgan")
    assert e


async def test_the_first_charge_follows_the_group_and_the_persons_choice(w):
    start = M.replace(day=16)
    e = await w.enroll(w.s1, w.g1, start)
    async with w.pool.acquire() as conn:
        group = dict(await conn.fetchrow("select * from groups where id = $1", w.g1))
        enrollment = dict(await conn.fetchrow("select * from enrollments where id = $1", e))
        amount = await money.issue_first_charge(conn, enrollment, group, w.api.owner_id)
    next_first = rules.next_month(M)
    assert amount == rules.half_up_div(400000 * (next_first - start).days, (next_first - M).days)

    # The group's prorate_first_period switch: off, the first charge is the full price.
    await w.pool.execute("update groups set prorate_first_period = false where id = $1", w.g1)
    async with w.pool.acquire() as conn:
        group = dict(await conn.fetchrow("select * from groups where id = $1", w.g1))
        e2 = await conn.fetchval(
            "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, $3) returning id", w.s2, w.g1, start
        )
        enrollment2 = dict(await conn.fetchrow("select * from enrollments where id = $1", e2))
        assert await money.issue_first_charge(conn, enrollment2, group, None) == 400000
        # An explicit choice for this student beats the group's setting.
        e3 = await conn.fetchval(
            "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, $3) returning id", w.s2, w.g2, start
        )
        enrollment3 = dict(await conn.fetchrow("select * from enrollments where id = $1", e3))
        group2 = dict(await conn.fetchrow("select * from groups where id = $1", w.g2))
        assert await money.issue_first_charge(conn, enrollment3, group2, None, "full") == 300000


async def test_settings_are_validated_and_audited(w):
    async with w.pool.acquire() as conn:
        with pytest.raises(Exception):
            await money.update_settings(conn, w.api.owner_id, trial_limit_per_person=0)
        updated = await money.update_settings(conn, w.api.owner_id, trial_limit_per_person=2)
        assert updated.trial_limit_per_person == 2
        assert (await money.get_settings(conn)).trial_limit_per_person == 2
    assert await w.pool.fetchval("select count(*) from audit_log where entity = 'settings'") == 1


# --- Payments, allocation, balance ------------------------------------------------------------


async def test_payments_pay_the_oldest_charge_first_and_overpayment_is_credit(w):
    e = await w.enroll(w.s1, w.g1)
    c_old = await w.charge(e, P, 400000)
    c_new = await w.charge(e, M, 400000)

    await w.pay(w.s1, 300000)
    assert (await w.owed(c_old), await w.owed(c_new)) == (100000, 400000)
    assert await w.balance(w.s1) == {"paid": 300000, "charged": 800000, "balance": -500000}

    payment = await w.pay(w.s1, 700000)
    # 100 000 finishes the old charge, 400 000 pays the new one, 200 000 is credit.
    assert (await w.owed(c_old), await w.owed(c_new)) == (0, 0)
    assert (payment["allocated"], payment["credit"]) == (500000, 200000)
    assert (await w.balance(w.s1))["balance"] == 200000

    # The credit pays the next charge the moment it exists.
    c_next = await w.charge(e, N, 400000)
    assert await w.owed(c_next) == 200000
    assert (await w.balance(w.s1))["balance"] == -200000


async def test_a_payment_pays_the_oldest_charge_across_a_students_groups(w):
    e1 = await w.enroll(w.s1, w.g1)
    e2 = await w.enroll(w.s1, w.g2)
    c1 = await w.charge(e1, P, 400000)
    c2 = await w.charge(e2, P, 300000)
    await w.pay(w.s1, 500000)
    assert (await w.owed(c1), await w.owed(c2)) == (0, 200000)


async def test_balance_is_computed_not_stored(w):
    columns = await w.pool.fetch(
        "select column_name from information_schema.columns where table_name in ('students', 'enrollments', 'charges', 'payments')"
    )
    assert not [c for c in columns if "balance" in c["column_name"]]
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    assert (await w.balance(w.s1))["balance"] == -400000


async def test_payment_needs_a_positive_amount_and_a_known_method(w):
    for amount, method in ((0, "cash"), (-5, "cash"), (1000, "bitcoin")):
        with pytest.raises(Exception):
            await w.pay(w.s1, amount, method=method)
    assert await w.pool.fetchval("select count(*) from payments") == 0
    payment = await w.pay(w.s1, 1000, method="click_payme")
    assert payment["receipt_no"].startswith("R-") and payment["method"] == "click_payme"
    second = await w.pay(w.s1, 1000)
    assert second["receipt_no"] != payment["receipt_no"]


async def test_concurrent_payments_never_overpay_a_charge(w):
    e = await w.enroll(w.s1, w.g1)
    c1 = await w.charge(e, P, 400000)
    c2 = await w.charge(e, M, 400000)
    await asyncio.gather(*(w.pay(w.s1, 300000) for _ in range(3)))
    owed = [await w.owed(c1), await w.owed(c2)]
    assert owed == [0, 0] and (await w.balance(w.s1))["balance"] == 100000
    total = await w.pool.fetchval("select sum(amount) from payment_allocations")
    assert total == 800000


# --- Cancelling ----------------------------------------------------------------------------------------


async def test_cancelling_a_payment_reverses_it_and_keeps_the_record(w):
    e = await w.enroll(w.s1, w.g1)
    charge = await w.charge(e, M, 400000)
    payment = await w.pay(w.s1, 400000)
    assert await w.owed(charge) == 0

    blank = await w.api.client.post(f"/payments/{payment['id']}/cancel", json={"reason": "  "})
    assert blank.status_code == 400

    response = await w.api.client.post(f"/payments/{payment['id']}/cancel", json={"reason": "Xato kiritildi"})
    assert response.status_code == 200, response.text
    assert response.json()["kind"] == "reversal"

    assert await w.owed(charge) == 400000
    assert await w.balance(w.s1) == {"paid": 0, "charged": 400000, "balance": -400000}
    original = await w.pool.fetchrow("select status, cancelled_by, cancel_reason from payments where id = $1", payment["id"])
    assert (original["status"], original["cancelled_by"], original["cancel_reason"]) == ("cancelled", w.api.owner_id, "Xato kiritildi")
    assert await w.pool.fetchval("select count(*) from payments where kind = 'reversal' and reverses_id = $1", payment["id"]) == 1
    assert await w.pool.fetchval("select sum(amount) from payment_allocations where payment_id = $1", payment["id"]) == 0
    audit = await w.pool.fetchrow("select user_id, action, reason from audit_log where entity = 'payment'")
    assert (audit["user_id"], audit["action"], audit["reason"]) == (w.api.owner_id, "cancel", "Xato kiritildi")

    again = await w.api.client.post(f"/payments/{payment['id']}/cancel", json={"reason": "yana"})
    assert again.status_code == 409


async def test_a_cancelled_payment_is_not_reused_but_later_payments_work(w):
    e = await w.enroll(w.s1, w.g1)
    charge = await w.charge(e, M, 400000)
    payment = await w.pay(w.s1, 400000)
    async with w.pool.acquire() as conn:
        await money.cancel_payment(conn, payment["id"], "Xato", w.api.owner_id)
    await w.pay(w.s1, 150000)
    assert await w.owed(charge) == 250000


async def test_cancelling_a_charge_returns_what_it_had_received_as_credit(w):
    e = await w.enroll(w.s1, w.g1)
    c_old = await w.charge(e, P, 400000)
    c_new = await w.charge(e, M, 400000)
    await w.pay(w.s1, 400000)  # pays c_old
    async with w.pool.acquire() as conn:
        await money.cancel_charge(conn, c_old, "Noto'g'ri oy", w.api.owner_id)
    # The money moves on to the next unpaid charge.
    assert await w.owed(c_new) == 0
    assert (await w.balance(w.s1))["balance"] == 0


async def test_money_is_never_deleted_and_allocations_are_never_edited(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 100000)
    async with w.pool.acquire() as conn:
        await money.audit(conn, w.api.owner_id, "test", 1, "x")
    for statement in (
        "delete from charges",
        "delete from payments",
        "delete from payment_allocations",
        "update payment_allocations set amount = 1",
        "delete from audit_log",
    ):
        with pytest.raises(asyncpg.RaiseError):
            await w.pool.execute(statement)


async def test_leaving_cancels_later_months_with_a_reason_instead_of_deleting(w):
    e = await w.enroll(w.s1, w.g1)
    first = await w.charge(e, P, 400000)
    later = await w.charge(e, N, 400000)
    response = await w.api.client.post(f"/enrollments/{e}/withdraw")
    assert response.status_code == 200, response.text
    rows = {r["id"]: r for r in await w.pool.fetch("select id, status, cancel_reason from charges")}
    assert rows[first]["status"] == "active"
    assert (rows[later]["status"], rows[later]["cancel_reason"]) == ("cancelled", "O'quvchi guruhdan chiqdi")
    assert len(rows) == 2


async def test_joining_and_leaving_the_same_day_owes_nothing(w):
    response = await w.api.client.get("/groups")
    assert response.status_code == 200
    created = await w.api.client.post(
        "/enrollments", json={"student_id": w.s1, "group_id": w.g1, "joined_at": clock.today().isoformat()}
    )
    assert created.status_code == 201, created.text
    assert await w.pool.fetchval("select count(*) from charges where status = 'active'") == 1
    await w.api.client.post(f"/enrollments/{created.json()['id']}/withdraw")
    assert await w.pool.fetchval("select count(*) from charges where status = 'active'") == 0
    assert (await w.balance(w.s1))["balance"] == 0


# --- Debt age ----------------------------------------------------------------------------------------------


async def test_debtors_carry_the_age_of_their_oldest_unpaid_charge(w):
    e1 = await w.enroll(w.s1, w.g1)
    e2 = await w.enroll(w.s2, w.g1)
    today = clock.today()
    await w.charge(e1, rules.month_start(today - timedelta(days=45)), 400000, due=today - timedelta(days=45))
    await w.charge(e2, rules.month_start(today - timedelta(days=10)), 400000, due=today - timedelta(days=10))
    debtors = {d["student_id"]: d for d in (await w.api.client.get("/debtors")).json()}
    assert (debtors[w.s1]["days_overdue"], debtors[w.s1]["age_bucket"]) == (45, "30+")
    assert (debtors[w.s2]["days_overdue"], debtors[w.s2]["age_bucket"]) == (10, "8-30")
    # Paying clears it.
    await w.pay(w.s1, 400000)
    assert w.s1 not in {d["student_id"] for d in (await w.api.client.get("/debtors")).json()}


# --- Salary (30%) --------------------------------------------------------------------------------------------


async def test_salary_is_a_percent_of_what_was_paid_and_unpaid_study_adds_nothing(w):
    e1 = await w.enroll(w.s1, w.g1)
    e2 = await w.enroll(w.s2, w.g1)
    await w.charge(e1, M, 400000)
    await w.charge(e2, M, 400000)  # studies, hasn't paid
    await w.pay(w.s1, 400000)
    month = await w.salary(M)
    teacher = month[w.t1]
    assert (teacher["collected"], teacher["earned"]) == (400000, 120000)
    assert [(l["student_name"], l["share"]) for l in teacher["lines"]] == [("Aziz", 120000)]


async def test_a_partial_payment_earns_its_share(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 100000)
    assert (await w.salary(M))[w.t1]["earned"] == 30000


async def test_a_late_payment_counts_in_the_month_it_is_received(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, P, 400000)
    await w.pay(w.s1, 400000)  # received now, for last month's charge
    assert (await w.salary(P))[w.t1]["earned"] == 0
    assert (await w.salary(M))[w.t1]["earned"] == 120000


async def test_a_payment_received_last_month_counts_last_month(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, P, 400000)
    await w.pay(w.s1, 400000, received_at=at(P))
    assert (await w.salary(P))[w.t1]["earned"] == 120000
    assert (await w.salary(M))[w.t1]["earned"] == 0


async def test_a_cancelled_payment_reduces_the_month_it_is_cancelled_in(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, P, 400000)
    payment = await w.pay(w.s1, 400000, received_at=at(P))
    async with w.pool.acquire() as conn:
        await money.cancel_payment(conn, payment["id"], "Qaytarildi", w.api.owner_id)
    # Last month still shows what was received then; this month gives it back.
    assert (await w.salary(P))[w.t1]["earned"] == 120000
    assert (await w.salary(M))[w.t1]["earned"] == -120000


async def test_a_student_in_two_groups_pays_each_teacher_for_their_own_group(w):
    e1 = await w.enroll(w.s1, w.g1)
    e2 = await w.enroll(w.s1, w.g2)
    await w.charge(e1, M, 400000)
    await w.charge(e2, M, 300000)
    await w.pay(w.s1, 700000)
    month = await w.salary(M)
    assert (month[w.t1]["collected"], month[w.t1]["earned"]) == (400000, 120000)
    assert (month[w.t2]["collected"], month[w.t2]["earned"]) == (300000, 90000)


async def test_a_teacher_with_no_paying_students_earns_nothing(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 400000)
    month = await w.salary(M)
    assert (month[w.t3]["earned"], month[w.t3]["lines"], month[w.t3]["remaining"]) == (0, [], 0)


async def test_a_group_percent_overrides_the_teachers(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 400000)
    async with w.pool.acquire() as conn:
        await money.set_group_percent(conn, w.g1, Decimal("50"), w.api.owner_id)
    assert (await w.salary(M))[w.t1]["earned"] == 200000
    async with w.pool.acquire() as conn:
        await money.set_group_percent(conn, w.g1, None, w.api.owner_id)
    assert (await w.salary(M))[w.t1]["earned"] == 120000
    assert await w.pool.fetchval("select count(*) from audit_log where action = 'set_salary_rule'") == 2


async def test_payouts_reduce_what_is_left(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 400000)
    async with w.pool.acquire() as conn:
        await money.close_month(conn, M, w.api.owner_id)
        await money.record_payout(
            conn, teacher_id=w.t1, month=M, amount=100000, paid_on=clock.today(), method="cash", note=None,
            user_id=w.api.owner_id,
        )
    teacher = (await w.salary(M))[w.t1]
    assert (teacher["earned"], teacher["paid"], teacher["remaining"]) == (120000, 100000, 20000)


async def test_a_closed_month_never_changes(w):
    e1 = await w.enroll(w.s1, w.g1)
    e2 = await w.enroll(w.s2, w.g1)
    await w.charge(e1, M, 400000)
    await w.charge(e2, M, 400000)
    first = await w.pay(w.s1, 400000)
    async with w.pool.acquire() as conn:
        closed = await money.close_month(conn, M, w.api.owner_id)
    assert closed["closed"] and closed["total_earned"] == 120000

    # Changing the percent afterwards doesn't touch the closed month...
    async with w.pool.acquire() as conn:
        await money.set_teacher_percent(conn, w.t1, Decimal("50"), w.api.owner_id)
        await money.set_group_percent(conn, w.g1, Decimal("70"), w.api.owner_id)
    after = (await w.salary(M))[w.t1]
    assert after["earned"] == 120000 and after["lines"][0]["percent"] == 30.0

    # ...nor does later money: a payment that would land in it counts next month.
    await w.pay(w.s2, 400000)
    assert (await w.salary(M))[w.t1]["earned"] == 120000
    assert (await w.salary(N))[w.t1]["collected"] == 400000
    # Cancelling a payment from the closed month reduces the next open one.
    async with w.pool.acquire() as conn:
        await money.cancel_payment(conn, first["id"], "Xato", w.api.owner_id)
    assert (await w.salary(M))[w.t1]["earned"] == 120000
    assert (await w.salary(N))[w.t1]["collected"] == 0

    async with w.pool.acquire() as conn:
        with pytest.raises(Exception, match="yopilgan"):
            await money.close_month(conn, M, w.api.owner_id)
        with pytest.raises(Exception, match="Kelajak"):
            await money.close_month(conn, N, w.api.owner_id)
    assert await w.pool.fetchval("select count(*) from audit_log where action = 'close'") == 1


async def test_salary_endpoints_close_and_break_down_a_month(w):
    e = await w.enroll(w.s1, w.g1)
    await w.charge(e, M, 400000)
    await w.pay(w.s1, 400000)
    response = await w.api.client.get("/finance/salaries", params={"month": M.isoformat()})
    teacher = next(t for t in response.json()["teachers"] if t["teacher_id"] == w.t1)
    assert teacher["lines"][0]["student_name"] == "Aziz" and teacher["lines"][0]["percent"] == 30.0

    async with w.api.as_admin() as admin:
        assert (await admin.post("/finance/salaries/close", params={"month": M.isoformat()})).status_code == 403
        assert (await admin.put(f"/finance/groups/{w.g1}/percent", json={"salary_percent": 10})).status_code == 403
    closed = await w.api.client.post("/finance/salaries/close", params={"month": M.isoformat()})
    assert closed.status_code == 200 and closed.json()["closed"] is True
    assert (await w.api.client.post("/finance/salaries/close", params={"month": M.isoformat()})).status_code == 409
    assert (await w.api.client.put(f"/finance/groups/{w.g1}/percent", json={"salary_percent": 101})).status_code == 400


async def test_a_trial_creates_no_charge_payment_or_student(w):
    lead = await w.api.client.post("/leads", json={"full_name": "Sinovchi", "phone": "998907777777"})
    assert lead.status_code in (200, 201), lead.text
    counts = await w.pool.fetchrow(
        "select (select count(*) from charges) c, (select count(*) from payments) p, "
        "(select count(*) from payment_allocations) a"
    )
    assert tuple(counts) == (0, 0, 0)
    assert "Sinovchi" not in {s["full_name"] for s in (await w.api.client.get("/students")).json()}
