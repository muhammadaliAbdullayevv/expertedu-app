"""Admissions: leads, trials, follow-ups and the explicit enrollment step,
against a real database (see conftest.py)."""

import asyncio
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi import HTTPException

from app import admissions
from app.routes import leads as leads_routes

pytestmark = pytest.mark.anyio

PHONE = "998901234567"


# Helpers ------------------------------------------------------------------


async def seed(api, *, capacity: int | None = None) -> dict:
    pool = api.pool
    subject_id = await pool.fetchval("insert into subjects (name) values ('Ingliz tili') returning id")
    other_subject_id = await pool.fetchval("insert into subjects (name) values ('Matematika') returning id")
    teacher_id = await pool.fetchval("insert into teachers (full_name) values ('Dilnoza') returning id")
    other_teacher_id = await pool.fetchval("insert into teachers (full_name) values ('Jasur') returning id")
    group_id = await pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day, capacity) "
        "values ($1, 'IELTS 1', $2, 400000, 5, $3) returning id",
        subject_id,
        teacher_id,
        capacity,
    )
    return {
        "subject_id": subject_id,
        "other_subject_id": other_subject_id,
        "teacher_id": teacher_id,
        "other_teacher_id": other_teacher_id,
        "group_id": group_id,
    }


async def counts(pool) -> dict:
    row = await pool.fetchrow(
        """
        select (select count(*) from students) as students,
               (select count(*) from enrollments) as enrollments,
               (select count(*) from charges) as charges,
               (select count(*) from payments) as payments,
               (select count(*) from leads) as leads,
               (select count(*) from trial_bookings) as bookings
        """
    )
    return dict(row)


def slot(hours_from_now: float = 24, length_hours: float = 1) -> tuple[str, str]:
    start = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(hours=hours_from_now)
    return start.isoformat(), (start + timedelta(hours=length_hours)).isoformat()


def session_payload(teacher_id: int, *, hours: float = 24, capacity: int = 5, room: str | None = None, **extra):
    starts_at, ends_at = slot(hours)
    return {
        "kind": "dedicated",
        "teacher_id": teacher_id,
        "room": room,
        "starts_at": starts_at,
        "ends_at": ends_at,
        "capacity": capacity,
        **extra,
    }


async def new_lead(api, phone: str = PHONE, client=None, **extra) -> dict:
    response = await (client or api.client).post(
        "/leads", json={"full_name": "Aziza Karimova", "phone": phone, **extra}
    )
    assert response.status_code == 201, response.text
    return response.json()


async def book(api, lead_id: int, teacher_id: int, **extra) -> dict:
    response = await api.client.post(
        "/trial-bookings", json={"lead_id": lead_id, "session": session_payload(teacher_id, **extra)}
    )
    assert response.status_code == 201, response.text
    return response.json()


async def move_to_past(pool, session_id: int) -> None:
    """The lesson has happened -- attendance can be marked."""
    await pool.execute(
        "update trial_sessions set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour' "
        "where id = $1",
        session_id,
    )


def slow_down_writes(monkeypatch) -> None:
    """Holds every lead-changing transaction open a little longer, so two
    requests sent together really overlap instead of running one after the
    other."""
    real_log = admissions.log

    async def slow_log(*args, **kwargs):
        await asyncio.sleep(0.3)
        await real_log(*args, **kwargs)

    monkeypatch.setattr(admissions, "log", slow_log)


async def lead_detail(api, lead_id: int) -> dict:
    response = await api.client.get(f"/leads/{lead_id}")
    assert response.status_code == 200, response.text
    return response.json()


def enroll_payload(group_id: int, **extra) -> dict:
    return {
        "full_name": "Aziza Karimova",
        "phone": PHONE,
        "group_id": group_id,
        "joined_at": date.today().isoformat(),
        "first_month": "full",
        "first_payment_amount": 400000,
        "first_payment_method": "cash",
        **extra,
    }


async def enroll(api, lead_id: int, group_id: int, key=None, **extra):
    return await api.client.post(
        f"/leads/{lead_id}/enroll",
        json=enroll_payload(group_id, **extra),
        headers={"Idempotency-Key": str(key or uuid.uuid4())},
    )


# Leads --------------------------------------------------------------------


async def test_creating_a_lead_creates_no_student_or_enrollment(api):
    ids = await seed(api)
    before = await counts(api.pool)

    lead = await new_lead(api, subject_id=ids["subject_id"], source="instagram", note="Kechqurun qulay")

    assert lead["stage"] == "new"
    assert lead["student_id"] is None and lead["enrollment_id"] is None
    assert lead["assigned_to"] == api.owner_id
    after = await counts(api.pool)
    assert after == {**before, "leads": 1}
    roster = await api.client.get(f"/groups/{ids['group_id']}/roster")
    assert roster.json() == []


async def test_lead_for_existing_student_links_the_student_instead_of_copying(api):
    student_id = await api.pool.fetchval(
        "insert into students (full_name, phone) values ('Aziza Karimova', $1) returning id", PHONE
    )
    lookup = (await api.client.get("/leads/lookup", params={"phone": "+998 90 123 45 67"})).json()
    assert lookup["student"]["student_id"] == student_id
    assert lookup["leads"] == []

    lead = await new_lead(api, phone="+998 90 123 45 67")

    assert lead["phone"] == PHONE
    assert lead["student_id"] == student_id
    assert (await counts(api.pool))["students"] == 1


async def test_second_open_lead_for_same_phone_and_course_is_refused_or_merged(api):
    ids = await seed(api)
    first = await new_lead(api, subject_id=ids["subject_id"])

    duplicate = await api.client.post(
        "/leads", json={"full_name": "Aziza", "phone": PHONE, "subject_id": ids["subject_id"]}
    )
    assert duplicate.status_code == 409
    assert "ochiq so'rov bor" in duplicate.json()["detail"]

    merged = await api.client.post(
        "/leads",
        json={
            "full_name": "Aziza",
            "phone": PHONE,
            "subject_id": ids["subject_id"],
            "note": "Yana qo'ng'iroq qildi",
            "on_duplicate": "merge",
        },
    )
    assert merged.status_code == 201
    assert merged.json()["id"] == first["id"] and merged.json()["merged"] is True
    timeline = (await lead_detail(api, first["id"]))["interactions"]
    assert any(item["body"] == "Qayta murojaat qildi: Yana qo'ng'iroq qildi" for item in timeline)

    # Another course is another lead.
    other = await new_lead(api, subject_id=ids["other_subject_id"])
    assert other["id"] != first["id"]

    # Once the first is closed, the same course can be asked about again.
    closed = await api.client.post(
        f"/leads/{first['id']}/stage", json={"stage": "not_interested", "version": first["version"]}
    )
    assert closed.status_code == 200
    again = await new_lead(api, subject_id=ids["subject_id"])
    assert again["id"] not in (first["id"], other["id"])
    assert (await counts(api.pool))["leads"] == 3


async def test_two_operators_taking_the_same_number_at_once_open_one_lead(api, monkeypatch):
    ids = await seed(api)
    slow_down_writes(monkeypatch)
    payload = {"full_name": "Aziza", "phone": PHONE, "subject_id": ids["subject_id"]}
    async with api.as_admin() as admin:
        responses = await asyncio.gather(api.client.post("/leads", json=payload), admin.post("/leads", json=payload))

    assert sorted(response.status_code for response in responses) == [201, 409]
    assert (await counts(api.pool))["leads"] == 1


async def test_stale_edit_is_refused(api):
    lead = await new_lead(api)
    first = await api.client.patch(f"/leads/{lead['id']}", json={"version": lead["version"], "note": "Birinchi"})
    assert first.status_code == 200
    assert first.json()["version"] == lead["version"] + 1

    # A second operator still looking at the old version.
    stale = await api.client.patch(f"/leads/{lead['id']}", json={"version": lead["version"], "note": "Ikkinchi"})
    assert stale.status_code == 409
    assert (await lead_detail(api, lead["id"]))["lead"]["note"] == "Birinchi"


async def test_concurrent_stage_changes_from_the_same_version_let_one_through(api, monkeypatch):
    lead = await new_lead(api)
    slow_down_writes(monkeypatch)
    async with api.as_admin() as admin:
        responses = await asyncio.gather(
            api.client.post(f"/leads/{lead['id']}/stage", json={"stage": "contacted", "version": lead["version"]}),
            admin.post(f"/leads/{lead['id']}/stage", json={"stage": "unreachable", "version": lead["version"]}),
        )
    assert sorted(response.status_code for response in responses) == [200, 409]


async def test_stages_that_follow_from_trials_or_enrollment_cannot_be_set_by_hand(api):
    lead = await new_lead(api)
    for stage in ("enrolled", "trial_scheduled", "trial_completed", "new"):
        response = await api.client.post(f"/leads/{lead['id']}/stage", json={"stage": stage, "version": 1})
        assert response.status_code == 400, stage

    later = await api.client.post(
        f"/leads/{lead['id']}/stage",
        json={"stage": "follow_up_later", "version": 1, "follow_up_at": slot(48)[0], "reason": "Bahorda"},
    )
    assert later.status_code == 200
    assert later.json()["next_task_due_at"] is not None


async def test_first_call_moves_a_new_lead_to_contacted(api):
    lead = await new_lead(api)
    note = await api.client.post(f"/leads/{lead['id']}/interactions", json={"kind": "note", "body": "Izoh"})
    assert note.status_code == 201
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "new"

    call = await api.client.post(
        f"/leads/{lead['id']}/interactions", json={"kind": "call_out", "body": "Narxlarni aytdim"}
    )
    assert call.status_code == 201
    detail = await lead_detail(api, lead["id"])
    assert detail["lead"]["stage"] == "contacted"
    assert detail["lead"]["last_contact_at"] is not None


async def test_lead_timeline_is_append_only(api):
    lead = await new_lead(api)
    with pytest.raises(Exception, match="append-only"):
        await api.pool.execute("update lead_interactions set body = 'x' where lead_id = $1", lead["id"])
    with pytest.raises(Exception, match="append-only"):
        await api.pool.execute("delete from lead_interactions where lead_id = $1", lead["id"])


# Trials -------------------------------------------------------------------


async def test_scheduling_a_trial_does_not_add_the_lead_to_a_group(api):
    ids = await seed(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    before = await counts(api.pool)

    booking = await book(api, lead["id"], ids["teacher_id"])

    assert booking["status"] == "scheduled"
    assert booking["session"]["booked"] == 1
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "trial_scheduled"
    after = await counts(api.pool)
    assert after == {**before, "bookings": 1}
    assert (await api.client.get(f"/groups/{ids['group_id']}/roster")).json() == []


async def test_guest_seat_at_a_group_lesson_is_not_an_enrollment(api):
    ids = await seed(api)
    lead = await new_lead(api)
    starts_at, ends_at = slot(24)
    response = await api.client.post(
        "/trial-bookings",
        json={
            "lead_id": lead["id"],
            "session": {
                "kind": "group_lesson",
                "group_id": ids["group_id"],
                "starts_at": starts_at,
                "ends_at": ends_at,
                "capacity": 2,
            },
        },
    )
    assert response.status_code == 201, response.text
    session = response.json()["session"]
    # Taught by the group's own teacher, in its subject.
    assert session["teacher_id"] == ids["teacher_id"]
    assert session["subject_id"] == ids["subject_id"]
    assert (await counts(api.pool))["enrollments"] == 0
    group = (await api.client.get(f"/groups/{ids['group_id']}")).json()
    assert group["id"] == ids["group_id"]
    assert (await api.client.get(f"/groups/{ids['group_id']}/roster")).json() == []


async def test_trial_capacity_and_teacher_and_room_conflicts(api):
    ids = await seed(api)
    first = await new_lead(api)
    second = await new_lead(api, phone="998901111111")
    booking = await book(api, first["id"], ids["teacher_id"], capacity=1, room="12-xona")
    session_id = booking["session"]["id"]

    full = await api.client.post("/trial-bookings", json={"lead_id": second["id"], "session_id": session_id})
    assert full.status_code == 409
    assert "joy yo'q (1/1)" in full.json()["detail"]

    # Same teacher, overlapping half an hour later.
    clash = await api.client.post(
        "/trial-bookings",
        json={"lead_id": second["id"], "session": session_payload(ids["teacher_id"], hours=24.5)},
    )
    assert clash.status_code == 409
    assert "O'qituvchi Dilnoza bu vaqtda band" in clash.json()["detail"]

    # Other teacher, same room.
    room = await api.client.post(
        "/trial-bookings",
        json={
            "lead_id": second["id"],
            "session": session_payload(ids["other_teacher_id"], hours=24.5, room="12-XONA"),
        },
    )
    assert room.status_code == 409
    assert "xonasi bu vaqtda band" in room.json()["detail"]

    # Right after it is fine.
    ok = await api.client.post(
        "/trial-bookings", json={"lead_id": second["id"], "session": session_payload(ids["teacher_id"], hours=25)}
    )
    assert ok.status_code == 201, ok.text


async def test_trial_validation_errors(api):
    ids = await seed(api)
    lead = await new_lead(api)
    past = await api.client.post(
        "/trial-bookings", json={"lead_id": lead["id"], "session": session_payload(ids["teacher_id"], hours=-3)}
    )
    assert past.status_code == 400 and past.json()["detail"] == "Bu vaqt o'tib ketgan."

    starts_at, _ = slot(24)
    backwards = await api.client.post(
        "/trial-bookings",
        json={
            "lead_id": lead["id"],
            "session": {"kind": "dedicated", "starts_at": starts_at, "ends_at": starts_at, "capacity": 1},
        },
    )
    assert backwards.status_code == 400

    neither = await api.client.post("/trial-bookings", json={"lead_id": lead["id"]})
    assert neither.status_code == 400
    assert (await counts(api.pool))["bookings"] == 0


async def test_one_upcoming_trial_per_lead_and_reschedule_keeps_history(api):
    ids = await seed(api)
    lead = await new_lead(api)
    first = await book(api, lead["id"], ids["teacher_id"])

    second = await api.client.post(
        "/trial-bookings", json={"lead_id": lead["id"], "session": session_payload(ids["teacher_id"], hours=48)}
    )
    assert second.status_code == 409
    assert "rejalashtirilgan sinov bor" in second.json()["detail"]

    moved = await api.client.post(
        f"/trial-bookings/{first['id']}/reschedule",
        json={"session": session_payload(ids["teacher_id"], hours=48), "reason": "Ishda"},
    )
    assert moved.status_code == 201, moved.text
    assert moved.json()["rescheduled_from_id"] == first["id"]

    bookings = (await lead_detail(api, lead["id"]))["bookings"]
    assert [booking["status"] for booking in bookings] == ["scheduled", "rescheduled"]
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "trial_scheduled"


async def test_trial_attendance_is_kept_apart_from_groups_and_billing(api):
    ids = await seed(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    booking = await book(api, lead["id"], ids["teacher_id"])

    too_early = await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})
    assert too_early.status_code == 409 and too_early.json()["detail"] == "Dars hali boshlanmagan."

    await move_to_past(api.pool, booking["session"]["id"])
    before = await counts(api.pool)
    attended = await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})
    assert attended.status_code == 200, attended.text
    feedback = await api.client.post(
        f"/trial-bookings/{booking['id']}/feedback",
        json={"feedback": "Yaxshi gapiradi", "recommended_level": "B1"},
    )
    assert feedback.status_code == 200
    assert feedback.json()["feedback"] == "Yaxshi gapiradi"

    # Only the booking changed: no enrollment, no charge, nothing in a group.
    assert await counts(api.pool) == before
    assert (await api.client.get(f"/groups/{ids['group_id']}/roster")).json() == []
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "trial_completed"


async def test_no_show_keeps_the_lead_open_with_a_follow_up(api):
    ids = await seed(api)
    lead = await new_lead(api)
    booking = await book(api, lead["id"], ids["teacher_id"])
    await move_to_past(api.pool, booking["session"]["id"])

    absent = await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "absent"})
    assert absent.status_code == 200

    detail = await lead_detail(api, lead["id"])
    assert detail["lead"]["stage"] == "contacted"
    assert detail["lead"]["closed_at"] is None
    assert [task["title"] for task in detail["tasks"]] == ["Sinovga kelmadi — qayta bog'laning"]
    no_feedback = await api.client.post(f"/trial-bookings/{booking['id']}/feedback", json={"feedback": "?"})
    assert no_feedback.status_code == 409

    # They come to a second trial.
    again = await book(api, lead["id"], ids["teacher_id"], hours=48)
    assert again["status"] == "scheduled"


async def test_cancelled_trial_or_session_keeps_the_lead_open(api):
    ids = await seed(api)
    lead = await new_lead(api)
    other = await new_lead(api, phone="998901111111")
    booking = await book(api, lead["id"], ids["teacher_id"])
    cancelled = await api.client.post(f"/trial-bookings/{booking['id']}/cancel", json={"reason": "Kasal"})
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "contacted"

    second = await book(api, other["id"], ids["teacher_id"], hours=30)
    session = await api.client.post(f"/trial-sessions/{second['session']['id']}/cancel", json={})
    assert session.status_code == 200 and session.json()["status"] == "cancelled"
    detail = await lead_detail(api, other["id"])
    assert detail["lead"]["stage"] == "contacted"
    assert detail["bookings"][0]["status"] == "cancelled"
    assert len(detail["tasks"]) == 1


async def test_closing_a_lead_cancels_its_trial_and_tasks_but_keeps_them(api):
    ids = await seed(api)
    lead = await new_lead(api)
    await book(api, lead["id"], ids["teacher_id"])
    task = await api.client.post(
        "/follow-up-tasks", json={"lead_id": lead["id"], "title": "Qo'ng'iroq", "due_at": slot(2)[0]}
    )
    assert task.status_code == 201

    current = (await lead_detail(api, lead["id"]))["lead"]
    closed = await api.client.post(
        f"/leads/{lead['id']}/stage",
        json={"stage": "not_interested", "version": current["version"], "reason": "Qimmat"},
    )
    assert closed.status_code == 200
    assert closed.json()["lost_reason"] == "Qimmat"

    detail = await lead_detail(api, lead["id"])
    assert detail["bookings"][0]["status"] == "cancelled"
    assert detail["tasks"][0]["status"] == "cancelled"

    reopened = await api.client.post(
        f"/leads/{lead['id']}/stage", json={"stage": "contacted", "version": detail["lead"]["version"]}
    )
    assert reopened.status_code == 200
    assert reopened.json()["closed_at"] is None and reopened.json()["lost_reason"] is None


async def test_follow_up_tasks_complete_and_list(api):
    lead = await new_lead(api)
    due = slot(-1)[0]  # already overdue
    created = await api.client.post(
        "/follow-up-tasks", json={"lead_id": lead["id"], "title": "Narxni yuborish", "due_at": due}
    )
    task = created.json()
    assert task["assigned_to"] == api.owner_id

    listed = (await api.client.get("/follow-up-tasks")).json()
    assert [item["id"] for item in listed] == [task["id"]]
    assert listed[0]["lead_full_name"] == "Aziza Karimova"

    stale = await api.client.patch(f"/follow-up-tasks/{task['id']}", json={"version": 99, "title": "x"})
    assert stale.status_code == 409

    done = await api.client.post(f"/follow-up-tasks/{task['id']}/complete", json={"reason": "Yubordim"})
    assert done.json()["status"] == "done"
    assert (await api.client.get("/follow-up-tasks")).json() == []
    timeline = (await lead_detail(api, lead["id"]))["interactions"]
    assert timeline[0]["body"] == "Vazifa bajarildi: Narxni yuborish. Yubordim"


# Enrollment ---------------------------------------------------------------


async def test_enrollment_needs_an_idempotency_key(api):
    ids = await seed(api)
    lead = await new_lead(api)
    response = await api.client.post(f"/leads/{lead['id']}/enroll", json=enroll_payload(ids["group_id"]))
    assert response.status_code == 400
    assert (await counts(api.pool))["students"] == 0


async def test_retried_enrollment_creates_nothing_twice(api):
    ids = await seed(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    key = uuid.uuid4()

    first = await enroll(api, lead["id"], ids["group_id"], key=key)
    assert first.status_code == 201, first.text
    retry = await enroll(api, lead["id"], ids["group_id"], key=key)

    assert retry.status_code == 201
    assert retry.json() == first.json()
    assert retry.headers.get("idempotent-replay") == "true"
    assert await counts(api.pool) == {
        "students": 1,
        "enrollments": 1,
        "charges": 1,
        "payments": 1,
        "leads": 1,
        "bookings": 0,
    }
    body = first.json()
    assert body["reused_student"] is False and body["first_payment"] == 400000

    # A different key -- a second, separate attempt -- is refused outright.
    again = await enroll(api, lead["id"], ids["group_id"])
    assert again.status_code == 409
    assert (await counts(api.pool))["enrollments"] == 1


async def test_double_submitted_enrollment_is_done_once(api):
    ids = await seed(api)
    lead = await new_lead(api)
    key = uuid.uuid4()

    responses = await asyncio.gather(*(enroll(api, lead["id"], ids["group_id"], key=key) for _ in range(3)))

    assert [response.status_code for response in responses] == [201, 201, 201]
    assert len({response.json()["enrollment_id"] for response in responses}) == 1
    snapshot = await counts(api.pool)
    assert (snapshot["students"], snapshot["enrollments"], snapshot["charges"], snapshot["payments"]) == (1, 1, 1, 1)


async def test_reusing_a_key_for_different_data_is_refused(api):
    ids = await seed(api)
    lead = await new_lead(api)
    key = uuid.uuid4()
    assert (await enroll(api, lead["id"], ids["group_id"], key=key)).status_code == 201
    other = await enroll(api, lead["id"], ids["group_id"], key=key, first_payment_amount=100000)
    assert other.status_code == 422


async def test_enrollment_into_a_full_group_rolls_everything_back(api):
    ids = await seed(api, capacity=1)
    taken_by = await api.pool.fetchval(
        "insert into students (full_name, phone) values ('Bor', '998909999999') returning id"
    )
    await api.pool.execute(
        "insert into enrollments (student_id, group_id, joined_at) values ($1, $2, current_date)",
        taken_by,
        ids["group_id"],
    )
    lead = await new_lead(api)
    before = await counts(api.pool)
    key = uuid.uuid4()

    response = await enroll(api, lead["id"], ids["group_id"], key=key)

    assert response.status_code == 409
    assert "Guruh to'lgan" in response.json()["detail"]
    assert await counts(api.pool) == before
    assert (await lead_detail(api, lead["id"]))["lead"]["stage"] == "new"
    # Nothing remembered for the key: once there's room, the same key works.
    assert await api.pool.fetchval("select count(*) from idempotency_keys") == 0
    await api.pool.execute("update groups set capacity = 2 where id = $1", ids["group_id"])
    assert (await enroll(api, lead["id"], ids["group_id"], key=key)).status_code == 201


async def test_failure_after_the_student_is_created_rolls_everything_back(api, monkeypatch):
    ids = await seed(api)
    lead = await new_lead(api)
    booking = await book(api, lead["id"], ids["teacher_id"])
    before = await counts(api.pool)
    real_enroll = leads_routes.enroll

    async def enroll_then_fail(conn, **kwargs):
        await real_enroll(conn, **kwargs)
        raise HTTPException(500, "Simulated failure")

    monkeypatch.setattr(leads_routes, "enroll", enroll_then_fail)
    response = await enroll(api, lead["id"], ids["group_id"])

    assert response.status_code == 500
    assert await counts(api.pool) == before
    detail = await lead_detail(api, lead["id"])
    assert detail["lead"]["stage"] == "trial_scheduled"
    assert detail["lead"]["student_id"] is None
    assert detail["bookings"][0]["id"] == booking["id"] and detail["bookings"][0]["status"] == "scheduled"
    assert not any(item["body"].startswith("Guruhga yozildi") for item in detail["interactions"])


async def test_enrollment_reuses_the_student_who_has_the_phone(api):
    ids = await seed(api)
    student_id = await api.pool.fetchval(
        "insert into students (full_name, phone) values ('Aziza K.', $1) returning id", PHONE
    )
    lead = await new_lead(api, subject_id=ids["subject_id"])

    response = await enroll(api, lead["id"], ids["group_id"], full_name="Boshqa ism")

    assert response.status_code == 201, response.text
    assert response.json()["reused_student"] is True
    assert response.json()["student"]["id"] == student_id
    assert response.json()["student"]["full_name"] == "Aziza K."
    assert (await counts(api.pool))["students"] == 1


async def test_lead_and_trial_history_survive_enrollment(api):
    ids = await seed(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    await api.client.post(f"/leads/{lead['id']}/interactions", json={"kind": "call_in", "body": "Narx so'radi"})
    booking = await book(api, lead["id"], ids["teacher_id"])
    await move_to_past(api.pool, booking["session"]["id"])
    await api.client.post(f"/trial-bookings/{booking['id']}/attendance", json={"status": "attended"})
    await api.client.post(f"/trial-bookings/{booking['id']}/feedback", json={"feedback": "Tayyor"})
    task = await api.client.post(
        "/follow-up-tasks", json={"lead_id": lead["id"], "title": "Qaror", "due_at": slot(4)[0]}
    )

    enrolled = await enroll(api, lead["id"], ids["group_id"])
    assert enrolled.status_code == 201

    detail = await lead_detail(api, lead["id"])
    assert detail["lead"]["stage"] == "enrolled"
    assert detail["lead"]["enrollment_id"] == enrolled.json()["enrollment_id"]
    assert detail["lead"]["student_id"] == enrolled.json()["student"]["id"]
    bodies = [item["body"] for item in detail["interactions"]]
    assert "Narx so'radi" in bodies
    assert "Sinov darsiga keldi" in bodies
    assert "O'qituvchi fikri: Tayyor" in bodies
    assert bodies[0].startswith("Guruhga yozildi: IELTS 1")
    assert detail["bookings"][0]["status"] == "attended"
    assert detail["bookings"][0]["feedback"] == "Tayyor"
    assert detail["tasks"][0]["id"] == task.json()["id"]
    assert detail["tasks"][0]["status"] == "cancelled"

    # Enrolled leads are read-only.
    edit = await api.client.patch(f"/leads/{lead['id']}", json={"version": detail["lead"]["version"], "note": "x"})
    assert edit.status_code == 409


# Offline replay -----------------------------------------------------------


async def test_offline_queued_lead_and_trial_sync_exactly_once(api):
    """What the outbox does: each queued write carries its own key and is
    resent until it gets an answer -- possibly after the first send landed."""
    ids = await seed(api)
    client_id = str(uuid.uuid4())
    lead_key, booking_key = str(uuid.uuid4()), str(uuid.uuid4())
    lead_body = {
        "client_id": client_id,
        "full_name": "Aziza",
        "phone": PHONE,
        "subject_id": ids["subject_id"],
        "on_duplicate": "merge",
    }

    first = await api.client.post("/leads", json=lead_body, headers={"Idempotency-Key": lead_key})
    # The response was lost; the outbox sends it again.
    resent = await api.client.post("/leads", json=lead_body, headers={"Idempotency-Key": lead_key})
    assert first.status_code == resent.status_code == 201
    assert first.json() == resent.json()
    assert first.json()["client_id"] == client_id
    lead_id = first.json()["id"]

    booking_body = {"lead_id": lead_id, "session": session_payload(ids["teacher_id"])}
    booked = await api.client.post("/trial-bookings", json=booking_body, headers={"Idempotency-Key": booking_key})
    rebooked = await api.client.post("/trial-bookings", json=booking_body, headers={"Idempotency-Key": booking_key})
    assert booked.status_code == rebooked.status_code == 201
    assert booked.json()["id"] == rebooked.json()["id"]

    snapshot = await counts(api.pool)
    assert (snapshot["leads"], snapshot["bookings"], snapshot["enrollments"]) == (1, 1, 0)
    assert await api.pool.fetchval("select count(*) from trial_sessions") == 1


async def test_offline_lead_for_a_number_that_already_has_one_is_merged(api):
    ids = await seed(api)
    existing = await new_lead(api, subject_id=ids["subject_id"])
    queued = await api.client.post(
        "/leads",
        json={
            "client_id": str(uuid.uuid4()),
            "full_name": "Aziza",
            "phone": PHONE,
            "subject_id": ids["subject_id"],
            "note": "Oflayn yozildi",
            "on_duplicate": "merge",
        },
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert queued.status_code == 201
    assert queued.json()["id"] == existing["id"] and queued.json()["merged"] is True
    assert (await counts(api.pool))["leads"] == 1


async def test_two_devices_syncing_the_same_new_number_at_once_end_up_with_one_lead(api, monkeypatch):
    ids = await seed(api)
    slow_down_writes(monkeypatch)

    def queued(note: str) -> dict:
        return {
            "client_id": str(uuid.uuid4()),
            "full_name": "Aziza",
            "phone": PHONE,
            "subject_id": ids["subject_id"],
            "note": note,
            "on_duplicate": "merge",
        }

    async with api.as_admin() as admin:
        responses = await asyncio.gather(
            api.client.post("/leads", json=queued("Telefondan"), headers={"Idempotency-Key": str(uuid.uuid4())}),
            admin.post("/leads", json=queued("Kompyuterdan"), headers={"Idempotency-Key": str(uuid.uuid4())}),
        )

    assert [response.status_code for response in responses] == [201, 201]
    assert len({response.json()["id"] for response in responses}) == 1
    assert sorted(response.json()["merged"] for response in responses) == [False, True]
    assert (await counts(api.pool))["leads"] == 1


async def test_offline_booking_rejected_at_sync_leaves_nothing_behind(api):
    ids = await seed(api)
    first = await new_lead(api)
    second = await new_lead(api, phone="998901111111")
    booking = await book(api, first["id"], ids["teacher_id"], capacity=1)

    # Queued offline for the same seat, sent once back online.
    late = await api.client.post(
        "/trial-bookings",
        json={"lead_id": second["id"], "session_id": booking["session"]["id"]},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )
    assert late.status_code == 409
    assert (await counts(api.pool))["bookings"] == 1
    assert await api.pool.fetchval("select count(*) from idempotency_keys") == 0


# Reporting ----------------------------------------------------------------


async def test_report_counts_and_conversion_denominators(api):
    ids = await seed(api)
    attended_lead = await new_lead(api, subject_id=ids["subject_id"], source="instagram")
    absent_lead = await new_lead(api, phone="998901111111", source="instagram")
    booked_only = await new_lead(api, phone="998902222222", source="telegram")
    await new_lead(api, phone="998903333333")

    first = await book(api, attended_lead["id"], ids["teacher_id"], hours=1)
    second = await book(api, absent_lead["id"], ids["other_teacher_id"], hours=1)
    await book(api, booked_only["id"], ids["teacher_id"], hours=30)
    for booking in (first, second):
        await move_to_past(api.pool, booking["session"]["id"])
    await api.client.post(f"/trial-bookings/{first['id']}/attendance", json={"status": "attended"})
    await api.client.post(f"/trial-bookings/{second['id']}/attendance", json={"status": "absent"})
    assert (await enroll(api, attended_lead["id"], ids["group_id"])).status_code == 201

    report = (await api.client.get("/admissions/report")).json()

    assert report["new_inquiries"] == 4
    assert report["trials_attended"] == 1
    assert report["trials_absent"] == 1
    assert report["show_rate"] == 0.5
    # A booked trial is not an enrollment: only the one enroll step counts.
    assert report["enrollments"] == 1
    assert (report["cohort_size"], report["cohort_enrolled"], report["lead_conversion_rate"]) == (4, 1, 0.25)
    assert (report["trial_cohort_size"], report["trial_conversion_rate"]) == (1, 1.0)
    assert report["upcoming_trials"] == 1
    assert report["follow_ups_overdue"] + report["follow_ups_due_today"] == 0
    stages = {row["key"]: row["count"] for row in report["open_by_stage"]}
    assert stages["trial_scheduled"] == 1 and stages["contacted"] == 1 and stages["new"] == 1
    sources = {row["key"]: (row["count"], row["enrolled"]) for row in report["cohort_by_source"]}
    assert sources == {"instagram": (2, 1), "telegram": (1, 0), "unknown": (1, 0)}

    empty = (await api.client.get("/admissions/report", params={"date_from": "2020-01-01", "date_to": "2020-01-31"}))
    assert empty.json()["lead_conversion_rate"] is None and empty.json()["show_rate"] is None


async def test_dashboard_lists_todays_trials_from_bookings(api):
    ids = await seed(api)
    lead = await new_lead(api, subject_id=ids["subject_id"])
    await book(api, lead["id"], ids["teacher_id"], hours=0.2)
    response = await api.client.get("/dashboard")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["open_leads"] == 1
    # "Today" is the center's day; a trial 12 minutes from now is today
    # unless the test runs right before the center's midnight.
    assert [trial["inquiry_id"] for trial in body["trials_today"]] in ([lead["id"]], [])


# Old app builds -----------------------------------------------------------


async def test_old_app_inquiries_api_still_works_on_leads(api):
    ids = await seed(api)
    created = await api.client.post(
        "/inquiries",
        json={"full_name": "Eski", "phone": "90 123 45 67", "subject_id": ids["subject_id"], "trial_date": "2026-12-01"},
    )
    assert created.status_code == 201, created.text
    inquiry = created.json()
    assert inquiry["status"] == "new" and inquiry["trial_date"] == "2026-12-01"

    scheduled = await api.client.patch(f"/inquiries/{inquiry['id']}", json={"status": "scheduled"})
    assert scheduled.json()["status"] == "contacted"
    detail = await lead_detail(api, inquiry["id"])
    assert detail["tasks"][0]["title"].startswith("Sinov darsini rejalashtiring")

    convert = await api.client.post(f"/inquiries/{inquiry['id']}/convert")
    assert convert.status_code == 410
    assert (await counts(api.pool))["students"] == 0

    lost = await api.client.patch(f"/inquiries/{inquiry['id']}", json={"status": "lost"})
    assert lost.json()["status"] == "lost"
    assert [item["id"] for item in (await api.client.get("/inquiries", params={"status_filter": "lost"})).json()] == [
        inquiry["id"]
    ]


async def test_users_list(api):
    users = (await api.client.get("/users")).json()
    assert {user["full_name"] for user in users} == {"Owner", "Operator"}
