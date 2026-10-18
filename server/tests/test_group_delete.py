"""Deleting a group: only one that never had anything happen in it. The owner
and the admin of its branch may; a group with history stays."""

from datetime import datetime, timedelta, timezone

import pytest

from test_branches import World

pytestmark = pytest.mark.anyio


@pytest.fixture
async def world(api):
    w = await World().build(api)
    yield w
    await w.close()


async def test_an_empty_group_is_deleted_with_its_schedule_by_its_admin_or_the_owner(world):
    empty = await world.group(world.a1, "Xato guruh", world.t1, 100000)
    await world.a1.put(f"/groups/{empty}/schedule", json={"slots": [{"weekday": 2, "starts_at": "10:00", "ends_at": "11:00"}]})
    lead = (await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001", "group_id": empty})).json()
    assert (await world.a1.delete(f"/groups/{empty}")).status_code == 204
    assert (await world.a1.get(f"/groups/{empty}")).status_code == 404
    assert await world.pool.fetchval("select count(*) from group_schedules where group_id = $1", empty) == 0
    # The request that was offered it is still there, just without a group.
    assert await world.pool.fetchval("select group_id from leads where id = $1", lead["id"]) is None
    other = await world.group(world.a2, "Boshqa xato", world.t2, 100000)
    assert (await world.owner.delete(f"/groups/{other}")).status_code == 204


async def test_a_group_with_students_lessons_or_history_cannot_be_deleted(world):
    # g1 has a student.
    refused = await world.a1.delete(f"/groups/{world.g1}")
    assert refused.status_code == 409 and "o'chirib bo'lmaydi" in refused.json()["detail"]
    assert (await world.a1.get(f"/groups/{world.g1}")).status_code == 200
    # Even after the student left, the money and history stay.
    await world.pool.execute("update enrollments set status = 'withdrawn' where group_id = $1", world.g1)
    assert (await world.a1.delete(f"/groups/{world.g1}")).status_code == 409
    # A group that had only a lesson held.
    lonely = await world.group(world.a1, "Darsli", world.t1, 100000)
    start = datetime.now(timezone.utc)
    await world.pool.execute(
        "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3)", lonely, start, start + timedelta(hours=1)
    )
    assert (await world.a1.delete(f"/groups/{lonely}")).status_code == 409


async def test_another_branchs_group_is_not_found_and_stays(world):
    assert (await world.a1.delete(f"/groups/{world.g2}")).status_code == 404
    assert (await world.a2.get(f"/groups/{world.g2}")).status_code == 200
    assert (await world.a1.delete("/groups/999999")).status_code == 404


async def test_the_same_group_cannot_be_made_twice_by_a_double_click(world):
    again = await world.a1.post(
        "/groups",
        json={"subject_id": world.subject, "name": " beginner a ", "teacher_id": world.t1, "fee_amount": 300000, "billing_day": 1},
    )
    assert again.status_code == 409 and "allaqachon bor" in again.json()["detail"]
    # Another subject, another branch, or an archived group may reuse the name.
    other_branch = await world.group(world.a2, "Beginner A", world.t2, 100000)
    assert other_branch
    await world.pool.execute("update groups set is_active = false where id = $1", world.g1)
    assert (
        await world.a1.post(
            "/groups",
            json={"subject_id": world.subject, "name": "Beginner A", "teacher_id": world.t1, "fee_amount": 1, "billing_day": 1},
        )
    ).status_code == 201
