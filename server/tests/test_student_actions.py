"""Archiving a student, removing one from a group, moving one to another group
and putting one back: everything stays on record, each action is written down
with its comment and what he still owed, and the profile says so."""

from datetime import date

import pytest

from test_students import School

pytestmark = pytest.mark.anyio

FIRST = date.today().replace(day=1)


async def post(api, path, **body):
    return await api.client.post(path, json=body)


async def events(school, student_id):
    return (await school.profile(student_id))["events"]


async def two_groups(api):
    """A student in Beginner A (owes 300 000, paid nothing) and Matematika 9
    (paid in full), with some attendance in the first."""
    school = await School(api).build()
    sid = await school.student()
    # Money is allocated to the oldest unpaid charge, so Matematika (the older
    # charge) is the one the payment settles.
    e2 = await school.join(sid, school.g2, FIRST)
    e1 = await school.join(sid, school.g1, FIRST)
    await school.pay(e2, 200000)
    await school.mark(e1, school.g1, ["present", "absent", "present"])
    return school, sid, e1, e2


async def test_archiving_needs_a_comment_and_changes_nothing_without_one(api):
    school, sid, *_ = await two_groups(api)
    assert (await post(api, f"/students/{sid}/archive", note="  ")).status_code == 400
    assert (await post(api, f"/students/{sid}/archive")).status_code == 422
    p = await school.profile(sid)
    assert p["student"]["archived_at"] is None
    assert [g["status"] for g in p["groups"]] == ["active", "active"]


async def test_archiving_takes_him_out_of_every_group_and_keeps_everything(api):
    school, sid, e1, e2 = await two_groups(api)
    before = await school.profile(sid)
    r = await post(api, f"/students/{sid}/archive", note="Ko'chib ketdi")
    assert r.status_code == 200, r.text
    # He still owes the 300 000 of Beginner A.
    assert r.json() == {"debt": 300000}
    p = await school.profile(sid)
    assert p["student"]["archived_at"] is not None
    assert {g["group_name"]: g["status"] for g in p["groups"]} == {"Beginner A": "withdrawn", "Matematika 9": "withdrawn"}
    assert all(g["ended_at"] == str(date.today()) for g in p["groups"])
    # Nothing was lost: payments, attendance and the debt are as they were.
    assert [x["id"] for x in p["payments"]] == [x["id"] for x in before["payments"]]
    assert p["attendance"]["total"] == before["attendance"]["total"] == 3
    assert p["balance"] == 300000
    # One "removed" per group and one "archived", all with his comment.
    by_kind = {}
    for ev in p["events"]:
        by_kind.setdefault(ev["kind"], []).append(ev)
    assert {ev["group_name"] for ev in by_kind["removed"]} == {"Beginner A", "Matematika 9"}
    assert all(ev["note"] == "Ko'chib ketdi" for ev in by_kind["removed"] + by_kind["archived"])
    assert by_kind["archived"][0]["debt"] == 300000
    assert {ev["group_name"]: ev["debt"] for ev in by_kind["removed"]} == {"Beginner A": 300000, "Matematika 9": 0}


async def test_the_list_flags_the_archived_and_cannot_archive_twice(api):
    school, sid, *_ = await two_groups(api)
    other = await school.student(name="Boshqa", phone="998901110002")
    await school.join(other, school.g1)
    await post(api, f"/students/{sid}/archive", note="Ketdi")
    rows = {s["id"]: s for s in (await api.client.get("/students")).json()}
    assert (rows[sid]["is_archived"], rows[sid]["is_active"]) == (True, False)
    assert (rows[other]["is_archived"], rows[other]["is_active"]) == (False, True)
    assert (await post(api, f"/students/{sid}/archive", note="Yana")).status_code == 409
    assert (await post(api, "/students/9999/archive", note="x")).status_code == 404


async def test_unarchiving_brings_him_back_without_any_group(api):
    school, sid, *_ = await two_groups(api)
    assert (await post(api, f"/students/{sid}/unarchive")).status_code == 409  # not archived yet
    await post(api, f"/students/{sid}/archive", note="Ketdi")
    r = await post(api, f"/students/{sid}/unarchive", note="Qaytdi")
    assert r.status_code == 200 and r.json() == {"debt": 300000}
    p = await school.profile(sid)
    assert p["student"]["archived_at"] is None
    # No group is switched back on by itself: they are there, ended, to choose from.
    assert [g["status"] for g in p["groups"]] == ["withdrawn", "withdrawn"]
    assert p["events"][0]["kind"] == "unarchived" and p["events"][0]["note"] == "Qaytdi"
    rows = {s["id"]: s for s in (await api.client.get("/students")).json()}
    assert (rows[sid]["is_archived"], rows[sid]["is_active"]) == (False, False)


async def test_putting_a_group_back_is_activated_and_ends_the_archive(api):
    school, sid, *_ = await two_groups(api)
    await post(api, f"/students/{sid}/archive", note="Ketdi")
    r = await post(api, f"/students/{sid}/add-to-group", group_id=school.g1, joined_at=str(date.today()))
    assert r.status_code == 201, r.text
    p = await school.profile(sid)
    assert p["student"]["archived_at"] is None
    kinds = [ev["kind"] for ev in p["events"]]
    assert "activated" in kinds and kinds[0] in ("activated", "unarchived")
    assert [g["status"] for g in p["groups"]].count("active") == 1
    # A group he was never in is just "added".
    third = await api.pool.fetchval(
        "insert into groups (subject_id, name, fee_amount, billing_day) values ($1, 'Yangi', 100000, 1) returning id",
        school.english,
    )
    await post(api, f"/students/{sid}/add-to-group", group_id=third, joined_at=str(date.today()))
    assert (await events(school, sid))[0]["kind"] == "added"


async def test_removing_from_one_group_needs_a_comment_and_keeps_the_rest(api):
    school, sid, e1, e2 = await two_groups(api)
    assert (await post(api, f"/students/{sid}/remove-from-group", group_id=school.g1, note="")).status_code == 400
    r = await post(api, f"/students/{sid}/remove-from-group", group_id=school.g1, note="Vaqti to'g'ri kelmadi")
    assert r.status_code == 200 and r.json() == {"debt": 300000}
    p = await school.profile(sid)
    assert {g["group_name"]: g["status"] for g in p["groups"]} == {"Beginner A": "withdrawn", "Matematika 9": "active"}
    assert p["student"]["archived_at"] is None
    assert p["attendance"]["total"] == 3  # his lessons are still on record
    ev = p["events"][0]
    assert (ev["kind"], ev["group_name"], ev["note"], ev["debt"]) == ("removed", "Beginner A", "Vaqti to'g'ri kelmadi", 300000)
    # Gone from that group's roster, still on the other's.
    assert (await api.client.get(f"/groups/{school.g1}/roster")).json() == []
    assert len((await api.client.get(f"/groups/{school.g2}/roster")).json()) == 1


async def test_removing_someone_who_paid_everything_reports_no_debt(api):
    school, sid, e1, e2 = await two_groups(api)
    r = await post(api, f"/students/{sid}/remove-from-group", group_id=school.g2, note="Tugatdi")
    assert r.json() == {"debt": 0}
    assert (await events(school, sid))[0]["debt"] == 0


async def test_removing_from_a_group_he_is_not_in_is_refused(api):
    school, sid, *_ = await two_groups(api)
    other = await school.student(name="Boshqa", phone="998901110002")
    assert (await post(api, f"/students/{other}/remove-from-group", group_id=school.g1, note="x")).status_code == 404
    await post(api, f"/students/{sid}/remove-from-group", group_id=school.g1, note="x")
    assert (await post(api, f"/students/{sid}/remove-from-group", group_id=school.g1, note="yana")).status_code == 404


async def test_a_transfer_bills_by_the_new_group_and_remembers_the_old_debt(api):
    school, sid, e1, e2 = await two_groups(api)
    third = await api.pool.fetchval(
        "insert into groups (subject_id, name, teacher_id, fee_amount, billing_day) "
        "values ($1, 'Intensiv', $2, 450000, 1) returning id", school.english, school.t1,
    )
    r = await post(api, f"/students/{sid}/transfer", from_group_id=school.g1, to_group_id=third, note="Kuchliroq daraja")
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["group_name"] == "Intensiv" and out["old_debt"] == 300000
    # Billed by the NEW group's price (prorated from today: never more than 450 000).
    assert 0 < out["first_charge"] <= 450000
    p = await school.profile(sid)
    status = {g["group_name"]: g["status"] for g in p["groups"]}
    assert status == {"Beginner A": "withdrawn", "Matematika 9": "active", "Intensiv": "active"}
    ev = p["events"][0]
    assert (ev["kind"], ev["group_name"], ev["to_group_name"], ev["note"], ev["debt"]) == (
        "transferred", "Beginner A", "Intensiv", "Kuchliroq daraja", 300000)
    # Only one entry for the move (no extra "added").
    assert [e["kind"] for e in p["events"]].count("added") == 2  # the two he joined first
    # Reminded of the old debt...
    assert [(n["from_group_name"], n["to_group_name"], n["debt"]) for n in p["transfer_notices"]] == [
        ("Beginner A", "Intensiv", 300000)]


async def test_the_reminder_ends_with_the_first_payment_on_the_new_group(api):
    school, sid, e1, e2 = await two_groups(api)
    third = await api.pool.fetchval(
        "insert into groups (subject_id, name, fee_amount, billing_day) values ($1, 'Intensiv', 450000, 1) returning id",
        school.english,
    )
    await post(api, f"/students/{sid}/transfer", from_group_id=school.g1, to_group_id=third)
    new_enrollment = await api.pool.fetchval(
        "select id from enrollments where student_id = $1 and group_id = $2", sid, third)
    # A payment on some other group does not end it.
    await school.pay(e2, 1000)
    assert len((await school.profile(sid))["transfer_notices"]) == 1
    await school.pay(new_enrollment, 50000)
    assert (await school.profile(sid))["transfer_notices"] == []


async def test_the_reminder_ends_when_the_old_debt_is_paid(api):
    school, sid, e1, e2 = await two_groups(api)
    third = await api.pool.fetchval(
        "insert into groups (subject_id, name, fee_amount, billing_day) values ($1, 'Intensiv', 450000, 1) returning id",
        school.english,
    )
    await post(api, f"/students/{sid}/transfer", from_group_id=school.g1, to_group_id=third)
    await school.pay(e1, 300000)
    assert (await school.profile(sid))["transfer_notices"] == []


async def test_a_transfer_to_the_same_group_or_from_a_group_he_is_not_in_is_refused(api):
    school, sid, *_ = await two_groups(api)
    other = await school.student(name="Boshqa", phone="998901110002")
    assert (await post(api, f"/students/{sid}/transfer", from_group_id=school.g1, to_group_id=school.g1)).status_code == 400
    assert (await post(api, f"/students/{other}/transfer", from_group_id=school.g1, to_group_id=school.g2)).status_code == 404
    # He is already in the target group.
    assert (await post(api, f"/students/{sid}/transfer", from_group_id=school.g1, to_group_id=school.g2)).status_code == 409
    # Nothing moved.
    assert [g["status"] for g in (await school.profile(sid))["groups"]] == ["active", "active"]


async def test_the_old_withdraw_endpoint_is_written_down_too(api):
    school, sid, e1, e2 = await two_groups(api)
    r = await api.client.post(f"/enrollments/{e1}/withdraw")
    assert r.status_code == 200
    ev = (await events(school, sid))[0]
    assert (ev["kind"], ev["group_name"], ev["debt"]) == ("removed", "Beginner A", 300000)
