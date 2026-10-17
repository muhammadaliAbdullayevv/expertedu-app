"""Profile photos for teachers and students: only real small pictures, one
file per person, behind login, and shown wherever the person is."""

import httpx
import pytest

from app.config import settings
from app.main import app
from test_students import School

pytestmark = pytest.mark.anyio

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
JPG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
WEBP = b"RIFF\x10\x00\x00\x00WEBP" + b"\x00" * 16


@pytest.fixture(autouse=True)
def photo_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "photos_dir", str(tmp_path / "photos"))
    return tmp_path / "photos"


async def put(api, group, owner_id, data, **kw):
    return await api.client.put(f"/photos/{group}/{owner_id}", content=data, **kw)


async def test_a_teacher_gets_a_photo_and_it_is_served_back(api, photo_dir):
    school = await School(api).build()
    r = await put(api, "teachers", school.t1, PNG)
    assert r.status_code == 200, r.text
    name = r.json()["photo"]
    assert name.startswith(f"teacher-{school.t1}-") and name.endswith(".png")
    assert (photo_dir / name).read_bytes() == PNG
    listed = (await api.client.get("/teachers")).json()
    assert {t["id"]: t["photo"] for t in listed}[school.t1] == name
    got = await api.client.get(f"/photos/file/{name}")
    assert got.status_code == 200 and got.content == PNG


async def test_a_student_photo_shows_in_the_list_the_profile_and_the_roster(api):
    school = await School(api).build()
    sid = await school.student()
    await school.join(sid, school.g1)
    name = (await put(api, "students", sid, JPG)).json()["photo"]
    assert name.endswith(".jpg")
    in_list = [s for s in (await api.client.get("/students")).json() if s["id"] == sid][0]
    assert in_list["photo"] == name
    assert (await school.profile(sid))["student"]["photo"] == name
    roster = (await api.client.get(f"/groups/{school.g1}/roster")).json()
    assert roster[0]["student_photo"] == name


async def test_the_group_profile_teacher_carries_the_photo(api):
    school = await School(api).build()
    name = (await put(api, "teachers", school.t1, WEBP)).json()["photo"]
    p = (await api.client.get(f"/groups/{school.g1}/profile")).json()
    assert p["teacher"]["photo"] == name


async def test_a_new_photo_replaces_the_old_file(api, photo_dir):
    school = await School(api).build()
    first = (await put(api, "teachers", school.t1, PNG)).json()["photo"]
    second = (await put(api, "teachers", school.t1, JPG)).json()["photo"]
    assert first != second
    assert sorted(p.name for p in photo_dir.iterdir()) == [second]
    assert (await api.client.get(f"/photos/file/{first}")).status_code == 404


async def test_removing_the_photo_clears_it_and_deletes_the_file(api, photo_dir):
    school = await School(api).build()
    await put(api, "teachers", school.t1, PNG)
    r = await api.client.delete(f"/photos/teachers/{school.t1}")
    assert r.status_code == 200 and r.json() == {"photo": None}
    assert list(photo_dir.iterdir()) == []
    listed = (await api.client.get("/teachers")).json()
    assert {t["id"]: t["photo"] for t in listed}[school.t1] is None


async def test_only_small_real_pictures_are_accepted(api, photo_dir):
    school = await School(api).build()
    assert (await put(api, "teachers", school.t1, b"<html>not a picture</html>")).status_code == 400
    assert (await put(api, "teachers", school.t1, b"")).status_code == 400
    assert (await put(api, "teachers", school.t1, PNG + b"0" * (2 * 1024 * 1024))).status_code == 413
    assert (await put(api, "teachers", 9999, PNG)).status_code == 404
    assert (await put(api, "groups", school.g1, PNG)).status_code == 404
    assert not photo_dir.exists() or list(photo_dir.iterdir()) == []


async def test_photos_need_a_login_and_cannot_reach_other_files(api, photo_dir):
    school = await School(api).build()
    name = (await put(api, "teachers", school.t1, PNG)).json()["photo"]
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as anonymous:
        assert (await anonymous.get(f"/photos/file/{name}")).status_code == 401
    secret = photo_dir.parent / "secret.txt"
    secret.write_text("x")
    assert (await api.client.get("/photos/file/..%2Fsecret.txt")).status_code == 404
    assert (await api.client.get("/photos/file/teacher-1-nothing.png")).status_code == 404
