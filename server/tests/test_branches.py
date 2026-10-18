"""Branches (docs/BRANCHES.md): an admin sees only their own branch -- never
another's students, groups, money, leads or lessons, by list or by id -- while
the owner sees all of them or one at a time, and a student who is in two
branches shares only their identity."""

from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

from app.deps import get_scope
from app.main import app
from app.security import create_access_token

pytestmark = pytest.mark.anyio

FIRST = date.today().replace(day=1)


def client_for(user_id: int, role: str = "admin", branch: int | None = None) -> httpx.AsyncClient:
    token = create_access_token(user_id=user_id, role=role, token_version=0)
    headers = {"Authorization": f"Bearer {token}"}
    if branch is not None:
        headers["X-Branch"] = str(branch)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test", headers=headers)


class World:
    """Bosh ofis (branch 1) with admin A1, and Chilonzor (branch 2) with admin A2;
    each has a teacher, a group and a student of its own."""

    async def build(self, api):
        self.api, self.pool = api, api.pool
        self.owner = api.client
        self.b1 = 1
        self.b2 = (await self.owner.post("/branches", json={"name": "Chilonzor"})).json()["id"]
        staff = await self.owner.post(
            "/staff",
            json={"phone": "998900000099", "full_name": "Chilonzor admini", "password": "secret12", "branch_id": self.b2},
        )
        assert staff.status_code == 201, staff.text
        self.admin2_id = staff.json()["id"]
        self.a1 = api.as_admin()
        self.a2 = client_for(self.admin2_id)
        self.subject = (await self.owner.post("/subjects", json={"name": "Ingliz tili"})).json()["id"]
        self.t1 = (await self.a1.post("/teachers", json={"full_name": "Madina"})).json()["id"]
        self.t2 = (await self.a2.post("/teachers", json={"full_name": "Jasur"})).json()["id"]
        self.g1 = await self.group(self.a1, "Beginner A", self.t1, 300000)
        self.g2 = await self.group(self.a2, "Beginner B", self.t2, 200000)
        self.s1 = await self.student(self.a1, "Botir Aliyev", "998901110001", self.g1)
        self.s2 = await self.student(self.a2, "Dilnoza Ergasheva", "998901110002", self.g2)
        return self

    async def group(self, client, name, teacher, fee):
        r = await client.post(
            "/groups",
            json={"subject_id": self.subject, "name": name, "teacher_id": teacher, "fee_amount": fee, "billing_day": 1},
        )
        assert r.status_code == 201, r.text
        return r.json()["id"]

    async def student(self, client, name, phone, group):
        r = await client.post(
            "/students/with-enrollment",
            json={"full_name": name, "phone": phone, "group_id": group, "joined_at": str(FIRST)},
        )
        assert r.status_code == 201, r.text
        return r.json()["student"]["id"]

    async def enrollment(self, student, group):
        return await self.pool.fetchval(
            "select id from enrollments where student_id = $1 and group_id = $2 order by id desc limit 1", student, group
        )

    async def close(self):
        await self.a1.aclose()
        await self.a2.aclose()


@pytest.fixture
async def world(api):
    w = await World().build(api)
    yield w
    await w.close()


def ids(rows, key="id"):
    return sorted(r[key] for r in rows)


# --- accounts, branches and the owner's view ------------------------------------------------------


async def test_an_admin_belongs_to_one_branch_and_me_says_which(world):
    me = (await world.a2.get("/me")).json()
    assert (me["branch_id"], me["branch_name"]) == (world.b2, "Chilonzor")
    owner = (await world.owner.get("/me")).json()
    assert owner["branch_id"] is None


async def test_only_the_owner_manages_branches_and_the_headquarters_stays(world):
    assert (await world.a1.post("/branches", json={"name": "Yunusobod"})).status_code == 403
    assert (await world.a1.patch(f"/branches/{world.b2}", json={"name": "X"})).status_code == 403
    assert (await world.owner.post("/branches", json={"name": "Chilonzor"})).status_code == 409
    assert (await world.owner.patch("/branches/1", json={"is_active": False})).status_code == 400
    renamed = await world.owner.patch(f"/branches/{world.b2}", json={"name": "Chilonzor filiali"})
    assert renamed.json()["name"] == "Chilonzor filiali"
    # An admin lists only their own branch; the owner lists all.
    assert [b["id"] for b in (await world.a2.get("/branches")).json()] == [world.b2]
    assert len((await world.owner.get("/branches")).json()) == 2


async def test_an_admin_without_a_branch_is_refused(world):
    await world.pool.execute("delete from user_branches where user_id = $1", world.admin2_id)
    assert (await world.a2.get("/groups")).status_code == 403


async def test_the_owner_sees_everything_or_one_branch_and_an_admin_cannot_choose(world):
    assert ids((await world.owner.get("/groups")).json()) == sorted([world.g1, world.g2])
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    assert ids((await only2.get("/groups")).json()) == [world.g2]
    assert ids((await only2.get("/students")).json()) == [world.s2]
    # An admin's X-Branch header is ignored: A2 stays in Chilonzor.
    cheat = client_for(world.admin2_id, branch=world.b1)
    assert ids((await cheat.get("/groups")).json()) == [world.g2]
    # An unknown branch is a 404 for the owner.
    assert (await client_for(world.api.owner_id, "owner", branch=999).get("/groups")).status_code == 404
    for c in (only2, cheat):
        await c.aclose()


async def test_every_route_is_inside_a_branch_scope(world):
    """No endpoint (other than login, health and the branch list) can run
    without the scope: get_scope is in its dependency chain."""
    open_paths = {"/health", "/auth/login", "/me", "/me/revoke-sessions", "/branches", "/branches/{branch_id}", "/docs",
                  "/openapi.json", "/docs/oauth2-redirect", "/redoc"}
    missing = []
    for route in app.routes:
        dependant = getattr(route, "dependant", None)
        if dependant is None or route.path in open_paths or route.path.startswith("/uploads"):
            continue

        def uses_scope(dep) -> bool:
            return dep.call is get_scope or any(uses_scope(d) for d in dep.dependencies)

        if not uses_scope(dependant):
            missing.append(route.path)
    assert missing == []


# --- groups ----------------------------------------------------------------------------------------


async def test_an_admin_sees_only_their_branchs_groups_by_list_and_by_id(world):
    assert ids((await world.a1.get("/groups")).json()) == [world.g1]
    assert ids((await world.a2.get("/groups")).json()) == [world.g2]
    for path in (f"/groups/{world.g1}", f"/groups/{world.g1}/profile", f"/groups/{world.g1}/roster",
                 f"/groups/{world.g1}/schedule", f"/groups/{world.g1}/trial-dates"):
        assert (await world.a2.get(path)).status_code == 404, path
    assert (await world.a2.patch(f"/groups/{world.g1}", json={"name": "Hack"})).status_code == 404
    assert (await world.a2.put(f"/groups/{world.g1}/schedule", json={"slots": []})).status_code == 404
    assert (await world.pool.fetchval("select name from groups where id = $1", world.g1)) == "Beginner A"


async def test_a_new_group_lands_in_the_creators_branch_and_needs_that_branchs_teacher(world):
    row = await world.pool.fetchrow("select branch_id from groups where id = $1", world.g2)
    assert row["branch_id"] == world.b2
    # Chilonzor cannot use Bosh ofis's teacher.
    r = await world.a2.post(
        "/groups", json={"subject_id": world.subject, "name": "Yangi", "teacher_id": world.t1, "fee_amount": 1, "billing_day": 1}
    )
    assert r.status_code == 404
    # The owner, looking at one branch, creates there.
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    made = await only2.post("/groups", json={"subject_id": world.subject, "name": "Owner guruh", "fee_amount": 1, "billing_day": 1})
    assert made.json()["branch_id"] == world.b2 and made.json()["branch_name"] == "Chilonzor"
    await only2.aclose()


async def test_the_course_finder_and_course_list_follow_the_branch(world):
    found = (await world.a2.get("/groups/search")).json()
    assert [g["group_id"] for g in found["exact"]] == [world.g2]
    owner = (await world.owner.get("/groups/search")).json()
    assert {g["branch_name"] for g in owner["exact"]} == {"Bosh ofis", "Chilonzor"}
    subjects = {s["id"]: s["group_count"] for s in (await world.a2.get("/subjects")).json()}
    assert subjects[world.subject] == 1  # the course is shared; the count is the branch's
    assert ids((await world.a2.get(f"/subjects/{world.subject}/groups")).json()) == [world.g2]


# --- students and the shared identity -----------------------------------------------------------------


async def test_an_admin_sees_only_their_branchs_students_by_list_and_by_id(world):
    assert ids((await world.a1.get("/students")).json()) == [world.s1]
    assert ids((await world.a2.get("/students")).json()) == [world.s2]
    for path in (f"/students/{world.s1}", f"/students/{world.s1}/profile"):
        assert (await world.a2.get(path)).status_code == 404, path
    assert (await world.a2.patch(f"/students/{world.s1}", json={"address": "x"})).status_code == 404
    day = {"group_id": world.g2, "joined_at": str(date.today())}
    assert (await world.a2.post(f"/students/{world.s1}/add-to-group", json=day)).status_code == 404
    assert (await world.a2.post(f"/students/{world.s1}/archive", json={"note": "x"})).status_code == 404
    assert (await world.a2.post(f"/students/{world.s1}/remove-from-group", json={"group_id": world.g1, "note": "x"})).status_code == 404
    assert (await world.a2.get(f"/enrollments/by-student/{world.s1}")).status_code == 404 or \
        (await world.a2.get(f"/enrollments/by-student/{world.s1}")).json() == []


async def test_a_phone_that_belongs_to_another_branch_says_which_and_blocks_a_duplicate(world):
    check = (await world.a2.get("/students/phone-check", params={"phone": "998901110001"})).json()["owner"]
    assert check["student_id"] == world.s1 and check["in_scope"] is False
    assert check["branch_names"] == ["Bosh ofis"]
    # No groups of the other branch are shown.
    assert check["group_names"] == []
    dup = await world.a2.post("/students", json={"full_name": "Botir", "phone": "998901110001"})
    assert dup.status_code == 409 and "Bosh ofis" in dup.json()["detail"]
    # Same branch: the usual warning, with groups.
    same = (await world.a1.get("/students/phone-check", params={"phone": "998901110001"})).json()["owner"]
    assert same["in_scope"] is True and same["group_names"] == ["Beginner A"]


async def test_joining_a_branch_shares_only_the_identity(world):
    a2 = world.a2
    # The number must match: an id alone is not enough.
    assert (await a2.post(f"/students/{world.s1}/join-branch", json={"phone": "998901110009"})).status_code == 404
    joined = await a2.post(f"/students/{world.s1}/join-branch", json={"phone": "998901110001"})
    assert joined.status_code == 200, joined.text
    # Now Chilonzor sees him -- once, with the shared details...
    rows = (await a2.get("/students")).json()
    assert ids(rows) == sorted([world.s1, world.s2])
    mine = (await a2.get(f"/students/{world.s1}/profile")).json()
    assert mine["student"]["full_name"] == "Botir Aliyev"
    # ...but nothing of Bosh ofis: no groups, payments, balance, events.
    assert (mine["groups"], mine["payments"], mine["events"], mine["balance"]) == ([], [], [], 0)
    # He can be added to a Chilonzor group, with Chilonzor's price.
    added = await a2.post(f"/students/{world.s1}/add-to-group", json={"group_id": world.g2, "joined_at": str(FIRST)})
    assert added.status_code == 201, added.text
    assert added.json()["first_charge"] == 200000
    # And Bosh ofis still shows only its own group for him.
    hq = (await world.a1.get(f"/students/{world.s1}/profile")).json()
    assert [g["group_name"] for g in hq["groups"]] == ["Beginner A"]
    # Editing the shared details changes them everywhere.
    await a2.patch(f"/students/{world.s1}", json={"address": "Chilonzor 9"})
    assert (await world.a1.get(f"/students/{world.s1}")).json()["address"] == "Chilonzor 9"


async def test_each_branch_keeps_its_own_note_and_archive(world):
    await world.a2.post(f"/students/{world.s1}/join-branch", json={"phone": "998901110001"})
    await world.a1.patch(f"/students/{world.s1}", json={"note": "Bosh ofis izohi"})
    await world.a2.patch(f"/students/{world.s1}", json={"note": "Chilonzor izohi"})
    assert (await world.a1.get(f"/students/{world.s1}")).json()["note"] == "Bosh ofis izohi"
    assert (await world.a2.get(f"/students/{world.s1}")).json()["note"] == "Chilonzor izohi"
    # Archived in Bosh ofis only.
    assert (await world.a1.post(f"/students/{world.s1}/archive", json={"note": "Ketdi"})).status_code == 200
    hq = {s["id"]: s for s in (await world.a1.get("/students")).json()}
    ch = {s["id"]: s for s in (await world.a2.get("/students")).json()}
    assert hq[world.s1]["is_archived"] is True and ch[world.s1]["is_archived"] is False


# --- money is per branch -------------------------------------------------------------------------------


async def test_a_payment_pays_only_the_branch_it_was_taken_in(world):
    await world.a2.post(f"/students/{world.s1}/join-branch", json={"phone": "998901110001"})
    await world.a2.post(f"/students/{world.s1}/add-to-group", json={"group_id": world.g2, "joined_at": str(FIRST)})
    e1 = await world.enrollment(world.s1, world.g1)
    e2 = await world.enrollment(world.s1, world.g2)
    # He owes 300 000 in Bosh ofis and 200 000 in Chilonzor. Chilonzor takes 200 000.
    paid = await world.a2.post(f"/enrollments/{e2}/payments", json={"amount": 200000, "method": "cash"})
    assert paid.status_code == 201, paid.text
    hq = (await world.a1.get(f"/students/{world.s1}/profile")).json()
    ch = (await world.a2.get(f"/students/{world.s1}/profile")).json()
    assert (hq["balance"], ch["balance"]) == (300000, 0)
    # ...and each group's own debt (what the debtors list shows) agrees: the
    # Chilonzor payment did not pay down the Bosh ofis charge.
    assert [g["balance"] for g in hq["groups"]] == [300000]
    assert [g["balance"] for g in ch["groups"]] == [0]
    assert [d["student_id"] for d in (await world.a1.get("/debtors")).json()] == [world.s1]
    # The owner, looking at everything, sees the sum.
    owner = (await world.owner.get(f"/students/{world.s1}/profile")).json()
    assert owner["balance"] == 300000 and len(owner["groups"]) == 2
    # Chilonzor cannot take money for, or look at, a Bosh ofis enrollment.
    assert (await world.a2.post(f"/enrollments/{e1}/payments", json={"amount": 1, "method": "cash"})).status_code == 404
    assert (await world.a2.get(f"/enrollments/{e1}/transactions")).status_code == 404


async def test_a_payment_cannot_be_cancelled_from_another_branch(world):
    e1 = await world.enrollment(world.s1, world.g1)
    pay = (await world.a1.post(f"/enrollments/{e1}/payments", json={"amount": 100000, "method": "cash"})).json()
    assert (await world.a2.post(f"/payments/{pay['id']}/cancel", json={"reason": "x"})).status_code == 404
    assert (await world.a1.post(f"/payments/{pay['id']}/cancel", json={"reason": "xato"})).status_code == 200


async def test_debtors_and_the_dashboard_are_per_branch(world):
    hq = (await world.a1.get("/debtors")).json()
    ch = (await world.a2.get("/debtors")).json()
    assert [d["student_id"] for d in hq] == [world.s1] and [d["student_id"] for d in ch] == [world.s2]
    assert sorted(d["student_id"] for d in (await world.owner.get("/debtors")).json()) == sorted([world.s1, world.s2])
    dash1 = (await world.a1.get("/dashboard")).json()
    dash2 = (await world.a2.get("/dashboard")).json()
    assert (dash1["total_debt"], dash2["total_debt"]) == (300000, 200000)
    assert (await world.owner.get("/dashboard")).json()["total_debt"] == 500000
    assert (dash1["active_students"], dash2["active_students"]) == (1, 1)
    counts = (await world.a2.get("/counts")).json()
    assert (counts["active_students"], counts["active_groups"], counts["active_teachers"]) == (1, 1, 1)


# --- moving between branches is the owner's -------------------------------------------------------------


async def test_only_the_owner_can_move_a_student_to_another_branchs_group(world):
    # Admin A1 cannot even see Chilonzor's group.
    refused = await world.a1.post(
        f"/students/{world.s1}/transfer", json={"from_group_id": world.g1, "to_group_id": world.g2}
    )
    assert refused.status_code == 404
    moved = await world.owner.post(
        f"/students/{world.s1}/transfer", json={"from_group_id": world.g1, "to_group_id": world.g2, "note": "Ko'chdi"}
    )
    assert moved.status_code == 200, moved.text
    # Chilonzor's own price (200 000), prorated from today.
    assert 0 < moved.json()["first_charge"] <= 200000 and moved.json()["old_debt"] == 300000
    # Each branch's record names only its own group.
    hq = (await world.a1.get(f"/students/{world.s1}/profile")).json()
    ch = (await world.a2.get(f"/students/{world.s1}/profile")).json()
    assert [e["group_name"] for e in hq["events"] if e["kind"] == "removed"] == ["Beginner A"]
    assert "Boshqa filialga" in hq["events"][0]["note"]
    assert [(e["kind"], e["group_name"]) for e in ch["events"]] == [("added", "Beginner B")]
    # He is linked to Chilonzor now, and keeps his Bosh ofis debt there.
    assert hq["balance"] == 300000 and ch["balance"] == moved.json()["first_charge"]


# --- teachers ---------------------------------------------------------------------------------------------


async def test_teachers_are_per_branch_and_the_owner_assigns_them(world):
    assert ids((await world.a1.get("/teachers")).json()) == [world.t1]
    assert ids((await world.a2.get("/teachers")).json()) == [world.t2]
    assert (await world.a2.get(f"/teachers/{world.t1}/profile")).status_code == 404
    assert (await world.a2.patch(f"/teachers/{world.t1}", json={"full_name": "Hack"})).status_code == 404
    assert (await world.a1.put(f"/teachers/{world.t1}/branches", json={"branch_ids": [1, world.b2]})).status_code == 403
    both = await world.owner.put(f"/teachers/{world.t1}/branches", json={"branch_ids": [1, world.b2]})
    assert both.json()["branch_names"] == ["Bosh ofis", "Chilonzor"]
    # Now Chilonzor sees Madina too -- but only as far as Chilonzor.
    assert ids((await world.a2.get("/teachers")).json()) == sorted([world.t1, world.t2])
    seen = (await world.a2.get(f"/teachers/{world.t1}/profile")).json()
    assert seen["groups"] == [] and seen["teacher"]["branch_names"] == ["Chilonzor"]
    # She cannot be taken out of a branch where she still teaches.
    blocked = await world.owner.put(f"/teachers/{world.t1}/branches", json={"branch_ids": [world.b2]})
    assert blocked.status_code == 409 and "Bosh ofis" in blocked.json()["detail"]
    assert (await world.owner.put(f"/teachers/{world.t1}/branches", json={"branch_ids": []})).status_code == 400


async def test_a_teachers_page_follows_the_branch_in_view(world):
    await world.owner.put(f"/teachers/{world.t1}/branches", json={"branch_ids": [1, world.b2]})
    g3 = await world.group(world.a2, "Kechki guruh", world.t1, 100000)
    full = (await world.owner.get(f"/teachers/{world.t1}/profile")).json()
    assert sorted(g["name"] for g in full["groups"]) == ["Beginner A", "Kechki guruh"]
    assert {g["branch_name"] for g in full["groups"]} == {"Bosh ofis", "Chilonzor"}
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    one = (await only2.get(f"/teachers/{world.t1}/profile")).json()
    assert [g["group_id"] for g in one["groups"]] == [g3]
    await only2.aclose()


# --- timetable and attendance ------------------------------------------------------------------------------


async def test_lessons_and_attendance_stay_in_their_branch(world):
    for g, tid in ((world.g1, world.a1), (world.g2, world.a2)):
        await tid.put(f"/groups/{g}/schedule", json={"slots": [
            {"weekday": d, "starts_at": "09:00", "ends_at": "10:00"} for d in (1, 2, 3, 4, 5, 6, 7)
        ]})
    today = date.today().isoformat()
    t1 = (await world.a1.get("/timetable", params={"date_from": today, "date_to": today})).json()
    t2 = (await world.a2.get("/timetable", params={"date_from": today, "date_to": today})).json()
    assert [l["group_id"] for l in t1] == [world.g1] and [l["group_id"] for l in t2] == [world.g2]
    both = (await world.owner.get("/timetable", params={"date_from": today, "date_to": today})).json()
    assert sorted(l["group_id"] for l in both) == sorted([world.g1, world.g2])
    start = t1[0]["starts_at"]
    assert (await world.a2.get("/lessons/sheet", params={"group_id": world.g1, "starts_at": start})).status_code == 404
    assert (await world.a2.post("/lessons/cancel", json={"group_id": world.g1, "starts_at": start})).status_code == 404
    assert (await world.a2.get("/attendance/report", params={"date_from": today, "date_to": today})).json() == []


# --- qabul -------------------------------------------------------------------------------------------------


async def test_leads_are_per_branch_and_the_same_person_can_ask_at_two(world):
    a = (await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"})).json()
    b = (await world.a2.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"}))
    assert b.status_code == 201, b.text  # a different branch: not a duplicate
    b = b.json()
    assert ids((await world.a1.get("/leads")).json()["items"]) == [a["id"]]
    assert ids((await world.a2.get("/leads")).json()["items"]) == [b["id"]]
    for path in (f"/leads/{a['id']}",):
        assert (await world.a2.get(path)).status_code == 404
    assert (await world.a2.patch(f"/leads/{a['id']}", json={"note": "x", "version": a["version"]})).status_code == 404
    assert (await world.a2.post(f"/leads/{a['id']}/stage", json={"stage": "contacted", "version": a["version"]})).status_code == 404
    assert (await world.a2.post(f"/leads/{a['id']}/interactions", json={"kind": "note", "body": "x"})).status_code == 404
    # Within a branch a second open lead for the same person is still refused.
    again = await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"})
    assert again.status_code == 409
    # Counts and the Qabul board follow the branch.
    assert (await world.a2.get("/counts")).json()["open_leads"] == 1
    assert (await world.owner.get("/counts")).json()["open_leads"] == 2
    board = (await world.a2.get("/admissions/board")).json()
    assert sum(c["count"] for c in board["columns"] if c["key"] == "new") == 1
    assert (await world.a2.get("/admissions/report")).json()["new_inquiries"] == 1
    # The legacy inquiries API is scoped too.
    assert [i["id"] for i in (await world.a2.get("/inquiries")).json()] == [b["id"]]
    lookup = (await world.a2.get("/leads/lookup", params={"phone": "998907770001"})).json()
    assert [l["id"] for l in lookup["leads"]] == [b["id"]]
    dup = (await world.a2.get("/leads/duplicates", params={"phone": "998907770001"})).json()
    assert [l["id"] for l in dup["phone_leads"]] == [b["id"]]


async def test_a_lead_is_enrolled_into_its_own_branch_only(world):
    a = (await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"})).json()
    key = {"Idempotency-Key": "3f1c1f6e-5c11-4f4e-9d0e-5a1b3a0f0001"}
    body = {"full_name": "Aziza", "phone": "998907770001", "group_id": world.g2, "joined_at": str(FIRST)}
    # Chilonzor cannot enroll a Bosh ofis lead...
    assert (await world.a2.post(f"/leads/{a['id']}/enroll", json=body, headers=key)).status_code == 404
    # ...nor Bosh ofis into Chilonzor's group.
    key2 = {"Idempotency-Key": "3f1c1f6e-5c11-4f4e-9d0e-5a1b3a0f0002"}
    assert (await world.a1.post(f"/leads/{a['id']}/enroll", json=body, headers=key2)).status_code == 404
    ok = {**body, "group_id": world.g1}
    key3 = {"Idempotency-Key": "3f1c1f6e-5c11-4f4e-9d0e-5a1b3a0f0003"}
    done = await world.a1.post(f"/leads/{a['id']}/enroll", json=ok, headers=key3)
    assert done.status_code == 201, done.text
    new_student = done.json()["student"]["id"]
    assert new_student in ids((await world.a1.get("/students")).json())
    assert new_student not in ids((await world.a2.get("/students")).json())


async def test_trials_and_follow_ups_stay_in_their_branch(world):
    lead = (await world.a1.post("/leads", json={"full_name": "Aziza", "phone": "998907770001"})).json()
    start = (datetime.now(timezone.utc) + timedelta(days=2)).replace(microsecond=0)
    session = {"kind": "dedicated", "teacher_id": world.t1, "room": "1", "starts_at": start.isoformat(),
               "ends_at": (start + timedelta(hours=1)).isoformat(), "capacity": 3}
    booking = await world.a1.post("/trial-bookings", json={"lead_id": lead["id"], "session": session})
    assert booking.status_code == 201, booking.text
    session_id = booking.json()["session"]["id"]
    today = date.today()
    window = {"date_from": str(today), "date_to": str(today + timedelta(days=5))}
    assert [s["id"] for s in (await world.a1.get("/trial-sessions", params=window)).json()] == [session_id]
    assert (await world.a2.get("/trial-sessions", params=window)).json() == []
    assert (await world.a2.post(f"/trial-sessions/{session_id}/cancel", json={})).status_code == 404
    assert (await world.a2.post(f"/trial-bookings/{booking.json()['id']}/cancel", json={})).status_code == 404
    # A Chilonzor lead cannot be booked into a Bosh ofis session, nor use its teacher.
    mine = (await world.a2.post("/leads", json={"full_name": "Zilola", "phone": "998907770002"})).json()
    cross = await world.a2.post("/trial-bookings", json={"lead_id": mine["id"], "session_id": session_id})
    assert cross.status_code == 404
    bad_teacher = await world.a2.post("/trial-bookings", json={"lead_id": mine["id"], "session": {**session, "room": "2"}})
    assert bad_teacher.status_code == 404
    # Follow-up tasks follow their lead's branch.
    task = await world.a1.post("/follow-up-tasks", json={"lead_id": lead["id"], "title": "Qo'ng'iroq", "due_at": (start).isoformat()})
    assert task.status_code == 201, task.text
    assert (await world.a2.get("/follow-up-tasks")).json() == []
    assert (await world.a2.post(f"/follow-up-tasks/{task.json()['id']}/complete", json={})).status_code == 404


# --- owner-only money, per branch ---------------------------------------------------------------------------


async def test_finance_is_filtered_by_the_branch_in_view(world):
    today = date.today().isoformat()
    e1 = await world.enrollment(world.s1, world.g1)
    e2 = await world.enrollment(world.s2, world.g2)
    await world.a1.post(f"/enrollments/{e1}/payments", json={"amount": 300000, "method": "cash"})
    await world.a2.post(f"/enrollments/{e2}/payments", json={"amount": 100000, "method": "cash"})
    only1 = client_for(world.api.owner_id, "owner", branch=1)
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    assert (await world.owner.get("/finance/summary")).json()["months"][-1]["income"] == 400000
    assert (await only1.get("/finance/summary")).json()["months"][-1]["income"] == 300000
    assert (await only2.get("/finance/summary")).json()["months"][-1]["income"] == 100000
    # Expenses are recorded in the branch in view.
    spent = await only2.post("/expenses", json={"category": "rent", "amount": 5000, "spent_on": today})
    assert spent.status_code == 201
    assert len((await only2.get("/expenses", params={"date_from": today, "date_to": today})).json()) == 1
    assert (await only1.get("/expenses", params={"date_from": today, "date_to": today})).json() == []
    assert len((await world.owner.get("/expenses", params={"date_from": today, "date_to": today})).json()) == 1
    for c in (only1, only2):
        await c.aclose()


async def test_teacher_pay_is_worked_out_per_branch(world):
    # One teacher, two branches, a percent rule: each branch has its own pay.
    await world.owner.put(f"/teachers/{world.t1}/branches", json={"branch_ids": [1, world.b2]})
    await world.owner.put(f"/finance/teachers/{world.t1}/percent", json={"salary_percent": 40})
    g3 = await world.group(world.a2, "Kechki guruh", world.t1, 100000)
    s3 = await world.student(world.a2, "Zilola Karimova", "998901110003", g3)
    e1 = await world.enrollment(world.s1, world.g1)
    e3 = await world.enrollment(s3, g3)
    await world.a1.post(f"/enrollments/{e1}/payments", json={"amount": 300000, "method": "cash"})
    await world.a2.post(f"/enrollments/{e3}/payments", json={"amount": 100000, "method": "cash"})
    only1 = client_for(world.api.owner_id, "owner", branch=1)
    only2 = client_for(world.api.owner_id, "owner", branch=world.b2)
    total = (await world.owner.get(f"/teachers/{world.t1}/profile")).json()
    one = (await only1.get(f"/teachers/{world.t1}/profile")).json()
    two = (await only2.get(f"/teachers/{world.t1}/profile")).json()
    assert (total["earned"], one["earned"], two["earned"]) == (160000, 120000, 40000)
    # The Finance salary page agrees branch by branch.
    pay = lambda body, t: next(x for x in body["teachers"] if x["teacher_id"] == t)  # noqa: E731
    assert pay((await only2.get("/finance/salaries")).json(), world.t1)["earned"] == 40000
    # A payout is made in, and capped by, the branch in view.
    await world.owner.post("/finance/salaries/close", params={"month": str(date.today())})
    over = await only2.post("/expenses", json={"category": "salary", "amount": 40001, "spent_on": str(date.today()),
                                                "teacher_id": world.t1, "salary_month": str(FIRST), "method": "cash"})
    assert over.status_code == 409
    ok = await only2.post("/expenses", json={"category": "salary", "amount": 40000, "spent_on": str(date.today()),
                                              "teacher_id": world.t1, "salary_month": str(FIRST), "method": "cash"})
    assert ok.status_code == 201, ok.text
    assert (await only1.get(f"/teachers/{world.t1}/profile")).json()["paid"] == 0
    assert (await only2.get(f"/teachers/{world.t1}/profile")).json()["remaining"] == 0
    for c in (only1, only2):
        await c.aclose()


# --- photos --------------------------------------------------------------------------------------------


PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


async def test_photos_follow_the_branch(world, tmp_path, monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "photos_dir", str(tmp_path / "photos"))
    assert (await world.a2.put(f"/photos/students/{world.s1}", content=PNG)).status_code == 404
    name = (await world.a1.put(f"/photos/students/{world.s1}", content=PNG)).json()["photo"]
    assert (await world.a2.get(f"/photos/file/{name}")).status_code == 404
    assert (await world.a1.get(f"/photos/file/{name}")).status_code == 200
    assert (await world.owner.get(f"/photos/file/{name}")).status_code == 200
    assert (await world.a2.delete(f"/photos/students/{world.s1}")).status_code == 404


# --- staff -----------------------------------------------------------------------------------------------


async def test_the_owner_puts_an_admin_in_a_branch_and_can_move_them(world):
    staff = (await world.owner.get("/staff")).json()
    mine = next(s for s in staff if s["id"] == world.admin2_id)
    assert (mine["branch_id"], mine["branch_name"]) == (world.b2, "Chilonzor")
    moved = await world.owner.patch(f"/staff/{world.admin2_id}", json={"branch_id": 1})
    assert moved.json()["branch_id"] == 1
    assert ids((await world.a2.get("/groups")).json()) == [world.g1]
    assert (await world.owner.patch(f"/staff/{world.admin2_id}", json={"branch_id": 999})).status_code == 404
    # People assignable in Qabul are the branch's admins and the owner.
    names = [u["full_name"] for u in (await world.a1.get("/users")).json()]
    assert "Chilonzor admini" in names  # moved to Bosh ofis
    await world.owner.patch(f"/staff/{world.admin2_id}", json={"branch_id": world.b2})
    names = [u["full_name"] for u in (await world.a1.get("/users")).json()]
    assert "Chilonzor admini" not in names
