"""The home page: an admin sees what students owe and what happens today, never
what the center collects; the owner sees the money and every branch side by side."""

from datetime import date, datetime, timedelta, timezone

import pytest

from test_branches import World, client_for

pytestmark = pytest.mark.anyio

FIRST = date.today().replace(day=1)


@pytest.fixture
async def world(api):
    w = await World().build(api)
    yield w
    await w.close()


async def pay(world, client, student, group, amount):
    enrollment = await world.enrollment(student, group)
    r = await client.post(f"/enrollments/{enrollment}/payments", json={"amount": amount, "method": "cash"})
    assert r.status_code == 201, r.text


async def test_an_admin_sees_debts_but_not_what_the_center_collects(world):
    await pay(world, world.a1, world.s1, world.g1, 100000)
    admin = (await world.a1.get("/dashboard")).json()
    assert admin["money_visible"] is False
    assert (admin["collected_this_month"], admin["monthly_plan"]) == (0, 0)
    assert (admin["revenue_by_month"], admin["recent_payments"]) == ([], [])
    # What they collect from students is still there.
    assert admin["total_debt"] == 200000 and admin["debtor_count"] == 1
    assert [d["student_id"] for d in admin["top_debtors"]] == [world.s1]
    owner = (await world.owner.get("/dashboard")).json()
    assert owner["money_visible"] is True
    assert owner["collected_this_month"] == 100000 and owner["monthly_plan"] > 0
    assert len(owner["revenue_by_month"]) == 6 and len(owner["recent_payments"]) == 1


async def test_the_owner_picks_a_branch_and_the_figures_follow(world):
    await pay(world, world.a1, world.s1, world.g1, 300000)
    await pay(world, world.a2, world.s2, world.g2, 50000)
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    everything = (await world.owner.get("/dashboard")).json()
    chilonzor = (await only2.get("/dashboard")).json()
    assert (everything["collected_this_month"], chilonzor["collected_this_month"]) == (350000, 50000)
    assert (everything["active_students"], chilonzor["active_students"]) == (2, 1)
    assert (everything["total_debt"], chilonzor["total_debt"]) == (150000, 150000)
    await only2.aclose()


async def test_attendance_of_the_last_seven_days(world):
    e1 = await world.enrollment(world.s1, world.g1)
    now = datetime.now(timezone.utc)
    for days_ago, status in ((1, "present"), (2, "late"), (3, "absent"), (4, "excused"), (30, "absent")):
        start = now - timedelta(days=days_ago)
        lesson = await world.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
            world.g1, start, start + timedelta(hours=1),
        )
        await world.pool.execute(
            "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)", lesson, e1, status
        )
    # Excused and the old lesson do not count: 2 came out of 3 expected.
    assert (await world.a1.get("/dashboard")).json()["attendance_rate_7d"] == pytest.approx(0.6667, abs=0.001)
    # Another branch has marked nothing.
    assert (await world.a2.get("/dashboard")).json()["attendance_rate_7d"] is None


async def test_calls_to_make_today_are_counted(world):
    lead = (await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"})).json()
    due = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    await world.a1.post("/follow-up-tasks", json={"lead_id": lead["id"], "title": "Qo'ng'iroq", "due_at": due})
    assert (await world.a1.get("/dashboard")).json()["tasks_due_today"] == 1
    assert (await world.a2.get("/dashboard")).json()["tasks_due_today"] == 0


async def test_every_branch_side_by_side_for_the_owner_only(world):
    await pay(world, world.a1, world.s1, world.g1, 300000)
    await pay(world, world.a2, world.s2, world.g2, 50000)
    await world.a2.post("/leads", json={"full_name": "Zilola", "phone": "998907770002"})
    rows = {r["name"]: r for r in (await world.owner.get("/dashboard/branches")).json()}
    assert set(rows) == {"Bosh ofis", "Chilonzor"}
    hq, ch = rows["Bosh ofis"], rows["Chilonzor"]
    assert hq["is_headquarters"] is True
    assert (hq["active_students"], hq["collected_this_month"], hq["total_debt"], hq["debtor_count"]) == (1, 300000, 0, 0)
    assert (ch["active_students"], ch["collected_this_month"], ch["total_debt"], ch["debtor_count"]) == (1, 50000, 150000, 1)
    assert (hq["open_leads"], ch["open_leads"]) == (0, 1)
    assert hq["active_groups"] == 1 and ch["active_groups"] == 1
    # An admin may not see the other branches' figures.
    assert (await world.a1.get("/dashboard/branches")).status_code == 403
