"""A group's profile page: teacher, students, who paid, attendance, days and
times, the billing day, and what was collected of what was expected."""

import uuid
from datetime import date, timedelta

import pytest

from test_students import School

pytestmark = pytest.mark.anyio


async def profile(school, group_id: int) -> dict:
    r = await school.api.client.get(f"/groups/{group_id}/profile")
    assert r.status_code == 200, r.text
    return r.json()


async def test_the_profile_names_the_teacher_the_schedule_and_the_billing_day(api):
    school = await School(api).build()
    await api.pool.execute("update teachers set phone = '998901110000' where id = $1", school.t1)
    p = await profile(school, school.g1)
    assert p["group"]["name"] == "Beginner A"
    assert p["subject_name"] == "Ingliz tili"
    assert p["teacher"] == {"id": school.t1, "full_name": "Madina Karimova", "phone": "998901110000"}
    assert [(s["weekday"], s["starts_at"][:5], s["ends_at"][:5]) for s in p["schedule"]] == [
        (1, "09:00", "10:30"), (3, "09:00", "10:30"), (5, "09:00", "10:30"),
    ]
    # Bills on the 1st: the next billing day is the next 1st (today counts).
    nxt = date.fromisoformat(p["next_billing_date"])
    assert nxt.day == 1 and nxt >= date.today()
    assert len(p["next_lessons"]) == 3
    # No students yet: nothing to count, nothing expected.
    assert (p["student_count"], p["paid_count"], p["unpaid_count"]) == (0, 0, 0)
    assert (p["expected"], p["collected"], p["debt_total"]) == (0, 0, 0)
    assert p["attendance"]["rate"] is None and p["waiting"] == []


async def test_a_group_with_no_teacher_or_billing_day_still_has_a_profile(api):
    school = await School(api).build()
    anniversary = await api.pool.fetchval(
        "insert into groups (subject_id, name, fee_amount, billing_mode, billing_day) "
        "values ($1, 'Har kuni', 100000, 'student_anniversary', null) returning id", school.english,
    )
    p = await profile(school, anniversary)
    assert p["teacher"] is None
    # Each student pays on their own day, so there is no group billing day.
    assert p["next_billing_date"] is None
    assert p["schedule"] == []
    assert (await api.client.get("/groups/9999/profile")).status_code == 404


async def test_students_who_paid_and_who_did_not_and_how_much_came_in(api):
    school = await School(api).build(capacity=4)
    paid = await school.student(name="Toladi", phone="998901110031")
    half = await school.student(name="Yarmini", phone="998901110032")
    none = await school.student(name="Tolamadi", phone="998901110033")
    ep = await school.join(paid, school.g1)
    eh = await school.join(half, school.g1)
    await school.join(none, school.g1)
    owed_paid = (await school.profile(paid))["groups"][0]["balance"]
    owed_half = (await school.profile(half))["groups"][0]["balance"]
    owed_none = (await school.profile(none))["groups"][0]["balance"]
    await school.pay(ep, owed_paid)
    await school.pay(eh, owed_half // 2)

    p = await profile(school, school.g1)
    assert (p["student_count"], p["paid_count"], p["unpaid_count"]) == (3, 1, 2)
    assert p["capacity"] == 4 and p["free_seats"] == 1
    # Expected is this period's charges, collected is what was paid toward them.
    assert p["expected"] == owed_paid + owed_half + owed_none
    assert p["collected"] == owed_paid + owed_half // 2
    assert p["debt_total"] == (owed_half - owed_half // 2) + owed_none
    assert p["collected"] < p["expected"]


async def test_a_cancelled_payment_is_not_collected(api):
    school = await School(api).build()
    s = await school.student()
    e = await school.join(s, school.g1)
    owed = (await school.profile(s))["groups"][0]["balance"]
    payment = await school.pay(e, owed)
    assert (await profile(school, school.g1))["collected"] == owed
    r = await api.client.post(f"/payments/{payment['id']}/cancel", json={"reason": "Xato"})
    assert r.status_code == 200, r.text
    p = await profile(school, school.g1)
    assert (p["collected"], p["unpaid_count"], p["debt_total"]) == (0, 1, owed)


async def test_the_group_attendance_counts_every_marked_lesson(api):
    school = await School(api).build()
    a = await school.student(name="A", phone="998901110041")
    b = await school.student(name="B", phone="998901110042")
    ea = await school.join(a, school.g1)
    eb = await school.join(b, school.g1)
    # Four lessons, each marked for both students.
    for days_ago, (sa, sb) in zip(
        (4, 3, 2, 1),
        [("present", "present"), ("present", "excused"), ("late", "absent"), ("absent", "absent")],
    ):
        lesson = await school.lesson(school.g1, days_ago)
        for enrollment, status in ((ea, sa), (eb, sb)):
            await api.pool.execute(
                "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)",
                lesson, enrollment, status,
            )
    att = (await profile(school, school.g1))["attendance"]
    assert (att["present"], att["late"], att["absent"], att["excused"], att["total"]) == (3, 1, 3, 1, 8)
    # 4 came (present or late) of the 7 they were expected at -- excused is not held against them.
    assert att["rate"] == round(4 / 7, 4)


async def test_a_full_group_shows_its_students_beyond_the_capacity_and_no_free_seats(api):
    school = await School(api).build(capacity=1)
    for i in range(2):
        s = await school.student(name=f"S{i}", phone=f"99890111005{i}")
        await school.join(s, school.g1)
    p = await profile(school, school.g1)
    assert (p["student_count"], p["capacity"], p["free_seats"]) == (2, 1, 0)


async def test_people_saved_for_the_group_wait_beside_it_and_are_not_students(api):
    school = await School(api).build(capacity=5)
    lesson = (await api.client.get(f"/groups/{school.g1}/trial-dates", params={"count": 1})).json()[0]

    async def save(name, phone, **extra):
        r = await api.client.post(
            "/leads",
            json={"full_name": name, "phone": phone, "client_id": str(uuid.uuid4()), "on_duplicate": "merge", **extra},
            headers={"Idempotency-Key": str(uuid.uuid4())},
        )
        assert r.status_code == 201, r.text
        return r.json()

    await save("Kutuvchi Bir", "998901110061", group_id=school.g1)
    await save("Kutuvchi Ikki", "998901110062", group_id=school.g1, trial_starts_at=lesson["starts_at"])
    other = await save("Boshqa guruh", "998901110063", group_id=school.g2)
    gone = await save("Arxivdagi", "998901110064", group_id=school.g1)
    await api.client.post(f"/leads/{gone['id']}/stage", json={"stage": "not_interested", "version": gone["version"]})

    p = await profile(school, school.g1)
    assert sorted(w["full_name"] for w in p["waiting"]) == ["Kutuvchi Bir", "Kutuvchi Ikki"]
    assert other["id"] not in {w["lead_id"] for w in p["waiting"]}
    trial = next(w for w in p["waiting"] if w["full_name"] == "Kutuvchi Ikki")
    assert trial["trial_at"] is not None
    # Not students: no seat, not counted, no charge.
    assert (p["student_count"], p["free_seats"]) == (0, 5)
    assert await api.pool.fetchval("select count(*) from charges") == 0
    assert await api.pool.fetchval("select count(*) from students where phone like '9989011100%'") == 0


async def test_expected_is_this_period_only_while_the_debt_includes_the_older_months(api):
    from app.money import service as money

    school = await School(api).build()
    s = await school.student()
    await school.join(s, school.g1, joined=date.today() - timedelta(days=75))
    async with api.pool.acquire() as conn:
        await money.generate_charges(conn, date.today())
    p = await profile(school, school.g1)
    charges = await api.pool.fetch("select amount, period_start, period_end from charges order by period_start")
    assert len(charges) >= 3  # the months since they joined
    current = next(c for c in charges if c["period_start"] <= date.today() < c["period_end"])
    assert p["expected"] == current["amount"]
    # Nothing was paid, so everything is still owed -- the old months too.
    assert p["collected"] == 0
    assert p["debt_total"] == sum(c["amount"] for c in charges) > p["expected"]
