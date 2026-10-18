"""Staff accounts: only the owner manages them; switching an account off or
resetting its password signs it out everywhere."""

import pytest

pytestmark = pytest.mark.anyio


async def _login(api, phone: str, password: str):
    return await api.client.post("/auth/login", json={"phone": phone, "password": password})


async def test_owner_adds_an_admin_who_can_sign_in(api):
    created = await api.client.post(
        "/staff", json={"phone": "+998 91 000 00 01", "full_name": " Nodira ", "password": "secret1"}
    )
    assert created.status_code == 201, created.text
    member = created.json()
    assert (member["phone"], member["full_name"], member["role"]) == ("998910000001", "Nodira", "admin")
    assert member["last_login_at"] is None

    login = await _login(api, "910000001", "secret1")
    assert login.status_code == 200
    assert login.json()["role"] == "admin"
    listed = {row["full_name"]: row for row in (await api.client.get("/staff")).json()}
    assert listed["Nodira"]["last_login_at"] is not None
    # The owner is listed first.
    assert (await api.client.get("/staff")).json()[0]["role"] == "owner"


async def test_staff_validation(api):
    short = await api.client.post("/staff", json={"phone": "910000002", "full_name": "A", "password": "123"})
    assert short.status_code == 400
    bad_phone = await api.client.post("/staff", json={"phone": "123", "full_name": "A", "password": "secret1"})
    assert bad_phone.status_code == 400
    taken = await api.client.post(
        "/staff", json={"phone": "998900000002", "full_name": "A", "password": "secret1"}
    )
    assert taken.status_code == 409


async def test_admins_cannot_manage_staff(api):
    async with api.as_admin() as admin:
        assert (await admin.get("/staff")).status_code == 403
        assert (
            await admin.post("/staff", json={"phone": "910000003", "full_name": "X", "password": "secret1"})
        ).status_code == 403
        assert (await admin.post(f"/staff/{api.owner_id}/password", json={"password": "hacked1"})).status_code == 403


async def test_switching_an_admin_off_signs_them_out(api):
    async with api.as_admin() as admin:
        assert (await admin.get("/me")).status_code == 200
        off = await api.client.patch(f"/staff/{api.admin_id}", json={"is_active": False})
        assert off.status_code == 200 and off.json()["is_active"] is False
        assert (await admin.get("/me")).status_code == 401
    # Off accounts aren't offered for assigning leads either.
    assert {user["id"] for user in (await api.client.get("/users")).json()} == {api.owner_id}


async def test_password_reset_signs_out_and_takes_the_new_password(api):
    await api.pool.execute(
        "update users set password_hash = $2, failed_login_attempts = 5, locked_until = now() + interval '1 hour' "
        "where id = $1",
        api.admin_id,
        "x",
    )
    async with api.as_admin() as admin:
        reset = await api.client.post(f"/staff/{api.admin_id}/password", json={"password": "newpass1"})
        assert reset.status_code == 200
        assert (await admin.get("/me")).status_code == 401
    # The lockout is cleared too.
    assert (await _login(api, "900000002", "newpass1")).status_code == 200


async def test_the_owner_account_is_protected(api):
    off = await api.client.patch(f"/staff/{api.owner_id}", json={"is_active": False})
    assert off.status_code == 400
    renamed = await api.client.patch(f"/staff/{api.owner_id}", json={"full_name": "Egasi"})
    assert renamed.status_code == 200 and renamed.json()["full_name"] == "Egasi"


# --- a branch and its admin, managed together by the owner ------------------------------------------


async def test_a_branch_is_made_together_with_its_admin(api):
    made = await api.client.post(
        "/branches",
        json={"name": "Yunusobod", "admin_full_name": "Hilola", "admin_phone": "+998 93 111 22 33", "admin_password": "secret1"},
    )
    assert made.status_code == 201, made.text
    branch_id = made.json()["id"]
    admin = next(s for s in (await api.client.get("/staff")).json() if s["full_name"] == "Hilola")
    assert (admin["role"], admin["branch_id"], admin["phone"]) == ("admin", branch_id, "998931112233")
    login = await _login(api, "931112233", "secret1")
    assert login.status_code == 200


async def test_a_branch_needs_all_admin_fields_or_none_and_leaves_nothing_behind(api):
    half = await api.client.post("/branches", json={"name": "Yarim", "admin_full_name": "Hilola"})
    assert half.status_code == 400
    # The admin's number is taken: the branch is not created either.
    taken = await api.client.post(
        "/branches",
        json={"name": "Band", "admin_full_name": "X", "admin_phone": "998900000002", "admin_password": "secret1"},
    )
    assert taken.status_code == 409
    weak = await api.client.post(
        "/branches",
        json={"name": "Zaif", "admin_full_name": "X", "admin_phone": "931112244", "admin_password": "123"},
    )
    assert weak.status_code == 400
    names = {b["name"] for b in (await api.client.get("/branches")).json()}
    assert names.isdisjoint({"Yarim", "Band", "Zaif"})
    bare = await api.client.post("/branches", json={"name": "Adminsiz"})
    assert bare.status_code == 201


async def test_the_owner_changes_an_admins_phone_and_the_old_login_stops(api):
    async with api.as_admin() as admin:
        assert (await admin.get("/me")).status_code == 200
        moved = await api.client.patch(f"/staff/{api.admin_id}", json={"phone": "+998 94 555 66 77"})
        assert moved.status_code == 200 and moved.json()["phone"] == "998945556677"
        assert (await admin.get("/me")).status_code == 401  # signed out of the old session
    await api.client.post(f"/staff/{api.admin_id}/password", json={"password": "secret1"})
    assert (await _login(api, "945556677", "secret1")).status_code == 200
    assert (await _login(api, "900000002", "secret1")).status_code == 401
    assert (await api.client.patch(f"/staff/{api.admin_id}", json={"phone": "998900000001"})).status_code == 409
    assert (await api.client.patch(f"/staff/{api.admin_id}", json={"phone": "123"})).status_code == 400
    assert (await api.client.patch(f"/staff/{api.owner_id}", json={"phone": "931112255"})).status_code == 400


async def test_the_owner_signs_an_admin_out_of_every_device(api):
    async with api.as_admin() as admin:
        assert (await admin.get("/me")).status_code == 200
        out = await api.client.post(f"/staff/{api.admin_id}/sign-out")
        assert out.status_code == 200 and out.json()["is_active"] is True
        assert (await admin.get("/me")).status_code == 401
        assert (await admin.post(f"/staff/{api.admin_id}/sign-out")).status_code in (401, 403)
    assert (await api.client.post(f"/staff/{api.owner_id}/sign-out")).status_code == 400
