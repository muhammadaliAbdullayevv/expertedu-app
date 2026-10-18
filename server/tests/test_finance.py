"""Finance: teachers' percentage of payments, expenses and profit -- owner
only (real database)."""

from datetime import date, datetime, timedelta, timezone

import pytest

from app import clock
from app.money import rules, service as money

pytestmark = pytest.mark.anyio


async def seed(api) -> dict:
    pool = api.pool
    subject = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
    dilnoza = await pool.fetchval("insert into teachers (full_name) values ('Dilnoza') returning id")
    jasur = await pool.fetchval("insert into teachers (full_name) values ('Jasur') returning id")
    group = await pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
        "values ($1, 'IELTS', $2, 400000, 5) returning id",
        subject,
        dilnoza,
    )
    student = await pool.fetchval("insert into students (full_name, phone) values ('Aziz', '998901000001') returning id")
    enrollment = await pool.fetchval(
        "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, $3) returning id",
        student,
        group,
        clock.today() - timedelta(days=40),
    )
    return {"dilnoza": dilnoza, "jasur": jasur, "group": group, "enrollment": enrollment}


async def pay(api, enrollment: int, amount: int) -> dict:
    response = await api.client.post(f"/enrollments/{enrollment}/payments", json={"amount": amount})
    assert response.status_code == 201, response.text
    return response.json()


def this_month() -> date:
    return clock.today().replace(day=1)


def last_month() -> date:
    return (this_month() - timedelta(days=1)).replace(day=1)


async def charge(api, enrollment: int, month: date, amount: int) -> None:
    """A charge for `month` -- payments are only a teacher's pay once they
    have paid a charge."""
    async with api.pool.acquire() as conn:
        await money.create_charge(
            conn, enrollment_id=enrollment, period_start=month, period_end=rules.next_month(month),
            amount=amount, base_fee=amount
        )


async def test_finance_and_pay_belong_to_the_owner_alone(api):
    ids = await seed(api)
    today = clock.today().isoformat()
    async with api.as_admin() as admin:
        # An admin neither sees nor changes anything in Moliya: not the
        # summary, not the salaries, not the expenses...
        for path in ("/finance/summary", "/finance/salaries"):
            assert (await admin.get(path)).status_code == 403, path
        assert (
            await admin.get("/expenses", params={"date_from": "2026-01-01", "date_to": "2026-12-31"})
        ).status_code == 403
        assert (
            await admin.post("/expenses", json={"category": "rent", "amount": 1000, "spent_on": today})
        ).status_code == 403
        # ...and cannot close a month or change how anyone is paid.
        assert (await admin.post("/finance/salaries/close", params={"month": today})).status_code == 403
        percent = {"salary_percent": 40}
        assert (await admin.put(f"/finance/teachers/{ids['dilnoza']}/percent", json=percent)).status_code == 403
        assert (await admin.put(f"/finance/groups/{ids['group']}/percent", json=percent)).status_code == 403
        rule = {"method": "fixed", "fixed": 1000000}
        assert (await admin.put(f"/finance/teachers/{ids['dilnoza']}/salary", json=rule)).status_code == 403
        assert (await admin.put(f"/finance/groups/{ids['group']}/salary", json=rule)).status_code == 403
        # Staff accounts are the owner's too.
        assert (await admin.get("/staff")).status_code == 403
    assert await api.pool.fetchval("select salary_method from teachers where id = $1", ids["dilnoza"]) is None
    # The owner can do all of it.
    assert (await api.client.get("/finance/summary")).status_code == 200
    assert (await api.client.get("/finance/salaries")).status_code == 200
    assert (await api.client.put(f"/finance/teachers/{ids['dilnoza']}/percent", json={"salary_percent": 40})).status_code == 200


async def test_payments_count_towards_the_teacher_at_the_time(api):
    ids = await seed(api)
    await charge(api, ids["enrollment"], last_month(), 400000)
    await charge(api, ids["enrollment"], this_month(), 400000)
    await pay(api, ids["enrollment"], 400000)
    # The group changes teacher; the earlier payment stays Dilnoza's.
    await api.client.patch(f"/groups/{ids['group']}", json={"teacher_id": ids["jasur"]})
    await pay(api, ids["enrollment"], 100000)
    rows = await api.pool.fetch("select amount, teacher_id from payment_allocations order by id")
    assert [(r["amount"], r["teacher_id"]) for r in rows] == [(400000, ids["dilnoza"]), (100000, ids["jasur"])]


async def test_salaries_for_a_month(api):
    ids = await seed(api)
    set_percent = await api.client.put(f"/finance/teachers/{ids['dilnoza']}/percent", json={"salary_percent": 40})
    assert set_percent.status_code == 200
    assert (await api.client.put(f"/finance/teachers/{ids['dilnoza']}/percent", json={"salary_percent": 140})).status_code == 400
    await charge(api, ids["enrollment"], last_month(), 999000)
    await charge(api, ids["enrollment"], this_month(), 650001)
    # Last month's payment isn't this month's salary.
    async with api.pool.acquire() as conn:
        await money.record_payment(
            conn, student_id=1, amount=999000, method="cash", user_id=None,
            received_at=datetime.combine(this_month() - timedelta(days=3), datetime.min.time(), timezone.utc),
        )
    await pay(api, ids["enrollment"], 400000)
    await pay(api, ids["enrollment"], 250001)

    month = (await api.client.get("/finance/salaries")).json()
    dilnoza = next(t for t in month["teachers"] if t["teacher_id"] == ids["dilnoza"])
    # 40% of 650 001, rounded half up.
    assert (dilnoza["collected"], dilnoza["earned"], dilnoza["paid"], dilnoza["remaining"]) == (650001, 260000, 0, 260000)
    assert [(l["student_name"], l["collected"], l["share"]) for l in dilnoza["lines"]] == [("Aziz", 650001, 260000)]
    jasur = next(t for t in month["teachers"] if t["teacher_id"] == ids["jasur"])
    assert (jasur["salary_percent"], jasur["earned"]) == (None, 0)

    payout_body = {
            "category": "salary",
            "amount": 200000,
            "spent_on": clock.today().isoformat(),
            "teacher_id": ids["dilnoza"],
            # Any day of the month means that month.
            "salary_month": (this_month() + timedelta(days=9)).isoformat(),
            "method": "cash",
        }
    # Not before the month is closed...
    early = await api.client.post("/expenses", json=payout_body)
    assert early.status_code == 409 and "yoping" in early.json()["detail"]
    assert (await api.client.post("/finance/salaries/close", params={"month": this_month().isoformat()})).status_code == 200
    payout = await api.client.post("/expenses", json=payout_body)
    assert payout.status_code == 201, payout.text
    assert payout.json()["salary_month"] == this_month().isoformat()
    month = (await api.client.get("/finance/salaries")).json()
    assert (month["total_earned"], month["total_paid"], month["total_remaining"]) == (260000, 200000, 60000)
    assert await api.pool.fetchval("select count(*) from salary_payouts where voided_at is null") == 1

    voided = await api.client.post(f"/expenses/{payout.json()['id']}/void", json={"reason": "Xato summa"})  # owner
    assert voided.status_code == 200 and voided.json()["voided_at"] is not None
    assert (await api.client.get("/finance/salaries")).json()["total_paid"] == 0
    assert await api.pool.fetchval("select count(*) from salary_payouts where voided_at is null") == 0
    # Voided, but kept.
    listed = (
        await api.client.get(
            "/expenses",
            params={"date_from": this_month().isoformat(), "date_to": clock.today().isoformat(), "include_voided": True},
        )
    ).json()
    assert [e["void_reason"] for e in listed] == ["Xato summa"]


async def test_expense_validation(api):
    today = clock.today().isoformat()
    cases = [
        {"category": "party", "amount": 1, "spent_on": today},
        {"category": "rent", "amount": 0, "spent_on": today},
        {"category": "salary", "amount": 100, "spent_on": today},
        {"category": "rent", "amount": 100, "spent_on": today, "method": "bitcoin"},
    ]
    for body in cases:
        assert (await api.client.post("/expenses", json=body)).status_code == 400, body
    missing = await api.client.post(
        "/expenses",
        json={"category": "salary", "amount": 100, "spent_on": today, "teacher_id": 99999, "salary_month": today},
    )
    assert missing.status_code == 404
    rent = await api.client.post("/expenses", json={"category": "rent", "amount": 3000000, "spent_on": today})
    assert rent.status_code == 201
    assert rent.json()["teacher_id"] is None and rent.json()["created_by_name"] == "Owner"


async def test_summary_shows_income_expenses_and_profit_by_month(api):
    ids = await seed(api)
    await api.client.put(f"/finance/teachers/{ids['dilnoza']}/percent", json={"salary_percent": 50})
    await charge(api, ids["enrollment"], this_month(), 1000000)
    await pay(api, ids["enrollment"], 1000000)
    today = clock.today().isoformat()
    await api.client.post("/expenses", json={"category": "rent", "amount": 300000, "spent_on": today})
    await api.client.post("/finance/salaries/close", params={"month": today})
    paid = await api.client.post(
        "/expenses",
        json={"category": "salary", "amount": 200000, "spent_on": today, "teacher_id": ids["dilnoza"], "salary_month": today},
    )
    assert paid.status_code == 201, paid.text

    summary = (await api.client.get("/finance/summary", params={"months": 3})).json()
    assert [m["month"] for m in summary["months"]][-1] == this_month().isoformat()
    assert len(summary["months"]) == 3
    current = summary["months"][-1]
    assert (current["income"], current["expenses"], current["profit"]) == (1000000, 500000, 500000)
    assert current["by_category"] == {"rent": 300000, "salary": 200000}
    assert summary["months"][0]["income"] == 0
    # Earned 500 000, paid 200 000.
    assert summary["salaries_unpaid_this_month"] == 300000
