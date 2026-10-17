"""Group schedules, the timetable and attendance (real database)."""

from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest

from app import clock

pytestmark = pytest.mark.anyio

TZ = ZoneInfo("Asia/Tashkent")


async def seed(api) -> dict:
    pool = api.pool
    subject = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
    dilnoza = await pool.fetchval("insert into teachers (full_name) values ('Dilnoza') returning id")
    jasur = await pool.fetchval("insert into teachers (full_name) values ('Jasur') returning id")
    ielts = await pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
        "values ($1, 'IELTS', $2, 400000, 5) returning id",
        subject,
        dilnoza,
    )
    kids = await pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
        "values ($1, 'Kids', $2, 300000, 5) returning id",
        subject,
        jasur,
    )
    return {"subject": subject, "dilnoza": dilnoza, "jasur": jasur, "ielts": ielts, "kids": kids}


async def student(api, name: str, phone: str, group_id: int, joined: date, ended: date | None = None) -> int:
    student_id = await api.pool.fetchval(
        "insert into students (full_name, phone) values ($1, $2) returning id", name, phone
    )
    return await api.pool.fetchval(
        "insert into enrollments (student_id, group_id, joined_at, status, ended_at) "
        "values ($1, $2, $3, $4, $5) returning id",
        student_id,
        group_id,
        joined,
        "withdrawn" if ended else "active",
        ended,
    )


def slot(weekday: int, start: str, end: str, room: str | None = None) -> dict:
    return {"weekday": weekday, "starts_at": start, "ends_at": end, "room": room}


def last_week() -> tuple[date, date]:
    today = clock.today()
    monday = today - timedelta(days=today.isoweekday() - 1) - timedelta(days=7)
    return monday, monday + timedelta(days=6)


def at(day: date, hhmm: str) -> str:
    return datetime.combine(day, time.fromisoformat(hhmm), TZ).isoformat()


async def test_schedule_is_saved_and_checked_for_clashes(api):
    ids = await seed(api)
    saved = await api.client.put(
        f"/groups/{ids['ielts']}/schedule",
        json={"slots": [slot(1, "14:00", "15:30", "5-xona"), slot(3, "14:00", "15:30", "5-xona")]},
    )
    assert saved.status_code == 200, saved.text
    assert [s["weekday"] for s in saved.json()["slots"]] == [1, 3]
    listed = {g["name"]: g for g in (await api.client.get("/groups")).json()}
    assert [(s["weekday"], s["starts_at"], s["room"]) for s in listed["IELTS"]["schedule"]] == [
        (1, "14:00:00", "5-xona"),
        (3, "14:00:00", "5-xona"),
    ]
    assert listed["Kids"]["schedule"] == []

    overlapping = await api.client.put(
        f"/groups/{ids['ielts']}/schedule",
        json={"slots": [slot(1, "14:00", "15:30"), slot(1, "15:00", "16:00")]},
    )
    assert overlapping.status_code == 400

    # Kids in the same room at the same time.
    room = await api.client.put(
        f"/groups/{ids['kids']}/schedule", json={"slots": [slot(1, "15:00", "16:00", "5-XONA")]}
    )
    assert room.status_code == 409 and "xonasi bu vaqtda band" in room.json()["detail"]

    # Elsewhere, fine; then Dilnoza can't take Kids into that slot.
    ok = await api.client.put(f"/groups/{ids['kids']}/schedule", json={"slots": [slot(1, "15:00", "16:00", "2")]})
    assert ok.status_code == 200
    teacher = await api.client.patch(f"/groups/{ids['kids']}", json={"teacher_id": ids["dilnoza"]})
    assert teacher.status_code == 409 and "Dilnoza bu vaqtda band" in teacher.json()["detail"]


async def test_timetable_lists_each_lesson_in_center_time_with_its_class_size(api):
    ids = await seed(api)
    monday, sunday = last_week()
    await api.client.put(
        f"/groups/{ids['ielts']}/schedule", json={"slots": [slot(1, "14:00", "15:30"), slot(5, "09:00", "10:00")]}
    )
    await student(api, "Aziz", "998901000001", ids["ielts"], monday - timedelta(days=30))
    await student(api, "Bek", "998901000002", ids["ielts"], monday + timedelta(days=2))  # joined Wednesday
    await student(api, "Dina", "998901000003", ids["ielts"], monday - timedelta(days=30), ended=monday + timedelta(days=1))

    lessons = (
        await api.client.get("/timetable", params={"date_from": monday.isoformat(), "date_to": sunday.isoformat()})
    ).json()

    starts = [datetime.fromisoformat(lesson["starts_at"]) for lesson in lessons]
    # 14:00 Monday and 09:00 Friday in Tashkent, whatever the server's zone.
    assert starts == [
        datetime.combine(monday, time(14), TZ),
        datetime.combine(monday + timedelta(days=4), time(9), TZ),
    ]
    # Monday: Aziz and Dina (she left Tuesday). Friday: Aziz and Bek.
    assert [lesson["student_count"] for lesson in lessons] == [2, 2]
    assert all(lesson["status"] == "scheduled" and lesson["lesson_id"] is None for lesson in lessons)

    # An inactive group's lessons don't show.
    await api.pool.execute("update groups set is_active = false where id = $1", ids["ielts"])
    lessons = (
        await api.client.get("/timetable", params={"date_from": monday.isoformat(), "date_to": sunday.isoformat()})
    ).json()
    assert lessons == []


async def test_attendance_is_marked_once_per_student_and_only_for_the_class(api):
    ids = await seed(api)
    monday, _ = last_week()
    await api.client.put(f"/groups/{ids['ielts']}/schedule", json={"slots": [slot(1, "14:00", "15:30")]})
    aziz = await student(api, "Aziz", "998901000001", ids["ielts"], monday - timedelta(days=30))
    bek = await student(api, "Bek", "998901000002", ids["ielts"], monday - timedelta(days=30))
    later = await student(api, "Late joiner", "998901000003", ids["ielts"], monday + timedelta(days=3))
    lesson_at = at(monday, "14:00")

    sheet = (await api.client.get("/lessons/sheet", params={"group_id": ids["ielts"], "starts_at": lesson_at})).json()
    assert [s["full_name"] for s in sheet["students"]] == ["Aziz", "Bek"]
    assert sheet["lesson"]["lesson_id"] is None

    body = {
        "group_id": ids["ielts"],
        "starts_at": lesson_at,
        "marks": [{"enrollment_id": aziz, "status": "present"}, {"enrollment_id": bek, "status": "absent"}],
    }
    first = await api.client.put("/lessons/attendance", json=body)
    assert first.status_code == 200, first.text
    again = await api.client.put("/lessons/attendance", json=body)
    assert again.status_code == 200
    assert await api.pool.fetchval("select count(*) from lessons") == 1
    assert await api.pool.fetchval("select count(*) from attendance") == 2
    # Nothing about money or enrollment changes.
    assert await api.pool.fetchval("select count(*) from charges") == 0

    corrected = await api.client.put(
        "/lessons/attendance",
        json={**body, "marks": [{"enrollment_id": bek, "status": "excused", "note": "Kasal"}]},
    )
    marks = {s["full_name"]: s["status"] for s in corrected.json()["students"]}
    assert marks == {"Aziz": "present", "Bek": "excused"}

    outsider = await api.client.put(
        "/lessons/attendance", json={**body, "marks": [{"enrollment_id": later, "status": "present"}]}
    )
    assert outsider.status_code == 400

    no_lesson = await api.client.put("/lessons/attendance", json={**body, "starts_at": at(monday, "16:00")})
    assert no_lesson.status_code == 404


async def test_future_lessons_cannot_be_marked(api):
    ids = await seed(api)
    tomorrow = clock.today() + timedelta(days=1)
    await api.client.put(
        f"/groups/{ids['ielts']}/schedule", json={"slots": [slot(tomorrow.isoweekday(), "10:00", "11:00")]}
    )
    enrollment = await student(api, "Aziz", "998901000001", ids["ielts"], tomorrow - timedelta(days=30))
    response = await api.client.put(
        "/lessons/attendance",
        json={
            "group_id": ids["ielts"],
            "starts_at": at(tomorrow, "10:00"),
            "marks": [{"enrollment_id": enrollment, "status": "present"}],
        },
    )
    assert response.status_code == 409 and response.json()["detail"] == "Dars hali boshlanmagan."


async def test_cancelling_and_restoring_a_lesson(api):
    ids = await seed(api)
    monday, sunday = last_week()
    await api.client.put(
        f"/groups/{ids['ielts']}/schedule", json={"slots": [slot(1, "14:00", "15:30"), slot(3, "14:00", "15:30")]}
    )
    aziz = await student(api, "Aziz", "998901000001", ids["ielts"], monday - timedelta(days=30))
    await api.client.put(
        "/lessons/attendance",
        json={"group_id": ids["ielts"], "starts_at": at(monday, "14:00"), "marks": [{"enrollment_id": aziz, "status": "present"}]},
    )

    marked = await api.client.post("/lessons/cancel", json={"group_id": ids["ielts"], "starts_at": at(monday, "14:00")})
    assert marked.status_code == 409

    wednesday = at(monday + timedelta(days=2), "14:00")
    cancelled = await api.client.post(
        "/lessons/cancel", json={"group_id": ids["ielts"], "starts_at": wednesday, "reason": "Bayram"}
    )
    assert cancelled.status_code == 200
    assert (cancelled.json()["status"], cancelled.json()["cancel_reason"]) == ("cancelled", "Bayram")
    on_cancelled = await api.client.put(
        "/lessons/attendance",
        json={"group_id": ids["ielts"], "starts_at": wednesday, "marks": [{"enrollment_id": aziz, "status": "present"}]},
    )
    assert on_cancelled.status_code == 409

    restored = await api.client.post("/lessons/restore", json={"group_id": ids["ielts"], "starts_at": wednesday})
    assert restored.json()["status"] == "scheduled"
    week = (
        await api.client.get("/timetable", params={"date_from": monday.isoformat(), "date_to": sunday.isoformat()})
    ).json()
    assert [(lesson["status"], lesson["marked_count"], lesson["present_count"]) for lesson in week] == [
        ("scheduled", 1, 1),
        ("scheduled", 0, 0),
    ]


async def test_extra_lessons_and_their_clashes(api):
    ids = await seed(api)
    monday, sunday = last_week()
    # Jasur teaches Kids on Tuesdays 10-11.
    await api.client.put(f"/groups/{ids['kids']}/schedule", json={"slots": [slot(2, "10:00", "11:00")]})
    await api.pool.execute("update groups set teacher_id = $2 where id = $1", ids["ielts"], ids["jasur"])
    tuesday = monday + timedelta(days=1)

    clash = await api.client.post(
        "/lessons",
        json={"group_id": ids["ielts"], "starts_at": at(tuesday, "10:30"), "ends_at": at(tuesday, "11:30")},
    )
    assert clash.status_code == 409 and "Jasur bu vaqtda dars beradi" in clash.json()["detail"]

    extra = await api.client.post(
        "/lessons",
        json={"group_id": ids["ielts"], "starts_at": at(tuesday, "12:00"), "ends_at": at(tuesday, "13:00"), "note": "Imtihon"},
    )
    assert extra.status_code == 201, extra.text
    assert extra.json()["is_extra"] is True
    week = (
        await api.client.get(
            "/timetable",
            params={"date_from": monday.isoformat(), "date_to": sunday.isoformat(), "teacher_id": ids["jasur"]},
        )
    ).json()
    assert [lesson["group_name"] for lesson in week] == ["Kids", "IELTS"]


async def test_attendance_report(api):
    ids = await seed(api)
    monday, sunday = last_week()
    await api.client.put(
        f"/groups/{ids['ielts']}/schedule", json={"slots": [slot(1, "14:00", "15:00"), slot(3, "14:00", "15:00")]}
    )
    aziz = await student(api, "Aziz", "998901000001", ids["ielts"], monday - timedelta(days=30))
    bek = await student(api, "Bek", "998901000002", ids["ielts"], monday - timedelta(days=30))
    for day, marks in (
        (monday, [(aziz, "present"), (bek, "absent")]),
        (monday + timedelta(days=2), [(aziz, "late"), (bek, "absent")]),
    ):
        await api.client.put(
            "/lessons/attendance",
            json={
                "group_id": ids["ielts"],
                "starts_at": at(day, "14:00"),
                "marks": [{"enrollment_id": e, "status": s} for e, s in marks],
            },
        )

    report = (
        await api.client.get(
            "/attendance/report", params={"date_from": monday.isoformat(), "date_to": sunday.isoformat()}
        )
    ).json()
    assert [(r["full_name"], r["lessons"], r["absent"], r["rate"]) for r in report] == [
        ("Bek", 2, 2, 0.0),
        ("Aziz", 2, 0, 1.0),
    ]


async def test_trial_sessions_respect_regular_lessons(api):
    ids = await seed(api)
    tomorrow = clock.today() + timedelta(days=1)
    await api.client.put(
        f"/groups/{ids['ielts']}/schedule",
        json={"slots": [slot(tomorrow.isoweekday(), "10:00", "11:30", "5-xona")]},
    )
    lead = (await api.client.post("/leads", json={"full_name": "Aziza", "phone": "998907000001"})).json()

    def session(start: str, end: str, **extra) -> dict:
        return {"kind": "dedicated", "starts_at": at(tomorrow, start), "ends_at": at(tomorrow, end), "capacity": 3, **extra}

    teacher = await api.client.post(
        "/trial-bookings", json={"lead_id": lead["id"], "session": session("10:30", "11:00", teacher_id=ids["dilnoza"])}
    )
    assert teacher.status_code == 409 and "Dilnoza bu vaqtda dars beradi" in teacher.json()["detail"]
    room = await api.client.post(
        "/trial-bookings", json={"lead_id": lead["id"], "session": session("11:00", "12:00", room="5-xona")}
    )
    assert room.status_code == 409 and "xonasi bu vaqtda band" in room.json()["detail"]
    # A guest seat at that very group's lesson is the point, not a clash.
    guest = await api.client.post(
        "/trial-bookings",
        json={
            "lead_id": lead["id"],
            "session": {
                "kind": "group_lesson",
                "group_id": ids["ielts"],
                "starts_at": at(tomorrow, "10:00"),
                "ends_at": at(tomorrow, "11:30"),
                "capacity": 2,
            },
        },
    )
    assert guest.status_code == 201, guest.text
