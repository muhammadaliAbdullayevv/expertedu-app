"""A teacher's page: their groups (name, students, days, times), what they earn
from ALL their groups together this month, today and tomorrow, six months of
pay. The list carries no money at all."""

from datetime import date

import pytest

from test_students import School

pytestmark = pytest.mark.anyio

FIRST = date.today().replace(day=1)


async def profile(api, teacher_id: int, **query) -> dict:
    r = await api.client.get(f"/teachers/{teacher_id}/profile", params=query)
    assert r.status_code == 200, r.text
    return r.json()


async def percent_teacher(api, school, percent=40):
    await api.pool.execute(
        "update teachers set salary_method = 'percent', salary_percent = $2 where id = $1", school.t1, percent
    )


async def test_groups_show_name_students_days_and_times_and_nothing_else(api):
    school = await School(api).build(capacity=10)
    for i in range(3):
        await school.join(await school.student(name=f"Talaba {i}", phone=f"99890111010{i}"), school.g1)
    p = await profile(api, school.t1)
    assert p["teacher"]["full_name"] == "Madina Karimova"
    assert [g["name"] for g in p["groups"]] == ["Beginner A"]
    g = p["groups"][0]
    assert (g["student_count"], g["capacity"], g["subject_name"]) == (3, 10, "Ingliz tili")
    assert [(s["weekday"], s["starts_at"][:5], s["ends_at"][:5]) for s in g["schedule"]] == [
        (1, "09:00", "10:30"), (3, "09:00", "10:30"), (5, "09:00", "10:30"),
    ]
    # Group stats (attendance, money) belong to the group's own page.
    assert set(g) == {"group_id", "name", "subject_name", "level", "student_count", "capacity", "schedule", "branch_name"}
    assert "attendance" not in p and "week" not in p
    assert p["student_total"] == 3
    # The other teacher's group is not on this page.
    assert [g["name"] for g in (await profile(api, school.t2))["groups"]] == ["Matematika 9"]


async def test_archived_groups_are_left_out(api):
    school = await School(api).build()
    await api.pool.execute(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, is_active) "
        "values ($1, 'Eski guruh', $2, 100000, 1, false)", school.english, school.t1,
    )
    assert [g["name"] for g in (await profile(api, school.t1))["groups"]] == ["Beginner A"]


async def test_the_salary_is_the_share_of_everything_all_his_groups_collected(api):
    school = await School(api).build()
    await percent_teacher(api, school)
    second = await api.pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
        "values ($1, 'Beginner B', $2, 200000, 1) returning id", school.english, school.t1,
    )
    e1 = await school.join(await school.student(name="A", phone="998901110301"), school.g1, FIRST)
    e2 = await school.join(await school.student(name="B", phone="998901110302"), second, FIRST)
    await school.pay(e1, 300000)
    await school.pay(e2, 200000)
    p = await profile(api, school.t1)
    # 40% of the 500 000 both groups together collected -- one figure for the teacher.
    assert (p["collected"], p["earned"], p["paid"], p["remaining"]) == (500000, 200000, 0, 200000)
    assert len(p["groups"]) == 2
    # The Finance page says the same.
    finance = (await api.client.get("/finance/salaries", params={"month": str(date.today())})).json()
    row = [t for t in finance["teachers"] if t["teacher_id"] == school.t1][0]
    assert (row["collected"], row["earned"]) == (p["collected"], p["earned"])
    # Another teacher's money does not leak onto this page.
    other = await profile(api, school.t2)
    assert (other["collected"], other["earned"]) == (0, 0)


async def test_a_group_with_its_own_percent_still_adds_into_the_one_total(api):
    school = await School(api).build()
    await percent_teacher(api, school)
    second = await api.pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, salary_method, salary_percent) "
        "values ($1, 'Beginner B', $2, 200000, 1, 'percent', 50) returning id", school.english, school.t1,
    )
    e1 = await school.join(await school.student(name="A", phone="998901110301"), school.g1, FIRST)
    e2 = await school.join(await school.student(name="B", phone="998901110302"), second, FIRST)
    await school.pay(e1, 300000)
    await school.pay(e2, 200000)
    p = await profile(api, school.t1)
    assert p["earned"] == 120000 + 100000  # 40% of 300 000 and 50% of 200 000


async def test_today_and_tomorrow_come_from_the_timetable(api):
    school = await School(api).build()
    p = await profile(api, school.t1)
    for lesson in p["lessons"]:
        assert lesson["teacher_id"] == school.t1


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


async def test_the_list_has_groups_and_students_but_no_money(api):
    school = await School(api).build()
    await percent_teacher(api, school)
    a = await school.join(await school.student(name="A", phone="998901110401"), school.g1, FIRST)
    await school.join(await school.student(name="B", phone="998901110402"), school.g1, FIRST)
    await school.pay(a, 300000)
    rows = {t["id"]: t for t in (await api.client.get("/teachers")).json()}
    mine, other = rows[school.t1], rows[school.t2]
    assert (mine["group_count"], mine["student_count"]) == (1, 2)
    assert (other["group_count"], other["student_count"]) == (1, 0)
    assert "earned" not in mine and "collected" not in mine
    # An archived teacher shows only when asked for.
    await api.pool.execute("update teachers set is_active = false where id = $1", school.t2)
    assert [t["id"] for t in (await api.client.get("/teachers")).json()] == [school.t1]
    assert len((await api.client.get("/teachers", params={"include_inactive": "true"})).json()) == 2


async def test_an_admin_gets_the_page_without_any_pay(api):
    school = await School(api).build()
    await percent_teacher(api, school)
    e = await school.join(await school.student(name="A", phone="998901110301"), school.g1, FIRST)
    await school.pay(e, 300000)
    async with api.as_admin() as admin:
        r = await admin.get(f"/teachers/{school.t1}/profile")
    assert r.status_code == 200
    p = r.json()
    # Groups and lessons are there; every pay figure is gone.
    assert [g["name"] for g in p["groups"]] == ["Beginner A"]
    assert p["salary_visible"] is False
    assert (p["salary_method"], p["salary_percent"], p["salary_fixed"]) == (None, None, None)
    assert (p["collected"], p["earned"], p["paid"], p["remaining"]) == (0, 0, 0, 0)
    assert p["history"] == []
    # The owner still gets it.
    owner = await profile(api, school.t1)
    assert owner["salary_visible"] is True and owner["earned"] == 120000 and len(owner["history"]) == 6
