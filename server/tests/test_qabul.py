"""Qabul: the board, the course finder, the trial date picker, and -- the
point of app/funnel.py -- one person counted the same way on Bugun, Qabul
and O'quvchilar at every step of the way."""

from datetime import date, datetime, time, timedelta, timezone

import pytest

from app import admissions, funnel
from test_admissions import PHONE, book, enroll, move_to_past, new_lead, seed as seed_admissions

pytestmark = pytest.mark.anyio


# --- one definition of the stages ----------------------------------------------------------------------


def test_every_stage_has_exactly_one_v2_stage():
    assert set(funnel.STAGE_TO_V2) == set(admissions.ALL_STAGES)
    assert set(funnel.STAGE_TO_V2.values()) == set(funnel.V2_STAGES)
    assert funnel.v2_stage("trial_scheduled") == "trial"
    # Attended, not decided yet: awaiting the answer.
    assert funnel.v2_stage("trial_completed") == funnel.v2_stage("decision_pending") == "awaiting_decision"
    assert funnel.v2_stage("not_interested") == funnel.v2_stage("unreachable") == "rejected"
    # Keyinroq is still an open lead; Guruhga qo'shildi and Rad etildi are not.
    assert set(funnel.OPEN_V2) == {funnel.v2_stage(s) for s in admissions.OPEN_STAGES}
    assert {"joined", "rejected"}.isdisjoint(funnel.OPEN_V2)


# --- one person, three screens --------------------------------------------------------------------------


async def screens(api) -> dict:
    """What Qabul, Bugun, O'quvchilar and the sidebar each say right now."""
    board = (await api.client.get("/admissions/board")).json()
    dashboard = (await api.client.get("/dashboard")).json()
    summary = (await api.client.get("/students/summary")).json()
    counts = (await api.client.get("/counts")).json()
    listed = (await api.client.get("/students")).json()
    columns = {c["key"]: c for c in board["columns"]}
    return {
        "qabul": {key: c["count"] for key, c in columns.items()},
        "qabul_cards": {key: [lead["phone"] for lead in c["leads"]] for key, c in columns.items()},
        "qabul_open": sum(columns[k]["count"] for k in funnel.OPEN_V2),
        "qabul_joined_kpi": board["kpi"]["joined"],
        "qabul_leads_kpi": board["kpi"]["leads"],
        "qabul_trial_people": board["kpi"]["trial_people"],
        "qabul_conversion": board["kpi"]["conversion_rate"],
        "bugun_open": dashboard["open_leads"],
        "bugun_new_leads": dashboard["new_leads_this_week"],
        "bugun_active": dashboard["active_students"],
        "bugun_new_students": dashboard["new_students_this_month"],
        "oquvchilar_active": summary["active_students"],
        "oquvchilar_total": summary["total_students"],
        "oquvchilar_listed": len(listed),
        "badge_open": counts["open_leads"],
        "badge_active": counts["active_students"],
    }


def assert_screens_agree(s: dict) -> None:
    """The same people, the same count, whichever screen you look at."""
    assert s["qabul_open"] == s["bugun_open"] == s["badge_open"], s
    assert s["bugun_active"] == s["oquvchilar_active"] == s["badge_active"], s
    assert s["oquvchilar_total"] == s["oquvchilar_listed"], s
    assert s["qabul"]["joined"] == s["qabul_joined_kpi"], s


async def test_one_person_is_counted_the_same_way_on_every_screen(api):
    ids = await seed_admissions(api)
    start = await screens(api)
    assert_screens_agree(start)
    assert (start["qabul_open"], start["oquvchilar_total"], start["bugun_active"]) == (0, 0, 0)

    # 1. A call comes in: Yangi. One open lead everywhere, not a student.
    lead = await new_lead(api, subject_id=ids["subject_id"])
    s = await screens(api)
    assert_screens_agree(s)
    assert (s["qabul"]["new"], s["qabul_open"], s["bugun_open"], s["badge_open"]) == (1, 1, 1, 1)
    assert PHONE in s["qabul_cards"]["new"]
    assert (s["qabul_leads_kpi"], s["bugun_new_leads"]) == (1, 1)
    assert (s["oquvchilar_total"], s["oquvchilar_active"], s["bugun_active"]) == (0, 0, 0)

    # 2. Called back: Bog'lanildi. Still the one open lead.
    response = await api.client.post(f"/leads/{lead['id']}/stage", json={"stage": "contacted", "version": lead["version"]})
    assert response.status_code == 200, response.text
    s = await screens(api)
    assert_screens_agree(s)
    assert (s["qabul"]["new"], s["qabul"]["contacted"], s["qabul_open"], s["bugun_open"]) == (0, 1, 1, 1)

    # 3. A trial lesson is booked: Sinov darsi. Free, and still not a student.
    booking = await book(api, lead["id"], ids["teacher_id"])
    s = await screens(api)
    assert_screens_agree(s)
    assert (s["qabul"]["contacted"], s["qabul"]["trial"], s["qabul_open"], s["bugun_open"]) == (0, 1, 1, 1)
    assert (s["oquvchilar_total"], s["oquvchilar_listed"], s["bugun_active"]) == (0, 0, 0)
    assert s["qabul_trial_people"] == 0

    # 4. They come to it: now we wait for the answer. Counted as a trial person,
    #    still one open lead, still not a student.
    await move_to_past(api.pool, booking["session"]["id"])
    attended = await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})
    assert attended.status_code == 200, attended.text
    s = await screens(api)
    assert_screens_agree(s)
    assert (s["qabul"]["trial"], s["qabul"]["awaiting_decision"], s["qabul_open"]) == (0, 1, 1)
    assert s["qabul_trial_people"] == 1 and s["bugun_open"] == 1
    assert (s["oquvchilar_total"], s["oquvchilar_active"], s["bugun_active"], s["bugun_new_students"]) == (0, 0, 0, 0)
    assert await api.pool.fetchval("select count(*) from charges") == 0

    # 5. "Guruhga qo'shish": the one step that makes them a student. In the
    #    same moment they leave the open leads, join Guruhga qo'shildi, and
    #    appear in O'quvchilar and Bugun's active students.
    enrolled = await enroll(api, lead["id"], ids["group_id"])
    assert enrolled.status_code in (200, 201), enrolled.text
    s = await screens(api)
    assert_screens_agree(s)
    assert (s["qabul_open"], s["bugun_open"], s["badge_open"]) == (0, 0, 0)
    assert (s["qabul"]["joined"], s["qabul_joined_kpi"]) == (1, 1)
    assert PHONE in s["qabul_cards"]["joined"]
    assert (s["oquvchilar_total"], s["oquvchilar_listed"], s["oquvchilar_active"]) == (1, 1, 1)
    assert (s["bugun_active"], s["bugun_new_students"], s["badge_active"]) == (1, 1, 1)
    assert s["qabul_conversion"] == 1.0 and s["qabul_trial_people"] == 1


async def test_a_person_who_says_later_or_no_is_counted_the_same_everywhere(api):
    ids = await seed_admissions(api)
    later = await new_lead(api, phone="998901111111", subject_id=ids["subject_id"])
    no = await new_lead(api, phone="998902222222", subject_id=ids["subject_id"])
    r = await api.client.post(f"/leads/{later['id']}/stage", json={
        "stage": "follow_up_later", "version": later["version"],
        "follow_up_at": (datetime.now(timezone.utc) + timedelta(days=3)).isoformat(),
    })
    assert r.status_code == 200, r.text
    r = await api.client.post(
        f"/leads/{no['id']}/stage", json={"stage": "not_interested", "version": no["version"], "reason": "Qimmat"}
    )
    assert r.status_code == 200, r.text
    s = await screens(api)
    assert_screens_agree(s)
    # Keyinroq is still open; Rad etildi is not.
    assert (s["qabul"]["later"], s["qabul"]["rejected"], s["qabul_open"], s["bugun_open"], s["badge_open"]) == (1, 1, 1, 1, 1)
    assert s["oquvchilar_total"] == 0 and s["qabul_conversion"] == 0.0


async def test_a_lead_for_an_existing_student_is_still_a_lead_not_a_second_student(api):
    ids = await seed_admissions(api)
    student = await api.pool.fetchval("insert into students (full_name, phone) values ('Mavjud', '998903333333') returning id")
    enrollment = await api.pool.fetchval(
        "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, current_date) returning id", student, ids["group_id"]
    )
    assert enrollment
    await new_lead(api, phone="998903333333", subject_id=ids["other_subject_id"])
    s = await screens(api)
    assert_screens_agree(s)
    # One open lead (a new inquiry from a student), one student: neither is counted twice.
    assert (s["qabul_open"], s["oquvchilar_total"], s["oquvchilar_active"]) == (1, 1, 1)


async def test_trial_people_are_counted_once_however_many_bookings(api):
    ids = await seed_admissions(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    first = await book(api, lead["id"], ids["teacher_id"])
    moved = await api.client.post(
        f"/trial-bookings/{first['id']}/reschedule", json={"session": session_payload_for(ids, hours=72)}
    )
    assert moved.status_code == 201, moved.text
    await move_to_past(api.pool, moved.json()["session"]["id"])
    await api.client.post(f"/trial-bookings/{moved.json()['id']}/attendance", json={"status": "attended"})
    s = await screens(api)
    # Two bookings (one moved), one person.
    assert s["qabul_trial_people"] == 1
    assert await api.pool.fetchval("select count(*) from trial_bookings") == 2


async def test_a_person_who_attends_two_trials_is_one_trial_person(api):
    ids = await seed_admissions(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    for hours in (24, 48):
        booking = await book(api, lead["id"], ids["teacher_id"], hours=hours)  # the owner may book a second
        await move_to_past(api.pool, booking["session"]["id"])
        assert (await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})).status_code == 200
    assert await api.pool.fetchval("select count(*) from trial_bookings where status = 'attended'") == 2
    assert (await screens(api))["qabul_trial_people"] == 1


def session_payload_for(ids, hours):
    from test_admissions import session_payload

    return session_payload(ids["teacher_id"], hours=hours)


# --- the board's payload ---------------------------------------------------------------------------------


async def test_board_columns_follow_the_design_and_cards_carry_what_the_cards_show(api):
    ids = await seed_admissions(api)
    await new_lead(api, subject_id=ids["subject_id"], source="instagram")
    board = (await api.client.get("/admissions/board")).json()
    assert [c["key"] for c in board["columns"]] == list(funnel.V2_STAGES)
    assert [c["label"] for c in board["columns"]] == [
        "Yangi", "Bog'lanildi", "Sinov darsi", "To'lov kutilmoqda", "Guruhga qo'shildi", "Keyinroq", "Rad etildi",
    ]
    card = board["columns"][0]["leads"][0]
    assert (card["full_name"], card["subject_name"], card["source"], card["v2_stage"]) == (
        "Aziza Karimova", "Ingliz tili", "instagram", "new",
    )
    assert card["assigned_to_name"] == "Owner" and card["stage_changed_at"]


async def test_the_joined_column_and_the_kpi_use_the_selected_dates(api):
    ids = await seed_admissions(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    assert (await enroll(api, lead["id"], ids["group_id"])).status_code in (200, 201)
    this_month = (await api.client.get("/admissions/board")).json()
    assert this_month["kpi"]["joined"] == 1
    long_ago = (await api.client.get("/admissions/board", params={"date_from": "2020-01-01", "date_to": "2020-01-31"})).json()
    assert long_ago["kpi"]["joined"] == 0 and long_ago["kpi"]["leads"] == 0
    assert {c["key"]: c["count"] for c in long_ago["columns"]}["joined"] == 0
    assert (await api.client.get("/admissions/board", params={"date_from": "2020-02-01", "date_to": "2020-01-01"})).status_code == 400


async def test_the_old_report_gives_the_same_people_numbers_as_the_board(api):
    ids = await seed_admissions(api)
    a = await new_lead(api, phone="998901000001", subject_id=ids["subject_id"])
    await new_lead(api, phone="998901000002", subject_id=ids["subject_id"])
    assert (await enroll(api, a["id"], ids["group_id"], phone="998901000001")).status_code in (200, 201)
    board = (await api.client.get("/admissions/board")).json()["kpi"]
    report = (await api.client.get("/admissions/report")).json()
    assert (report["new_inquiries"], report["enrollments"], report["cohort_enrolled"], report["lead_conversion_rate"]) == (
        board["leads"], board["joined"], board["cohort_joined"], board["conversion_rate"],
    )


# --- what the client asked for ----------------------------------------------------------------------------


async def test_a_lead_keeps_what_the_client_asked_for(api):
    ids = await seed_admissions(api)
    lead = await new_lead(
        api, subject_id=ids["subject_id"], desired_weekdays=[5, 1, 3, 3], desired_time_of_day="morning", level="Beginner"
    )
    assert (lead["desired_weekdays"], lead["desired_time_of_day"], lead["level"]) == ([1, 3, 5], "morning", "Beginner")
    for bad in ({"desired_weekdays": [0]}, {"desired_weekdays": [8]}, {"desired_time_of_day": "night"}):
        response = await api.client.post("/leads", json={"full_name": "X", "phone": "998909999999", **bad})
        assert response.status_code == 400, bad
    changed = await api.client.patch(f"/leads/{lead['id']}", json={"version": lead["version"], "desired_time_of_day": "evening"})
    assert changed.status_code == 200 and changed.json()["desired_time_of_day"] == "evening"


# --- Kurs qidirish ------------------------------------------------------------------------------------------


class Courses:
    """Beginner A (Mon Wed Fri morning, 14/16), Beginner B (Tue Thu Sat evening),
    a full group, another subject and another level."""

    def __init__(self, api):
        self.api, self.pool = api, api.pool

    async def build(self):
        pool = self.pool
        self.english = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
        self.french = await pool.fetchval("insert into subjects (name) values ('Fransuz tili') returning id")
        self.teacher = await pool.fetchval("insert into teachers (full_name) values ('Madina') returning id")
        self.a = await self.group(self.english, "Beginner A", "Beginner", [1, 3, 5], time(9, 0), capacity=16, enrolled=14)
        self.b = await self.group(self.english, "Beginner B", "Beginner", [2, 4, 6], time(18, 0), capacity=14, enrolled=6)
        self.mixed = await self.group(self.english, "Beginner C", "Beginner", [1, 3, 6], time(18, 30), capacity=10, enrolled=0)
        self.full = await self.group(self.english, "Beginner D", "Beginner", [1, 3, 5], time(10, 30), capacity=2, enrolled=2)
        self.inter = await self.group(self.english, "Intermediate", "Intermediate", [1, 3, 5], time(9, 0), capacity=10, enrolled=0)
        self.fr = await self.group(self.french, "A1", "Beginner", [1, 3, 5], time(9, 0), capacity=10, enrolled=0)
        return self

    async def group(self, subject, name, level, days, start, capacity, enrolled):
        pool = self.pool
        # Its own teacher, so no two groups clash on the timetable.
        teacher = await pool.fetchval("insert into teachers (full_name) values ($1) returning id", f"O'qituvchi {name}")
        gid = await pool.fetchval(
            "insert into groups (subject_id, name, level, teacher_id, fee_amount, billing_day, capacity) "
            "values ($1, $2, $3, $4, 310000, 1, $5) returning id", subject, name, level, teacher, capacity,
        )
        for day in days:
            await pool.execute(
                "insert into group_schedules (group_id, weekday, starts_at, ends_at) values ($1, $2, $3, $4)",
                gid, day, start, (datetime_add(start, 90)),
            )
        for i in range(enrolled):
            student = await pool.fetchval(
                "insert into students (full_name, phone) values ($1, $2) returning id", f"{name} {i}", f"99890{gid:03d}{i:04d}"
            )
            await pool.execute("insert into enrollments (student_id, group_id, joined_at) values ($1, $2, current_date)", student, gid)
        return gid

    async def find(self, **params):
        response = await self.api.client.get("/groups/search", params=params)
        assert response.status_code == 200, response.text
        body = response.json()
        return [g["group_id"] for g in body["exact"]], [g["group_id"] for g in body["near"]], body


def datetime_add(start: time, minutes: int) -> time:
    total = start.hour * 60 + start.minute + minutes
    return time(total // 60, total % 60)


@pytest.fixture
async def courses(api):
    return await Courses(api).build()


async def test_the_finder_separates_exact_matches_from_near_misses(courses):
    exact, near, body = await courses.find(subject_id=courses.english, level="Beginner", weekdays="1,3,5")
    # A and D meet exactly Mon-Wed-Fri; the full one is listed after the open one.
    assert exact == [courses.a, courses.full]
    # B meets none of the client's days; C meets two of them (Mon, Wed) -- closest first.
    assert near == [courses.mixed, courses.b]
    by_id = {g["group_id"]: g for g in body["exact"] + body["near"]}
    assert (by_id[courses.a]["matched_days"], by_id[courses.a]["total_days"]) == (3, 3)
    assert (by_id[courses.mixed]["matched_days"], by_id[courses.mixed]["total_days"]) == (2, 3)
    assert (by_id[courses.b]["matched_days"], by_id[courses.b]["total_days"]) == (0, 3)


async def test_free_seats_are_capacity_minus_active_students(courses):
    _, _, body = await courses.find(subject_id=courses.english, level="Beginner", weekdays="1,3,5")
    by_id = {g["group_id"]: g for g in body["exact"] + body["near"]}
    assert (by_id[courses.a]["free_seats"], by_id[courses.a]["enrolled"], by_id[courses.a]["capacity"]) == (2, 14, 16)
    assert by_id[courses.full]["free_seats"] == 0
    # A student who left no longer takes a seat.
    await courses.pool.execute(
        "update enrollments set status = 'withdrawn', ended_at = current_date where group_id = $1 and id = (select min(id) from enrollments where group_id = $1)",
        courses.a,
    )
    _, _, body = await courses.find(subject_id=courses.english, level="Beginner", weekdays="1,3,5")
    assert {g["group_id"]: g for g in body["exact"]}[courses.a]["free_seats"] == 3
    # No limit at all is not "full".
    await courses.pool.execute("update groups set capacity = null where id = $1", courses.a)
    _, _, body = await courses.find(subject_id=courses.english, level="Beginner", weekdays="1,3,5")
    assert {g["group_id"]: g for g in body["exact"]}[courses.a]["free_seats"] is None


async def test_the_finder_filters_by_subject_level_and_time_of_day(courses):
    exact, near, _ = await courses.find(subject_id=courses.english, level="Intermediate")
    assert exact == [courses.inter] and near == []
    exact, _, _ = await courses.find(subject_id=courses.french)
    assert exact == [courses.fr]
    # Levels match whatever the case.
    exact, _, _ = await courses.find(subject_id=courses.english, level="intermediate")
    assert exact == [courses.inter]
    # Morning: only the groups that meet before noon.
    exact, near, _ = await courses.find(subject_id=courses.english, level="Beginner", time_of_day="morning")
    assert exact == [courses.a, courses.full] and near == []
    exact, near, _ = await courses.find(subject_id=courses.english, level="Beginner", time_of_day="evening")
    assert set(exact) == {courses.b, courses.mixed} and near == []
    # No days chosen: every candidate is exact.
    exact, near, _ = await courses.find(subject_id=courses.english, level="Beginner")
    assert set(exact) == {courses.a, courses.b, courses.mixed, courses.full} and near == []


async def test_the_finder_ignores_inactive_groups_and_validates_input(courses):
    await courses.pool.execute("update groups set is_active = false where id = $1", courses.a)
    exact, _, _ = await courses.find(subject_id=courses.english, level="Beginner", weekdays="1,3,5")
    assert courses.a not in exact
    for params in ({"weekdays": "1,9"}, {"weekdays": "x"}, {"time_of_day": "midnight"}):
        assert (await courses.api.client.get("/groups/search", params=params)).status_code == 400, params
    assert (await courses.api.client.get("/groups/levels", params={"subject_id": courses.english})).json() == ["Beginner", "Intermediate"]


# --- the trial date picker ----------------------------------------------------------------------------------


async def test_trial_dates_are_the_groups_next_lessons_and_follow_the_schedule(courses):
    response = await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 3})
    assert response.status_code == 200, response.text
    dates = response.json()
    assert len(dates) == 3
    days = [datetime_from(d["starts_at"]).isoweekday() for d in dates]
    assert all(day in (1, 3, 5) for day in days)
    assert [d["starts_at"] for d in dates] == sorted(d["starts_at"] for d in dates)
    assert all(d["trial_session_id"] is None and d["guests_booked"] == 0 for d in dates)
    assert dates[0]["free_seats"] == 2 and dates[0]["suggested_capacity"] == 2
    # A cancelled lesson is not offered.
    await courses.pool.execute(
        "insert into lessons (group_id, starts_at, ends_at, status, cancel_reason) values ($1, $2, $3, 'cancelled', 'Bayram')",
        courses.a, datetime_from(dates[0]["starts_at"]), datetime_from(dates[0]["ends_at"]),
    )
    after = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 3})).json()
    assert dates[0]["starts_at"] not in [d["starts_at"] for d in after]
    assert len(after) == 3
    assert (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 0})).status_code == 400
    assert (await courses.api.client.get("/groups/99999/trial-dates")).status_code == 404


def datetime_from(text: str):
    from datetime import datetime
    from zoneinfo import ZoneInfo

    return datetime.fromisoformat(text).astimezone(ZoneInfo("Asia/Tashkent"))


async def test_booking_a_group_lesson_trial_with_a_reminder_makes_a_task_and_no_charge(courses):
    lead = await new_lead(courses.api, subject_id=courses.english)
    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    booking = await courses.api.client.post(
        "/trial-bookings",
        json={
            "lead_id": lead["id"],
            "remind": True,
            "session": {
                "kind": "group_lesson", "group_id": courses.a, "starts_at": lesson["starts_at"],
                "ends_at": lesson["ends_at"], "capacity": lesson["suggested_capacity"],
            },
        },
    )
    assert booking.status_code == 201, booking.text
    tasks = await courses.pool.fetch("select title, status, due_at from follow_up_tasks where lead_id = $1", lead["id"])
    assert [(t["title"], t["status"]) for t in tasks] == [("Sinov darsi haqida eslatish", "open")]
    assert tasks[0]["due_at"] <= datetime_from(lesson["starts_at"])
    assert await courses.pool.fetchval("select count(*) from charges") == 0
    # The second guest books the same lesson through its session.
    again = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    assert again["trial_session_id"] is not None and again["guests_booked"] == 1


async def test_groups_store_a_level_and_start_date(api):
    ids = await seed_admissions(api)
    created = await api.client.post(
        "/groups",
        json={"subject_id": ids["subject_id"], "name": "Yangi", "fee_amount": 300000, "billing_day": 1,
              "level": " Beginner ", "start_date": "2026-09-01"},
    )
    assert created.status_code == 201, created.text
    assert (created.json()["level"], created.json()["start_date"]) == ("Beginner", "2026-09-01")
    changed = await api.client.patch(f"/groups/{created.json()['id']}", json={"level": "Elementary"})
    assert changed.json()["level"] == "Elementary"


# --- the fast form: one save, with or without a group and a free trial -------------------------------


async def quick(courses, name="Nodira", phone="998901112233", client=None, **extra):
    import uuid

    body = {"full_name": name, "phone": phone, "client_id": str(uuid.uuid4()), "on_duplicate": "merge", **extra}
    return await (client or courses.api.client).post("/leads", json=body, headers={"Idempotency-Key": str(uuid.uuid4())})


async def test_a_saved_person_with_a_group_and_a_trial_is_a_lead_with_no_seat_and_no_charge(courses):
    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    response = await quick(courses, group_id=courses.a, trial_starts_at=lesson["starts_at"], remind=True)
    assert response.status_code == 201, response.text
    lead = response.json()
    assert (lead["group_id"], lead["group_name"], lead["subject_id"]) == (courses.a, "Beginner A", courses.english)
    assert lead["next_trial_at"] is not None
    pool = courses.pool
    # Not a student: no student row, no enrollment, no charge, no seat taken.
    assert await pool.fetchval("select count(*) from students where phone = '998901112233'") == 0
    assert await pool.fetchval("select count(*) from charges") == 0
    assert await pool.fetchval("select count(*) from enrollments where group_id = $1", courses.a) == 14
    assert await pool.fetchval("select count(*) from trial_bookings where lead_id = $1", lead["id"]) == 1
    assert await pool.fetchval("select count(*) from follow_up_tasks where lead_id = $1", lead["id"]) == 1
    # The free seats the picker shows did not change.
    found = (await courses.api.client.get("/groups/search", params={"subject_id": courses.english})).json()
    seats = {g["group_id"]: g["free_seats"] for g in found["exact"] + found["near"]}
    assert seats[courses.a] == 2


async def test_a_person_saved_without_a_group_has_no_group_and_no_trial(courses):
    response = await quick(courses, note="kechqurun qulay")
    assert response.status_code == 201, response.text
    lead = response.json()
    assert (lead["group_id"], lead["group_name"], lead["next_trial_at"]) == (None, None, None)
    # A trial needs a group.
    refused = await quick(courses, phone="998901112244", trial_starts_at="2030-01-01T09:00:00+05:00")
    assert refused.status_code == 400


async def test_a_retried_save_is_one_person_and_one_trial(courses):
    import uuid

    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    body = {
        "full_name": "Nodira", "phone": "998901112233", "client_id": str(uuid.uuid4()), "on_duplicate": "merge",
        "group_id": courses.a, "trial_starts_at": lesson["starts_at"],
    }
    # The same request twice (same key) and once more with a new key but the same client_id: all one save.
    key = str(uuid.uuid4())
    first = await courses.api.client.post("/leads", json=body, headers={"Idempotency-Key": key})
    again = await courses.api.client.post("/leads", json=body, headers={"Idempotency-Key": key})
    other = await courses.api.client.post("/leads", json=body, headers={"Idempotency-Key": str(uuid.uuid4())})
    assert [r.status_code for r in (first, again, other)] == [201, 201, 201]
    assert first.json()["id"] == again.json()["id"] == other.json()["id"]
    assert await courses.pool.fetchval("select count(*) from leads") == 1
    assert await courses.pool.fetchval("select count(*) from trial_bookings") == 1


async def test_a_refused_trial_saves_nothing_so_nothing_is_half_done(courses):
    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    ok = await quick(courses, group_id=courses.a, trial_starts_at=lesson["starts_at"])
    assert ok.status_code == 201
    # The same person may not take a second trial in another group (a limit of one) -- only the owner may.
    second_lesson = (await courses.api.client.get(f"/groups/{courses.fr}/trial-dates", params={"count": 1})).json()[0]
    async with courses.api.as_admin() as admin:
        refused = await quick(courses, client=admin, group_id=courses.fr, trial_starts_at=second_lesson["starts_at"])
    assert refused.status_code == 403, refused.text
    # The refused save created no lead of its own -- the person still has the one open lead.
    assert await courses.pool.fetchval("select count(*) from leads where phone = '998901112233'") == 1
    # A lesson that isn't one of the group's next lessons is refused too.
    odd = await quick(courses, phone="998901112255", group_id=courses.a, trial_starts_at="2030-01-01T03:00:00+05:00")
    assert odd.status_code == 409
    assert await courses.pool.fetchval("select count(*) from leads where phone = '998901112255'") == 0


async def test_saving_a_known_person_again_adds_to_their_lead_and_does_not_open_a_second(courses):
    first = await quick(courses, group_id=courses.a)
    again = await quick(courses, group_id=courses.b, name="Nodira I.")
    assert again.status_code == 201
    # Same phone, same subject: one lead; the new group is the one offered now.
    assert again.json()["id"] == first.json()["id"] and again.json()["merged"] is True
    assert again.json()["group_id"] == courses.b
    assert await courses.pool.fetchval("select count(*) from leads") == 1


async def test_undo_archives_what_the_save_made_and_cancels_the_trial_and_deletes_nothing(courses):
    import uuid

    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    client_id = str(uuid.uuid4())
    saved = await courses.api.client.post(
        "/leads",
        json={"full_name": "Nodira", "phone": "998901112233", "client_id": client_id, "group_id": courses.a,
              "trial_starts_at": lesson["starts_at"]},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert saved.status_code == 201, saved.text
    undone = (await courses.api.client.post("/leads/undo", json={"client_id": client_id})).json()
    assert undone["undone"] is True and undone["lead"]["stage"] == "not_interested"
    assert undone["lead"]["lost_reason"] == "Qaytarildi"
    pool = courses.pool
    assert await pool.fetchval("select count(*) from leads") == 1  # archived, not deleted
    assert await pool.fetchval("select status from trial_bookings") == "cancelled"
    # Undoing twice, or an unknown save, does nothing.
    assert (await courses.api.client.post("/leads/undo", json={"client_id": client_id})).json()["undone"] is False
    assert (await courses.api.client.post("/leads/undo", json={"client_id": str(uuid.uuid4())})).json() == {
        "undone": False, "lead": None,
    }
    # The phone can be saved again right away.
    assert (await quick(courses, group_id=courses.a)).status_code == 201


async def test_undoing_a_save_that_was_folded_into_an_older_lead_leaves_that_lead_alone(courses):
    older = await quick(courses, group_id=courses.a)
    import uuid

    client_id = str(uuid.uuid4())
    merged = await courses.api.client.post(
        "/leads",
        json={"full_name": "Nodira", "phone": "998901112233", "client_id": client_id, "group_id": courses.a,
              "on_duplicate": "merge"},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert merged.json()["merged"] is True and merged.json()["id"] == older.json()["id"]
    result = (await courses.api.client.post("/leads/undo", json={"client_id": client_id})).json()
    assert result["undone"] is False
    assert (await courses.api.client.get(f"/leads/{older.json()['id']}")).json()["lead"]["stage"] == "new"


async def test_the_list_filters_by_group_groupless_trial_and_archive(courses):
    lesson = (await courses.api.client.get(f"/groups/{courses.a}/trial-dates", params={"count": 1})).json()[0]
    await quick(courses, name="Aziza", phone="998901110001", group_id=courses.a)
    await quick(courses, name="Bobur", phone="998901110002", group_id=courses.a, trial_starts_at=lesson["starts_at"])
    await quick(courses, name="Sevara", phone="998901110003", group_id=courses.b)
    await quick(courses, name="Dilnoza", phone="998901110004")
    gone = (await quick(courses, name="Eldor", phone="998901110005", group_id=courses.b)).json()
    await courses.api.client.post(f"/leads/{gone['id']}/stage", json={"stage": "not_interested", "version": gone["version"], "reason": "Qiziqmadi"})

    async def names(**params):
        page = (await courses.api.client.get("/leads", params=params)).json()
        return sorted(item["full_name"] for item in page["items"])

    assert await names() == ["Aziza", "Bobur", "Dilnoza", "Sevara"]
    assert await names(group_id=courses.a) == ["Aziza", "Bobur"]
    assert await names(group_id=courses.b) == ["Sevara"]
    assert await names(groupless="true") == ["Dilnoza"]
    assert await names(with_trial="true") == ["Bobur"]
    assert await names(archive="true") == ["Eldor"]
    assert await names(q="9011100") == ["Aziza", "Bobur", "Dilnoza", "Sevara"]
    assert await names(q="Sev") == ["Sevara"]


# --- address, and warnings that never block ----------------------------------------------------------


async def test_a_saved_person_keeps_the_parent_phone_and_address(courses):
    response = await quick(
        courses, group_id=courses.a, parent_phone="998901110000", address="Chilonzor, 7-kvartal", level="Beginner"
    )
    assert response.status_code == 201, response.text
    lead = response.json()
    assert (lead["parent_phone"], lead["address"], lead["level"]) == ("998901110000", "Chilonzor, 7-kvartal", "Beginner")


async def test_a_person_with_no_group_keeps_what_they_asked_for(courses):
    response = await quick(
        courses, subject_id=courses.french, level="A1", note="kechqurun, du-chor-ju", address="Yunusobod"
    )
    assert response.status_code == 201, response.text
    lead = response.json()
    assert (lead["group_id"], lead["subject_name"], lead["level"], lead["note"]) == (
        None, "Fransuz tili", "A1", "kechqurun, du-chor-ju",
    )


async def dupes(courses, **params):
    response = await courses.api.client.get("/leads/duplicates", params=params)
    assert response.status_code == 200, response.text
    return response.json()


async def test_the_duplicate_check_warns_about_a_phone_or_a_name_and_blocks_nothing(courses):
    pool = courses.pool
    student = await pool.fetchval(
        "insert into students (full_name, phone) values ('Nodira Ismoilova', '998901110001') returning id"
    )
    await pool.execute(
        "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, current_date)", student, courses.a
    )
    await quick(courses, name="Sevara Tursunova", phone="998901110002", group_id=courses.b)

    # A phone that belongs to a student, with the groups they study in.
    by_phone = await dupes(courses, phone="998901110001", full_name="Boshqa Odam")
    assert by_phone["phone_student"]["full_name"] == "Nodira Ismoilova"
    assert by_phone["phone_student"]["group_names"] == ["Beginner A"]
    assert by_phone["name_students"] == []

    # A phone that already has an open request.
    saved = await dupes(courses, phone="998901110002")
    assert [x["full_name"] for x in saved["phone_leads"]] == ["Sevara Tursunova"]
    assert saved["phone_leads"][0]["group_name"] == "Beginner B"

    # The same name and surname with another phone: warned, however it is spelled.
    by_name = await dupes(courses, phone="998901119999", full_name="  nodira   ISMOILOVA ")
    assert [x["phone"] for x in by_name["name_students"]] == ["998901110001"]
    by_name = await dupes(courses, phone="998901119999", full_name="sevara tursunova")
    assert [x["phone"] for x in by_name["name_leads"]] == ["998901110002"]

    # One word is not a name match; nothing found is an empty answer.
    assert (await dupes(courses, full_name="Nodira"))["name_students"] == []
    assert await dupes(courses, phone="998909998877", full_name="Yangi Odam") == {
        "phone_student": None, "phone_leads": [], "name_students": [], "name_leads": [],
    }

    # And none of it blocks: the same name and a student's phone can still be saved
    # (one person may study in several groups).
    again = await quick(courses, name="Nodira Ismoilova", phone="998901119999", group_id=courses.b)
    assert again.status_code == 201, again.text
