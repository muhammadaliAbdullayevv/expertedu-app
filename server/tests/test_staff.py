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
