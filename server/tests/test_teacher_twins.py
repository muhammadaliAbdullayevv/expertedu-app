"""One person is one teacher: twins are refused, the same person is joined to
another branch, and the owner can fold a duplicate into the real record."""

import pytest

from test_branches import World, client_for

pytestmark = pytest.mark.anyio


@pytest.fixture
async def world(api):
    w = await World().build(api)
    yield w
    await w.close()


async def branches_of(world, teacher_id):
    rows = (await world.owner.get("/teachers")).json()
    return sorted(next(t for t in rows if t["id"] == teacher_id)["branch_names"])


async def test_a_number_or_a_name_that_exists_is_refused_with_where(world):
    await world.a1.patch(f"/teachers/{world.t1}", json={"phone": "+998 90 111 22 33"})
    # The same number in another branch.
    twin = await world.a2.post("/teachers", json={"full_name": "Boshqa ism", "phone": "901112233"})
    assert twin.status_code == 409 and "Bosh ofis" in twin.json()["detail"]
    # The same name in the same branch.
    same_name = await world.a1.post("/teachers", json={"full_name": " madina "})
    assert same_name.status_code == 409 and "shu ismli" in same_name.json()["detail"]
    # The same name in ANOTHER branch is allowed here (the lookup warns instead).
    assert (await world.a2.post("/teachers", json={"full_name": "Madina"})).status_code == 201
    # Changing a number onto someone else's is refused too.
    clash = await world.a2.patch(f"/teachers/{world.t2}", json={"phone": "901112233"})
    assert clash.status_code == 409


async def test_the_lookup_shows_who_this_might_be_in_any_branch(world):
    await world.a1.patch(f"/teachers/{world.t1}", json={"phone": "901112233"})
    by_phone = (await world.a2.get("/teachers/lookup", params={"phone": "+998 90 111 22 33"})).json()
    assert [(m["teacher_id"], m["branch_names"], m["in_scope"], m["same_phone"]) for m in by_phone] == [
        (world.t1, ["Bosh ofis"], False, True)
    ]
    by_name = (await world.a2.get("/teachers/lookup", params={"name": "MADINA"})).json()
    assert [(m["teacher_id"], m["same_phone"]) for m in by_name] == [(world.t1, False)]
    # Their own branch's teacher is marked as already theirs.
    mine = (await world.a1.get("/teachers/lookup", params={"name": "Madina"})).json()
    assert mine[0]["in_scope"] is True
    assert (await world.a1.get("/teachers/lookup")).json() == []


async def test_joining_another_branch_needs_the_number_unless_owner(world):
    await world.a1.patch(f"/teachers/{world.t1}", json={"phone": "901112233"})
    assert (await world.a2.post(f"/teachers/{world.t1}/join-branch", json={"phone": "909999999"})).status_code == 404
    assert (await world.a2.post(f"/teachers/{world.t1}/join-branch", json={})).status_code == 404
    joined = await world.a2.post(f"/teachers/{world.t1}/join-branch", json={"phone": "+998 90 111 22 33"})
    assert joined.status_code == 200
    # An admin sees only their own branch's side of it.
    assert joined.json()["branch_names"] == ["Chilonzor"]
    assert await branches_of(world, world.t1) == ["Bosh ofis", "Chilonzor"]
    # Now they can head a group in the second branch.
    # The owner, looking at one branch, needs no number.
    at_hq = client_for(world.api.owner_id, "owner", branch=1)
    assert (await at_hq.post(f"/teachers/{world.t2}/join-branch", json={})).status_code == 200
    assert await branches_of(world, world.t2) == ["Bosh ofis", "Chilonzor"]
    await at_hq.aclose()


async def test_a_typed_teacher_name_never_makes_a_teacher(world):
    count = await world.pool.fetchval("select count(*) from teachers")
    r = await world.a1.post(
        "/groups",
        json={"subject_id": world.subject, "name": "Yangi", "teacher_name": "Yo'q Odam", "fee_amount": 1, "billing_day": 1},
    )
    assert r.status_code == 400 and "topilmadi" in r.json()["detail"]
    assert await world.pool.fetchval("select count(*) from teachers") == count
    ok = await world.a1.post(
        "/groups",
        json={"subject_id": world.subject, "name": "Yangi", "teacher_name": "madina", "fee_amount": 1, "billing_day": 1},
    )
    assert ok.status_code == 201 and ok.json()["teacher_id"] == world.t1


async def test_the_owner_folds_a_duplicate_into_the_real_teacher(world):
    # Same person made twice, one per branch, each with a group.
    merged = await world.owner.post(f"/teachers/{world.t2}/merge", json={"into_id": world.t1})
    assert merged.status_code == 200, merged.text
    assert sorted(merged.json()["branch_names"]) == ["Bosh ofis", "Chilonzor"]
    # Both groups are now taught by the one record; the duplicate is off but kept.
    teachers = await world.pool.fetch("select id, is_active, note from teachers where id in ($1, $2)", world.t1, world.t2)
    assert {t["id"]: t["is_active"] for t in teachers} == {world.t1: True, world.t2: False}
    assert "Birlashtirildi" in next(t["note"] for t in teachers if t["id"] == world.t2)
    assert await world.pool.fetchval("select teacher_id from groups where id = $1", world.g2) == world.t1
    assert await world.pool.fetchval("select count(*) from teacher_branches where teacher_id = $1", world.t2) == 0
    # Only the owner, never into itself.
    assert (await world.a1.post(f"/teachers/{world.t1}/merge", json={"into_id": world.t2})).status_code == 403
    assert (await world.owner.post(f"/teachers/{world.t1}/merge", json={"into_id": world.t1})).status_code == 400


async def test_a_merge_is_refused_when_they_would_teach_at_the_same_hour(world):
    slot = {"slots": [{"weekday": 2, "starts_at": "10:00", "ends_at": "11:00"}]}
    assert (await world.a1.put(f"/groups/{world.g1}/schedule", json=slot)).status_code in (200, 204)
    assert (await world.a2.put(f"/groups/{world.g2}/schedule", json=slot)).status_code in (200, 204)
    refused = await world.owner.post(f"/teachers/{world.t2}/merge", json={"into_id": world.t1})
    assert refused.status_code == 409
    assert await world.pool.fetchval("select teacher_id from groups where id = $1", world.g2) == world.t2
