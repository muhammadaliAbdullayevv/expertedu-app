"""Printing from Telegram: who may queue a PDF, the print station that takes it, and telling the person how it went."""

import httpx
import pytest

from app.config import settings
from app.main import app
from test_bot_groups import ADMIN_TG, KEY, OTHER_TG, TEACHER_PHONE, TEACHER_TG, bot, world  # noqa: F401  (fixtures)

pytestmark = pytest.mark.anyio

PDF = b"%PDF-1.4\n%fake but enough for the queue\n"


def person(tg, **extra):
    return {"telegram_user_id": tg, **extra}


async def queue(bot, tg=TEACHER_TG, branch=1, chat=77, **extra):
    params = {
        "telegram_user_id": tg, "chat_id": chat, "branch_id": branch, "title": "Book.pdf", "pages": 4, "copies": 2,
        "summary": "1-4", "landscape": "true", **extra,
    }
    return await bot.post("/bot/print", params=params, content=PDF, headers={"Content-Type": "application/pdf"})


# --- who may print ------------------------------------------------------------------------------------------------


async def test_a_teacher_an_admin_and_the_owner_may_print_and_see_their_branches(world, bot):
    teacher = await bot.get("/bot/print/options", params=person(TEACHER_TG))
    assert teacher.status_code == 200, teacher.text
    assert teacher.json()["role"] == "teacher"
    assert [b["id"] for b in teacher.json()["branches"]] == [world.b1]

    admin = (await bot.get("/bot/print/options", params=person(ADMIN_TG))).json()
    assert (admin["role"], [b["id"] for b in admin["branches"]]) == ("admin", [world.b1])

    owner = (await bot.get("/bot/print/options", params=person(999, is_owner="true", name="Ega"))).json()
    assert owner["role"] == "owner"
    assert sorted(b["id"] for b in owner["branches"]) == sorted([world.b1, world.b2])


async def test_a_student_or_a_stranger_may_not_print(world, bot):
    assert (await bot.get("/bot/print/options", params=person(OTHER_TG))).status_code == 403
    assert (await queue(bot, tg=OTHER_TG)).status_code == 403
    assert await world.pool.fetchval("select count(*) from print_jobs") == 0


async def test_a_teacher_known_only_by_a_verified_number_may_print_too(world, bot):
    await world.pool.execute("update teachers set telegram_user_id = null where id = $1", world.t1)
    r = await bot.get("/bot/print/options", params=person(OTHER_TG, verified_phone=TEACHER_PHONE))
    assert r.status_code == 200 and r.json()["via"] == "phone"


async def test_one_may_print_only_in_a_branch_they_belong_to(world, bot):
    assert (await queue(bot, branch=world.b2)).status_code == 403
    assert (await queue(bot, tg=ADMIN_TG, branch=world.b2)).status_code == 403
    assert (await queue(bot, tg=999, is_owner="true", name="Ega", branch=world.b2)).status_code == 201


async def test_only_a_pdf_is_queued(world, bot):
    r = await bot.post("/bot/print", params={"telegram_user_id": TEACHER_TG, "chat_id": 1, "branch_id": 1, "title": "x", "pages": 1},
                       content=b"GIF89a", headers={"Content-Type": "application/pdf"})
    assert r.status_code == 422


# --- the print station ------------------------------------------------------------------------------------------------


async def test_the_station_takes_the_oldest_job_once_and_prints_it(world, bot):
    first = (await queue(bot)).json()
    second = (await queue(bot, copies=1)).json()
    assert (first["ahead"], second["ahead"]) == (0, 1)

    job = await world.a1.post("/print/next", params={"printer": "HP LaserJet"})
    assert job.status_code == 200, job.text
    body = job.json()
    assert (body["id"], body["copies"], body["pages"], body["requested_by"], body["landscape"]) == (first["id"], 2, 4, "Madina", True)
    # The next call gets the second job, not the first again.
    assert (await world.a1.post("/print/next")).json()["id"] == second["id"]
    assert (await world.a1.post("/print/next")).status_code == 204

    pdf = await world.a1.get(f"/print/{first['id']}/file")
    assert pdf.content == PDF and pdf.headers["content-type"] == "application/pdf"

    assert (await world.a1.post(f"/print/{first['id']}/result", json={"ok": True})).status_code == 204
    row = await world.pool.fetchrow("select status, data, printer, finished_at from print_jobs where id = $1", first["id"])
    assert row["status"] == "done" and row["data"] is None and row["printer"] == "HP LaserJet" and row["finished_at"]
    # The file is gone once printed.
    assert (await world.a1.get(f"/print/{first['id']}/file")).status_code == 404


async def test_a_station_only_gets_its_own_branchs_jobs(world, bot):
    job = (await queue(bot)).json()
    assert (await world.a2.post("/print/next")).status_code == 204
    assert (await world.a2.get(f"/print/{job['id']}/file")).status_code == 404
    assert (await world.a2.post(f"/print/{job['id']}/result", json={"ok": True})).status_code == 404
    assert (await world.a2.post(f"/print/{job['id']}/cancel")).status_code == 404
    assert (await world.a1.post("/print/next")).json()["id"] == job["id"]


async def test_the_owners_station_works_for_the_branch_chosen_in_the_header(world, bot):
    job = (await queue(bot, tg=999, is_owner="true", name="Ega", branch=world.b2)).json()
    at_b2 = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test", headers={**world.owner.headers, "X-Branch": str(world.b2)})
    assert (await at_b2.post("/print/next")).json()["id"] == job["id"]
    await at_b2.aclose()


async def test_the_bot_knows_whether_the_printer_pc_is_on(world, bot):
    assert (await queue(bot)).json()["online"] is False
    await world.a1.post("/print/next")
    assert (await queue(bot)).json()["online"] is True
    options = (await bot.get("/bot/print/options", params=person(TEACHER_TG))).json()
    assert options["branches"][0]["online"] is True
    await world.pool.execute("update print_stations set last_seen_at = now() - interval '2 minutes'")
    assert (await queue(bot)).json()["online"] is False


# --- telling the person -------------------------------------------------------------------------------------------


async def test_the_person_is_told_once_how_it_went(world, bot):
    ok = (await queue(bot, chat=11)).json()["id"]
    bad = (await queue(bot, chat=22)).json()["id"]
    await world.a1.post("/print/next")
    await world.a1.post("/print/next")
    await world.a1.post(f"/print/{ok}/result", json={"ok": True})
    await world.a1.post(f"/print/{bad}/result", json={"ok": False, "error": "Qog'oz tugadi"})

    told = {j["id"]: j for j in (await bot.get("/bot/print/finished")).json()}
    assert told[ok]["status"] == "done" and told[ok]["chat_id"] == 11 and told[ok]["pages"] == 4
    assert told[bad]["status"] == "failed" and told[bad]["error"] == "Qog'oz tugadi"
    await bot.post(f"/bot/print/{ok}/notified")
    await bot.post(f"/bot/print/{bad}/notified")
    assert (await bot.get("/bot/print/finished")).json() == []


async def test_a_job_the_printer_pc_never_took_expires(world, bot):
    job = (await queue(bot)).json()["id"]
    await world.pool.execute("update print_jobs set created_at = now() - interval '4 hours' where id = $1", job)
    told = (await bot.get("/bot/print/finished")).json()
    assert [(j["id"], j["status"]) for j in told] == [(job, "expired")]
    assert await world.pool.fetchval("select data from print_jobs where id = $1", job) is None
    assert (await world.a1.post("/print/next")).status_code == 204


async def test_a_job_a_silent_station_took_is_given_up_on(world, bot):
    job = (await queue(bot)).json()["id"]
    await world.a1.post("/print/next")
    await world.pool.execute("update print_jobs set claimed_at = now() - interval '20 minutes' where id = $1", job)
    told = (await bot.get("/bot/print/finished")).json()
    assert [(j["id"], j["status"]) for j in told] == [(job, "failed")]


# --- taking it back ------------------------------------------------------------------------------------------------


async def test_the_sender_can_cancel_until_the_printer_starts(world, bot):
    job = (await queue(bot)).json()["id"]
    assert (await bot.post(f"/bot/print/{job}/cancel", params=person(OTHER_TG))).status_code == 409  # not theirs
    assert (await bot.post(f"/bot/print/{job}/cancel", params=person(TEACHER_TG))).status_code == 204
    assert (await world.a1.post("/print/next")).status_code == 204
    assert (await bot.get("/bot/print/finished")).json() == []  # they did it themselves: no message

    started = (await queue(bot)).json()["id"]
    await world.a1.post("/print/next")
    assert (await bot.post(f"/bot/print/{started}/cancel", params=person(TEACHER_TG))).status_code == 409


async def test_the_station_can_drop_a_waiting_job_and_the_sender_is_told(world, bot):
    job = (await queue(bot)).json()["id"]
    assert (await world.a1.post(f"/print/{job}/cancel")).status_code == 204
    told = (await bot.get("/bot/print/finished")).json()
    assert [(j["id"], j["status"]) for j in told] == [(job, "cancelled")]
    assert (await world.a1.post(f"/print/{job}/cancel")).status_code == 409


async def test_history_shows_who_printed_what_in_the_branch_in_view(world, bot):
    await queue(bot)
    await queue(bot, tg=999, is_owner="true", name="Ega", branch=world.b2)
    mine = (await world.a1.get("/print")).json()
    assert [(j["requested_by"], j["requested_role"], j["title"]) for j in mine] == [("Madina", "teacher", "Book.pdf")]
    assert len((await world.owner.get("/print")).json()) == 2


async def test_the_bot_key_is_needed_for_the_bots_side(world, monkeypatch):
    monkeypatch.setattr(settings, "bot_api_key", KEY)
    anon = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")
    assert (await anon.get("/bot/print/options", params=person(TEACHER_TG))).status_code == 401
    assert (await anon.get("/bot/print/finished")).status_code == 401
    await anon.aclose()
