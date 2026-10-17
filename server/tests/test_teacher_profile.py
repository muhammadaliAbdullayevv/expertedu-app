"""A teacher's page: groups with size, days and times; what their groups
brought in this month and their share; how their lessons go; today and
tomorrow; six months of pay."""

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from test_students import School

pytestmark = pytest.mark.anyio


async def profile(api, teacher_id: int, **query) -> dict:
    r = await api.client.get(f"/teachers/{teacher_id}/profile", params=query)
    assert r.status_code == 200, r.text
    return r.json()


async def test_groups_with_size_days_times_and_the_rule_they_are_paid_by(api):
    school = await School(api).build(capacity=10)
    await api.pool.execute("update teachers set salary_method = 'percent', salary_percent = 40 where id = $1", school.t1)
    for i in range(3):
        await school.join(await school.student(name=f"Talaba {i}", phone=f"99890111010{i}"), school.g1)
    p = await profile(api, school.t1)
    assert p["teacher"]["full_name"] == "Madina Karimova"
    assert (p["salary_method"], p["salary_percent"]) == ("percent", 40.0)
    assert [g["name"] for g in p["groups"]] == ["Beginner A"]
    g = p["groups"][0]
    assert (g["student_count"], g["capacity"], g["subject_name"]) == (3, 10, "Ingliz tili")
    assert [(s["weekday"], s["starts_at"][:5], s["ends_at"][:5]) for s in g["schedule"]] == [
        (1, "09:00", "10:30"), (3, "09:00", "10:30"), (5, "09:00", "10:30"),
    ]
    assert (g["salary_method"], g["salary_percent"], g["own_rule"]) == ("percent", 40.0, False)
    assert p["student_total"] == 3
    # The other teacher's group is not on this page.
    other = await profile(api, school.t2)
    assert [g["name"] for g in other["groups"]] == ["Matematika 9"]


async def test_a_group_with_its_own_percent_shows_it_and_archived_groups_are_left_out(api):
    school = await School(api).build()
    await api.pool.execute("update teachers set salary_method = 'percent', salary_percent = 40 where id = $1", school.t1)
    await api.pool.execute("update groups set salary_method = 'percent', salary_percent = 50 where id = $1", school.g1)
    old = await api.pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, is_active) "
        "values ($1, 'Eski guruh', $2, 100000, 1, false) returning id", school.english, school.t1,
    )
    p = await profile(api, school.t1)
    assert [g["name"] for g in p["groups"]] == ["Beginner A"]
    g = p["groups"][0]
    assert (g["salary_percent"], g["own_rule"]) == (50.0, True)
    assert old not in [x["group_id"] for x in p["groups"]]


FIRST = date.today().replace(day=1)


async def test_the_salary_is_the_teachers_share_of_what_is_collected_and_matches_finance(api):
    school = await School(api).build()
    await api.pool.execute("update teachers set salary_method = 'percent', salary_percent = 40 where id = $1", school.t1)
    a = await school.join(await school.student(name="A", phone="998901110201"), school.g1, FIRST)
    b = await school.join(await school.student(name="B", phone="998901110202"), school.g1, FIRST)
    await school.pay(a, 300000)
    await school.pay(b, 100000)
    p = await profile(api, school.t1)
    assert (p["collected"], p["earned"], p["paid"], p["remaining"]) == (400000, 160000, 0, 160000)
    g = p["groups"][0]
    assert (g["collected"], g["share"]) == (400000, 160000)
    # The Finance page says the same.
    finance = (await api.client.get("/finance/salaries", params={"month": str(date.today())})).json()
    row = [t for t in finance["teachers"] if t["teacher_id"] == school.t1][0]
    assert (row["collected"], row["earned"]) == (p["collected"], p["earned"])
    # Another teacher's money does not leak onto this page.
    other = await profile(api, school.t2)
    assert (other["collected"], other["earned"]) == (0, 0)


async def test_the_salary_split_by_group_adds_up(api):
    school = await School(api).build()
    await api.pool.execute("update teachers set salary_method = 'percent', salary_percent = 40 where id = $1", school.t1)
    second = await api.pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, salary_method, salary_percent) "
        "values ($1, 'Beginner B', $2, 200000, 1, 'percent', 50) returning id", school.english, school.t1,
    )
    e1 = await school.join(await school.student(name="A", phone="998901110301"), school.g1, FIRST)
    e2 = await school.join(await school.student(name="B", phone="998901110302"), second, FIRST)
    await school.pay(e1, 300000)
    await school.pay(e2, 200000)
    p = await profile(api, school.t1)
    by_name = {g["name"]: g for g in p["groups"]}
    assert (by_name["Beginner A"]["collected"], by_name["Beginner A"]["share"]) == (300000, 120000)
    assert (by_name["Beginner B"]["collected"], by_name["Beginner B"]["share"]) == (200000, 100000)
    assert p["earned"] == sum(g["share"] for g in p["groups"]) == 220000


async def test_attendance_over_the_last_30_days(api):
    school = await School(api).build()
    e = await school.join(await school.student(), school.g1)
    await school.mark(e, school.g1, ["present", "present", "absent", "present"])
    p = await profile(api, school.t1)
    assert p["attendance"]["total"] == 4 and p["attendance"]["rate"] == 0.75
    assert p["groups"][0]["attendance_rate"] == 0.75
    # A group nobody marked has no rate yet.
    assert (await profile(api, school.t2))["groups"][0]["attendance_rate"] is None


async def test_the_week_counts_planned_marked_cancelled_and_forgotten_lessons(api):
    school = await School(api).build()
    e = await school.join(await school.student(), school.g1)
    tz = ZoneInfo("Asia/Tashkent")
    now = datetime.now(tz)
    today = now.date()
    monday = datetime.combine(today - timedelta(days=today.weekday()), datetime.min.time(), tz)
    # Mon, Wed, Fri 09:00-10:30: those already over and not marked are "forgotten".
    over = sum(1 for d in (0, 2, 4) if monday + timedelta(days=d, hours=10, minutes=30) <= now)
    p = await profile(api, school.t1)
    assert p["week"] == {"planned": 3, "marked": 0, "cancelled": 0, "unmarked_past": over}
    for lesson in p["lessons"]:
        assert lesson["teacher_id"] == school.t1

    # Three extra lessons early on Monday (already over): one marked, one
    # forgotten, one cancelled.
    ids = []
    for i, status in enumerate(("active", "active", "cancelled")):
        start = monday + timedelta(minutes=1 + 40 * i)
        ids.append(await api.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at, status, is_extra) values ($1, $2, $3, $4, true) returning id",
            school.g1, start, start + timedelta(minutes=30), status,
        ))
    await api.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, 'present')", ids[0], e)
    week = (await profile(api, school.t1))["week"]
    assert (week["marked"], week["cancelled"]) == (1, 1)
    assert week["unmarked_past"] == over + 1
    assert week["planned"] == 3 + 2


async def test_history_has_six_months_and_a_month_can_be_chosen(api):
    school = await School(api).build()
    p = await profile(api, school.t1)
    assert len(p["history"]) == 6
    assert p["history"][-1]["month"] == str(date.today().replace(day=1))
    assert [h["month"] for h in p["history"]] == sorted(h["month"] for h in p["history"])
    past = await profile(api, school.t1, month="2026-03-15")
    assert past["month"] == "2026-03-01" and past["history"][-1]["month"] == "2026-03-01"


async def test_an_unknown_teacher_is_404(api):
    assert (await api.client.get("/teachers/9999/profile")).status_code == 404
