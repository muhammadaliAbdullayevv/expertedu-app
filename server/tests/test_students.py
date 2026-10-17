"""The student profile: the table's flags, the profile panel's data, editing
with an audit trail, adding a student to another group, and the roster order."""

import uuid
from datetime import date, datetime, time, timedelta, timezone

import pytest

pytestmark = pytest.mark.anyio


class School:
    """A subject, two teachers and two groups -- one with a weekly schedule."""

    def __init__(self, api):
        self.api = api
        self.pool = api.pool

    async def build(self, capacity: int | None = None):
        pool = self.pool
        self.english = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
        self.math = await pool.fetchval("insert into subjects (name) values ('Matematika') returning id")
        self.t1 = await pool.fetchval("insert into teachers (full_name) values ('Madina Karimova') returning id")
        self.t2 = await pool.fetchval("insert into teachers (full_name) values ('Jasur Rahimov') returning id")
        self.g1 = await pool.fetchval(
            "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, capacity) "
            "values ($1, 'Beginner A', $2, 300000, 1, $3) returning id", self.english, self.t1, capacity,
        )
        self.g2 = await pool.fetchval(
            "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
            "values ($1, 'Matematika 9', $2, 200000, 1) returning id", self.math, self.t2,
        )
        for day in (1, 3, 5):
            await pool.execute(
                "insert into group_schedules (group_id, weekday, starts_at, ends_at) values ($1, $2, '09:00', '10:30')",
                self.g1, day,
            )
        return self

    async def student(self, name="Botir Aliyev", phone="998901110001", **extra) -> int:
        body = {"full_name": name, "phone": phone, **extra}
        r = await self.api.client.post("/students", json=body)
        assert r.status_code == 201, r.text
        return r.json()["id"]

    async def join(self, student_id: int, group_id: int, joined: date | None = None) -> int:
        r = await self.api.client.post(
            "/enrollments",
            json={"student_id": student_id, "group_id": group_id, "joined_at": str(joined or date.today())},
        )
        assert r.status_code == 201, r.text
        return r.json()["id"]

    async def lesson(self, group_id: int, days_ago: int) -> int:
        start = datetime.now(timezone.utc).replace(hour=4, minute=0, second=0, microsecond=0) - timedelta(days=days_ago)
        return await self.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
            group_id, start, start + timedelta(hours=1, minutes=30),
        )

    async def mark(self, enrollment_id: int, group_id: int, statuses: list[str]) -> None:
        """One lesson per status, oldest first."""
        for i, status in enumerate(statuses):
            lesson = await self.lesson(group_id, len(statuses) - i)
            await self.pool.execute(
                "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)",
                lesson, enrollment_id, status,
            )

    async def pay(self, enrollment_id: int, amount: int, method="cash") -> dict:
        r = await self.api.client.post(
            f"/enrollments/{enrollment_id}/payments", json={"amount": amount, "method": method}
        )
        assert r.status_code == 201, r.text
        return r.json()

    async def profile(self, student_id: int) -> dict:
        r = await self.api.client.get(f"/students/{student_id}/profile")
        assert r.status_code == 200, r.text
        return r.json()


@pytest.fixture
async def school(api):
    return await School(api).build()


async def test_the_profile_has_groups_attendance_balance_and_payments(school):
    s = await school.student(parent_phone="998935550000")
    e1 = await school.join(s, school.g1)
    e2 = await school.join(s, school.g2)
    # Beginner A: came to 4 of 5 (one absence), plus one excused lesson.
    await school.mark(e1, school.g1, ["present", "present", "late", "absent", "present", "excused"])
    await school.mark(e2, school.g2, ["absent", "absent"])
    paid = await school.pay(e1, 1000)

    p = await school.profile(s)
    assert p["student"]["full_name"] == "Botir Aliyev"
    assert p["student"]["parent_phone"] == "998935550000"
    # Newest group first among the active ones; each with teacher, schedule and its own balance.
    groups = {g["group_name"]: g for g in p["groups"]}
    a = groups["Beginner A"]
    assert (a["teacher_name"], a["subject_name"], a["fee_amount"], a["status"]) == (
        "Madina Karimova", "Ingliz tili", 300000, "active",
    )
    assert [(sl["weekday"], sl["starts_at"][:5], sl["ends_at"][:5]) for sl in a["schedule"]] == [
        (1, "09:00", "10:30"), (3, "09:00", "10:30"), (5, "09:00", "10:30"),
    ]
    # Each group's own balance; together they are what the student owes.
    assert a["balance"] > 0 and groups["Matematika 9"]["balance"] > 0
    assert a["balance"] + groups["Matematika 9"]["balance"] == p["balance"]
    # Attendance of that group: 4 came (present, late) out of 5 expected -- the excused one is not held against them.
    att = a["attendance"]
    assert (att["present"], att["late"], att["absent"], att["excused"], att["total"]) == (3, 1, 1, 1, 6)
    assert att["rate"] == 0.8
    assert att["recent"] == ["present", "present", "late", "absent", "present", "excused"]
    # Overall: 4 + 0 came; 5 + 2 expected.
    assert p["attendance"]["total"] == 8 and p["attendance"]["rate"] == round(4 / 7, 4)
    # The Davomat tab: dated lessons, newest first.
    assert len(p["marks"]) == 8
    mark_times = [datetime.fromisoformat(m["at"]) for m in p["marks"]]
    assert mark_times == sorted(mark_times, reverse=True)
    assert {m["group_name"] for m in p["marks"]} == {"Beginner A", "Matematika 9"}
    # Payments, with who took them.
    assert [(x["amount"], x["method"], x["group_name"], x["status"]) for x in p["payments"]] == [
        (1000, "cash", "Beginner A", "valid"),
    ]
    assert p["payments"][0]["receipt_no"] == paid["receipt_no"]
    assert p["paid_total"] == 1000


async def test_a_cancelled_payment_stays_on_the_profile_marked_and_is_not_counted(school):
    s = await school.student()
    e = await school.join(s, school.g1)
    first = await school.pay(e, 100000)
    await school.pay(e, 50000, method="card")
    r = await school.api.client.post(f"/payments/{first['id']}/cancel", json={"reason": "Xato kiritilgan"})
    assert r.status_code == 200, r.text

    p = await school.profile(s)
    by_amount = {x["amount"]: x for x in p["payments"]}
    assert by_amount[100000]["status"] == "cancelled"
    assert by_amount[100000]["cancel_reason"] == "Xato kiritilgan"
    assert by_amount[50000]["status"] == "valid"
    assert p["paid_total"] == 50000
    kinds = [i["kind"] for i in p["activity"]]
    assert "payment_cancelled" in kinds and "payment" in kinds


async def test_the_debt_card_knows_how_long_a_charge_has_been_unpaid(school):
    s = await school.student()
    await school.join(s, school.g1, joined=date.today() - timedelta(days=40))
    p = await school.profile(s)
    assert p["balance"] > 0
    assert p["debt_since"] is not None and p["overdue_days"] >= 0
    # Nothing owed, nothing overdue.
    clean = await school.student(name="Toza Odam", phone="998901110009")
    q = await school.profile(clean)
    assert (q["balance"], q["debt_since"], q["overdue_days"], q["groups"]) == (0, None, 0, [])


async def test_the_profile_activity_lists_what_happened_newest_first(school):
    s = await school.student()
    e = await school.join(s, school.g1)
    await school.mark(e, school.g1, ["present", "absent"])
    await school.pay(e, 100000)
    p = await school.profile(s)
    kinds = [i["kind"] for i in p["activity"]]
    assert {"joined", "charge", "payment", "absent"} <= set(kinds)
    times = [datetime.fromisoformat(i["at"]) for i in p["activity"]]
    assert times == sorted(times, reverse=True)
    absent = next(i for i in p["activity"] if i["kind"] == "absent")
    assert (absent["title"], absent["detail"]) == ("Darsga kelmadi", "Beginner A")


async def test_an_unknown_student_has_no_profile(api):
    assert (await api.client.get("/students/9999/profile")).status_code == 404


# --- the table ------------------------------------------------------------------------------------------


async def test_the_table_flags_debtors_new_at_risk_and_archived_students(school):
    pool = school.pool
    debtor = await school.student(name="Qarzdor Odam", phone="998901110002")
    await school.join(debtor, school.g1)
    paid = await school.student(name="Toliq Odam", phone="998901110003")
    pe = await school.join(paid, school.g1)
    await school.pay(pe, 300000)
    await school.mark(pe, school.g1, ["present"] * 7 + ["absent"] * 3)  # 70%: at risk
    # An archived student: left every group.
    gone = await school.student(name="Ketgan Odam", phone="998901110004")
    ge = await school.join(gone, school.g2)
    await pool.execute("update enrollments set status = 'withdrawn', ended_at = current_date where id = $1", ge)
    # Not new: registered a while ago.
    await pool.execute("update students set created_at = now() - interval '60 days' where id = $1", paid)

    rows = {r["full_name"]: r for r in (await school.api.client.get("/students")).json()}
    d, ok, g = rows["Qarzdor Odam"], rows["Toliq Odam"], rows["Ketgan Odam"]
    assert (d["is_debtor"], d["is_active"], d["is_new"], d["is_at_risk"]) == (True, True, True, False)
    assert (ok["is_debtor"], ok["is_active"], ok["is_new"], ok["is_at_risk"]) == (False, True, False, True)
    assert ok["attendance_rate"] == 0.7
    assert (g["is_active"], g["groups"]) == (False, [])
    # Groups with teacher and weekly days, for the "Guruh va o'qituvchi" column.
    ref = d["groups"][0]
    assert (ref["name"], ref["teacher_name"], ref["subject_name"]) == ("Beginner A", "Madina Karimova", "Ingliz tili")
    assert [sl["weekday"] for sl in ref["schedule"]] == [1, 3, 5]
    # Search still works.
    found = (await school.api.client.get("/students", params={"q": "qarzdor"})).json()
    assert [r["full_name"] for r in found] == ["Qarzdor Odam"]


async def test_a_student_with_too_few_marks_is_not_called_at_risk(school):
    s = await school.student()
    e = await school.join(s, school.g1)
    await school.mark(e, school.g1, ["absent", "absent"])
    row = next(r for r in (await school.api.client.get("/students")).json() if r["id"] == s)
    assert row["is_at_risk"] is False


# --- editing --------------------------------------------------------------------------------------------


async def test_editing_a_profile_changes_it_and_writes_what_it_was_to_the_audit_log(school):
    s = await school.student()
    r = await school.api.client.patch(
        f"/students/{s}",
        json={"full_name": "  Botir  Aliyev Jr ", "phone": "+998 90 111 00 77", "parent_phone": "935550011",
              "address": " Chilonzor, 7-kvartal ", "note": "Kechqurun keladi"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["full_name"], body["phone"], body["parent_phone"], body["address"], body["note"]) == (
        "Botir  Aliyev Jr", "998901110077", "998935550011", "Chilonzor, 7-kvartal", "Kechqurun keladi",
    )
    log = await school.pool.fetch("select action, before, after, user_id from audit_log where entity = 'student'")
    assert [row["action"] for row in log] == ["update"]
    import json as jsonlib
    before, after = jsonlib.loads(log[0]["before"]), jsonlib.loads(log[0]["after"])
    assert before["full_name"] == "Botir Aliyev" and before["phone"] == "998901110001"
    assert after["phone"] == "998901110077" and after["address"] == "Chilonzor, 7-kvartal"
    assert log[0]["user_id"] == school.api.owner_id


async def test_editing_with_nothing_changed_writes_nothing(school):
    s = await school.student()
    r = await school.api.client.patch(f"/students/{s}", json={"full_name": "Botir Aliyev"})
    assert r.status_code == 200
    assert await school.pool.fetchval("select count(*) from audit_log where entity = 'student'") == 0


async def test_a_phone_that_belongs_to_another_student_is_refused(school):
    a = await school.student(phone="998901110001")
    await school.student(name="Boshqa", phone="998901110002")
    r = await school.api.client.patch(f"/students/{a}", json={"phone": "998901110002"})
    assert r.status_code == 409
    assert (await school.api.client.get(f"/students/{a}")).json()["phone"] == "998901110001"
    # Keeping their own number is fine, and so is clearing the optional fields.
    ok = await school.api.client.patch(f"/students/{a}", json={"phone": "998901110001", "address": ""})
    assert ok.status_code == 200 and ok.json()["address"] is None


async def test_bad_edits_are_refused(school):
    s = await school.student()
    assert (await school.api.client.patch(f"/students/{s}", json={"full_name": "  "})).status_code == 400
    assert (await school.api.client.patch(f"/students/{s}", json={"phone": "123"})).status_code == 400
    assert (await school.api.client.patch(f"/students/{s}", json={"parent_phone": "12"})).status_code == 400
    assert (await school.api.client.patch("/students/9999", json={"note": "x"})).status_code == 404


# --- adding to another group ------------------------------------------------------------------------------


async def add(school, student_id, group_id, **extra):
    return await school.api.client.post(
        f"/students/{student_id}/add-to-group",
        json={"group_id": group_id, "joined_at": str(date.today()), **extra},
    )


async def test_adding_a_student_to_another_group_makes_the_seat_and_the_first_bill(school):
    s = await school.student()
    await school.join(s, school.g1)
    before = await school.pool.fetchval("select count(*) from charges")

    r = await add(school, s, school.g2)
    assert r.status_code == 201, r.text
    body = r.json()
    assert (body["group_name"], body["first_payment"]) == ("Matematika 9", 0)
    assert body["first_charge"] > 0
    assert await school.pool.fetchval("select count(*) from charges") == before + 1
    p = await school.profile(s)
    assert sorted(g["group_name"] for g in p["groups"]) == ["Beginner A", "Matematika 9"]
    assert await school.pool.fetchval("select count(*) from audit_log where action = 'add_to_group'") == 1


async def test_adding_with_the_first_payment_takes_it_in_the_same_step(school):
    s = await school.student()
    r = await add(school, s, school.g2, first_payment_amount=100000, first_payment_method="card")
    assert r.status_code == 201, r.text
    assert r.json()["first_payment"] == 100000
    p = await school.profile(s)
    assert [(x["amount"], x["method"], x["group_name"]) for x in p["payments"]] == [(100000, "card", "Matematika 9")]


async def test_a_failure_adds_nothing_at_all(school):
    s = await school.student()
    enrollments = await school.pool.fetchval("select count(*) from enrollments")
    # A payment method that does not exist: refused before anything is made.
    bad = await add(school, s, school.g2, first_payment_amount=1000, first_payment_method="bitcoin")
    assert bad.status_code == 400
    # A group that does not exist, a student who does not exist, a group they are already in.
    assert (await add(school, s, 9999)).status_code == 404
    assert (await add(school, 9999, school.g2)).status_code == 404
    await school.join(s, school.g1)
    enrollments += 1
    again = await add(school, s, school.g1)
    assert again.status_code == 409
    assert await school.pool.fetchval("select count(*) from enrollments") == enrollments
    assert await school.pool.fetchval("select count(*) from payments") == 0


async def test_a_full_group_still_takes_the_student_and_stays_full(api):
    school = await School(api).build(capacity=1)
    first = await school.student(name="Birinchi", phone="998901110011")
    await school.join(first, school.g1)
    second = await school.student(name="Ikkinchi", phone="998901110012")
    r = await add(school, second, school.g1)
    assert r.status_code == 201, r.text
    assert await school.pool.fetchval(
        "select count(*) from enrollments where group_id = $1 and status = 'active'", school.g1
    ) == 2
    found = (await api.client.get("/groups/search")).json()
    group = next(g for g in found["exact"] + found["near"] if g["group_id"] == school.g1)
    assert (group["enrolled"], group["free_seats"]) == (2, 0)


# --- the group roster -----------------------------------------------------------------------------------


async def test_new_students_come_first_on_the_roster_marked_as_new(school):
    old = await school.student(name="Eski Odam", phone="998901110021")
    await school.join(old, school.g1, joined=date.today() - timedelta(days=90))
    new = await school.student(name="Yangi Odam", phone="998901110022")
    await school.join(new, school.g1)
    roster = (await school.api.client.get(f"/groups/{school.g1}/roster")).json()
    assert [(r["student_full_name"], r["is_new"]) for r in roster] == [("Yangi Odam", True), ("Eski Odam", False)]


# --- from Qabul -----------------------------------------------------------------------------------------


async def test_the_address_typed_in_qabul_goes_to_the_student_when_they_join(school):
    lead = await school.api.client.post(
        "/leads",
        json={"full_name": "Nodira Ismoilova", "phone": "998901110031", "address": "Yunusobod, 4-mavze",
              "parent_phone": "998935550031", "group_id": school.g1, "on_duplicate": "merge",
              "client_id": str(uuid.uuid4())},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert lead.status_code == 201, lead.text
    enrolled = await school.api.client.post(
        f"/leads/{lead.json()['id']}/enroll",
        json={"full_name": "Nodira Ismoilova", "phone": "998901110031", "group_id": school.g1,
              "joined_at": str(date.today())},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert enrolled.status_code == 201, enrolled.text
    p = await school.profile(enrolled.json()["student"]["id"])
    assert (p["student"]["address"], p["student"]["parent_phone"]) == ("Yunusobod, 4-mavze", "998935550031")


async def test_if_the_payment_step_fails_the_seat_and_the_bill_are_undone_too(school, monkeypatch):
    from fastapi import HTTPException

    from app.routes import students as students_routes

    async def broken(*args, **kwargs):
        raise HTTPException(500, "to'lov saqlanmadi")

    monkeypatch.setattr(students_routes.money, "record_payment", broken)
    s = await school.student()
    r = await add(school, s, school.g2, first_payment_amount=1000, first_payment_method="cash")
    assert r.status_code == 500
    # Not a half-done join: no seat, no bill, no audit line.
    assert await school.pool.fetchval("select count(*) from enrollments") == 0
    assert await school.pool.fetchval("select count(*) from charges") == 0
    assert await school.pool.fetchval("select count(*) from audit_log where action = 'add_to_group'") == 0
