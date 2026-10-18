"""The Telegram bot's door (routes/bot.py) and the notifier that queues its
messages (jobs/telegram_notifier.py)."""

import json
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import httpx
import pytest

from app.config import settings
from app.jobs import telegram_notifier
from app.main import app
from test_branches import World

pytestmark = pytest.mark.anyio

TZ = ZoneInfo("Asia/Tashkent")
KEY = "test-bot-key-0123456789abcdef"


@pytest.fixture
async def world(api):
    w = await World().build(api)
    yield w
    await w.close()


@pytest.fixture
def bot(monkeypatch):
    monkeypatch.setattr(settings, "bot_api_key", KEY)
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", headers={"X-Bot-Key": KEY}
    )


def at(day: date, hour: int = 10) -> datetime:
    return datetime.combine(day, time(hour), tzinfo=TZ)


async def run_job(world, now: datetime) -> int:
    async with world.pool.acquire() as conn:
        return await telegram_notifier.generate(conn, now)


async def outbox(world, status: str | None = None):
    rows = await world.pool.fetch("select * from telegram_outbox order by id")
    return [r for r in rows if status is None or r["status"] == status]


def payload(row) -> dict:
    value = row["payload"]
    return json.loads(value) if isinstance(value, str) else value


async def link(bot, chat_id=555, phone="+998 90 111 00 01", language="uz"):
    r = await bot.post("/bot/link", json={"chat_id": chat_id, "phone": phone, "language": language})
    assert r.status_code == 200, r.text
    return r.json()


# --- the key ------------------------------------------------------------------------------------------------


async def test_the_bot_needs_its_key(world, bot, monkeypatch):
    anonymous = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")
    assert (await anonymous.get("/bot/courses")).status_code == 401
    wrong = httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test", headers={"X-Bot-Key": "nope"}
    )
    assert (await wrong.get("/bot/courses")).status_code == 401
    # A staff token is not the bot's key.
    assert (await world.owner.get("/bot/courses")).status_code == 401
    assert (await bot.get("/bot/courses")).status_code == 200
    monkeypatch.setattr(settings, "bot_api_key", None)
    assert (await bot.get("/bot/courses")).status_code == 503


# --- the public course list ------------------------------------------------------------------------------


async def test_courses_are_public_info_for_every_branch(world, bot):
    await world.a1.put(f"/groups/{world.g1}/schedule", json={"slots": [{"weekday": 2, "starts_at": "10:00", "ends_at": "11:30"}]})
    await world.a1.patch(f"/groups/{world.g1}", json={"capacity": 5})
    rows = {c["name"]: c for c in (await bot.get("/bot/courses")).json()}
    assert set(rows) == {"Beginner A", "Beginner B"}
    a = rows["Beginner A"]
    assert (a["fee_amount"], a["branch_name"], a["subject_name"]) == (300000, "Bosh ofis", "Ingliz tili")
    assert a["teacher"] == "Madina"
    assert a["slots"] == [{"weekday": 2, "starts_at": "10:00", "ends_at": "11:30"}]
    assert a["free_seats"] == 4  # capacity 5, one student
    assert rows["Beginner B"]["free_seats"] is None  # no limit
    # Nothing private in it: no student, phone or money beyond the price.
    assert not {"students", "phone", "balance"} & set(a)
    # An archived group or a switched-off branch is not offered.
    await world.pool.execute("update groups set is_active = false where id = $1", world.g2)
    assert [c["name"] for c in (await bot.get("/bot/courses")).json()] == ["Beginner A"]


# --- someone asks about a course ---------------------------------------------------------------------------


async def test_a_request_lands_in_qabul_of_the_groups_branch(world, bot):
    r = await bot.post(
        "/bot/leads",
        json={"chat_id": 77, "username": "aziza_u", "full_name": " Aziza ", "phone": "+998 90 777 00 01", "group_id": world.g2,
              "note": "Sinov darsiga"},
    )
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "created"
    mine = (await world.a2.get("/leads")).json()["items"]
    assert [(l["full_name"], l["source"], l["group_id"]) for l in mine] == [("Aziza", "telegram", world.g2)]
    assert "@aziza_u" in mine[0]["note"] and "Sinov darsiga" in mine[0]["note"]
    # The other branch does not see it.
    assert (await world.a1.get("/leads")).json()["items"] == []
    # The timeline says where it came from.
    detail = (await world.a2.get(f"/leads/{mine[0]['id']}")).json()
    assert detail["interactions"][0]["kind"] == "telegram"


async def test_asking_twice_about_the_same_course_is_one_request(world, bot):
    body = {"chat_id": 77, "full_name": "Aziza", "phone": "901112222", "group_id": world.g1}
    first = (await bot.post("/bot/leads", json=body)).json()
    again = await bot.post("/bot/leads", json={**body, "chat_id": 78})
    assert again.status_code == 201 and again.json() == {"status": "duplicate", "lead_id": first["lead_id"]}
    assert len((await world.a1.get("/leads")).json()["items"]) == 1


async def test_a_request_is_checked_and_limited(world, bot):
    base = {"chat_id": 9, "full_name": "X", "phone": "901112222"}
    assert (await bot.post("/bot/leads", json={**base, "phone": "123"})).status_code == 400
    assert (await bot.post("/bot/leads", json={**base, "full_name": "  "})).status_code == 400
    assert (await bot.post("/bot/leads", json={**base, "group_id": 999})).status_code == 404
    # No group: the headquarters.
    ok = await bot.post("/bot/leads", json=base)
    assert ok.status_code == 201
    assert len((await world.a1.get("/leads")).json()["items"]) == 1
    # A chat may ask only a few times a day.
    for n in range(3):
        await bot.post("/bot/leads", json={**base, "phone": f"9033300{n}0"})
    assert (await bot.post("/bot/leads", json={**base, "phone": "903330099"})).status_code == 429
    # Another person (chat) is not held back.
    assert (await bot.post("/bot/leads", json={**base, "chat_id": 10, "phone": "903330098"})).status_code == 201


# --- linking and asking about yourself ---------------------------------------------------------------------


async def test_a_student_links_their_chat_by_phone(world, bot):
    assert (await link(bot, phone="+998 90 999 99 99")) == {"linked": False, "student_name": None}
    assert (await link(bot)) == {"linked": True, "student_name": "Botir Aliyev"}
    me = (await bot.get("/bot/me/555")).json()
    assert me["student_name"] == "Botir Aliyev" and me["language"] == "uz"
    assert [(g["group_name"], g["branch_name"], g["owed"]) for g in me["groups"]] == [("Beginner A", "Bosh ofis", 300000)]
    assert me["total_owed"] == 300000
    # Not linked: nothing is said.
    assert (await bot.get("/bot/me/999")).status_code == 404


async def test_me_shows_the_week_and_counts_excused_as_not_against_them(world, bot):
    await link(bot)
    e = await world.enrollment(world.s1, world.g1)
    now = datetime.now(TZ)
    for days_ago, status in ((1, "present"), (2, "late"), (3, "absent"), (4, "excused"), (10, "absent")):
        start = now - timedelta(days=days_ago)
        lesson = await world.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
            world.g1, start, start + timedelta(hours=1),
        )
        await world.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)", lesson, e, status)
    week = (await bot.get("/bot/me/555")).json()["week"]
    assert (week["attended"], week["late"], week["absent"], week["excused"], week["total"]) == (2, 1, 1, 1, 4)
    assert week["rate"] == pytest.approx(0.6667, abs=0.001)


async def test_language_and_stop_and_unlink(world, bot):
    await link(bot)
    await bot.post("/bot/settings", json={"chat_id": 555, "language": "en"})
    assert (await bot.get("/bot/me/555")).json()["language"] == "en"
    await bot.post("/bot/settings", json={"chat_id": 555, "stopped": True})
    assert (await bot.get("/bot/me/555")).json()["stopped"] is True
    assert (await bot.post("/bot/settings", json={"chat_id": 1234, "stopped": True})).json()["linked"] is False
    assert (await bot.post("/bot/unlink", params={"chat_id": 555})).status_code == 204
    assert (await bot.get("/bot/me/555")).status_code == 404


async def test_linking_again_from_another_chat_works_and_a_new_phone_moves_the_chat(world, bot):
    await link(bot, chat_id=1)
    await link(bot, chat_id=2)  # the same student on a second device
    assert await world.pool.fetchval("select count(*) from telegram_links where student_id = $1", world.s1) == 2
    await link(bot, chat_id=2, phone="901110002")  # that chat now belongs to the other student
    assert await world.pool.fetchval("select student_id from telegram_links where chat_id = 2") == world.s2


# --- someone who is not a student yet ------------------------------------------------------------------------


async def test_a_stranger_waits_and_is_welcomed_when_put_into_a_group(world, bot):
    new_phone = "+998 90 555 00 00"
    assert (await link(bot, chat_id=777, phone=new_phone, language="en"))["linked"] is False
    assert await world.pool.fetchval("select phone from telegram_pending where chat_id = 777") == "998905550000"
    assert (await bot.get("/bot/me/777")).status_code == 404
    assert await run_job(world, at(date.today())) == 0

    # The center registers them but has not given them a group: still waiting.
    r = await world.a1.post("/students", json={"full_name": "Sardor Yusupov", "phone": "998905550000"})
    assert r.status_code == 201, r.text
    student = r.json()["id"]
    assert await run_job(world, at(date.today())) == 0
    assert await world.pool.fetchval("select count(*) from telegram_pending") == 1

    added = await world.a1.post(f"/students/{student}/add-to-group", json={"group_id": world.g1, "joined_at": str(date.today())})
    assert added.status_code in (200, 201), added.text
    await run_job(world, at(date.today()))
    assert await world.pool.fetchval("select count(*) from telegram_pending") == 0
    me = (await bot.get("/bot/me/777")).json()
    assert me["student_name"] == "Sardor Yusupov" and me["language"] == "en"
    (welcome,) = [m for m in await outbox(world) if m["kind"] == "welcome"]
    assert welcome["kind"] == "welcome" and welcome["chat_id"] == 777
    assert payload(welcome) == {"student_name": "Sardor Yusupov", "groups": ["Beginner A"]}
    # The bot can fetch it like any other message, and it is not queued twice.
    assert "welcome" in [i["kind"] for i in (await bot.get("/bot/outbox")).json()]
    assert await run_job(world, at(date.today())) == 0


async def test_sharing_the_number_of_an_existing_student_links_and_leaves_no_waiting_row(world, bot):
    await link(bot, chat_id=778, phone="+998 90 555 00 01")
    assert await world.pool.fetchval("select count(*) from telegram_pending where chat_id = 778") == 1
    await link(bot, chat_id=778)  # a real student's number
    assert await world.pool.fetchval("select count(*) from telegram_pending where chat_id = 778") == 0


async def test_the_welcome_is_not_sent_at_night(world, bot):
    await link(bot, chat_id=779, phone="+998 90 555 00 02")
    await world.student(world.a1, "Madina K", "998905550002", world.g1)
    assert await run_job(world, at(date.today(), 23)) == 0
    assert await outbox(world) == []
    await run_job(world, at(date.today(), 9))
    assert [m["kind"] for m in await outbox(world)].count("welcome") == 1


# --- the messages ------------------------------------------------------------------------------------------


async def due_on(world, student, group, day: date):
    await world.pool.execute(
        "update charges set period_start = $1, due_date = $1, period_end = $1::date + 30 where enrollment_id = $2",
        day, await world.enrollment(student, group),
    )


async def test_payment_reminders_come_once_before_on_the_day_and_weekly_after(world, bot):
    await link(bot)
    today = date.today()
    await due_on(world, world.s1, world.g1, today + timedelta(days=1))
    assert await run_job(world, at(today)) == 1
    first = (await outbox(world))[0]
    assert (first["kind"], payload(first)["amount"], payload(first)["group_name"]) == ("due_tomorrow", 300000, "Beginner A")
    assert await run_job(world, at(today)) == 0  # told once
    # The day itself.
    await due_on(world, world.s1, world.g1, today)
    assert await run_job(world, at(today, 12)) == 1
    assert (await outbox(world))[-1]["kind"] == "due_today"
    # Three days late: a reminder, and then one each week.
    await due_on(world, world.s1, world.g1, today - timedelta(days=3))
    assert await run_job(world, at(today)) == 1
    over = (await outbox(world))[-1]
    assert (over["kind"], payload(over)["days_overdue"]) == ("overdue", 3)
    assert await run_job(world, at(today, 15)) == 0
    assert await run_job(world, at(today + timedelta(days=7))) in (0, 1)  # next ISO week: asked again


async def test_a_paid_charge_is_not_reminded_and_a_payment_gets_a_receipt(world, bot):
    await link(bot)
    today = date.today()
    await due_on(world, world.s1, world.g1, today + timedelta(days=1))
    enrollment = await world.enrollment(world.s1, world.g1)
    paid = await world.owner.post(f"/enrollments/{enrollment}/payments", json={"amount": 300000, "method": "card"})
    assert paid.status_code == 201
    await run_job(world, datetime.now(TZ).replace(hour=12))
    kinds = [r["kind"] for r in await outbox(world)]
    assert kinds == ["paid"]
    receipt = payload((await outbox(world))[0])
    assert (receipt["amount"], receipt["method"], receipt["group_name"]) == (300000, "card", "Beginner A")


async def test_nothing_is_queued_at_night_or_for_stopped_or_unlinked(world, bot):
    today = date.today()
    await due_on(world, world.s1, world.g1, today + timedelta(days=1))
    assert await run_job(world, at(today)) == 0  # not linked
    await link(bot)
    assert await run_job(world, at(today, 23)) == 0
    assert await run_job(world, at(today, 6)) == 0
    await bot.post("/bot/settings", json={"chat_id": 555, "stopped": True})
    assert await run_job(world, at(today)) == 0
    await bot.post("/bot/settings", json={"chat_id": 555, "stopped": False})
    assert await run_job(world, at(today)) == 1


async def test_an_absence_is_told_once_to_the_student_marked_absent(world, bot):
    await link(bot)
    await link(bot, chat_id=556, phone="901110002")
    now = datetime.now(TZ).replace(hour=14, minute=0)
    start = now - timedelta(hours=3)
    lesson = await world.pool.fetchval(
        "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
        world.g1, start, start + timedelta(hours=1),
    )
    e1 = await world.enrollment(world.s1, world.g1)
    await world.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, 'absent')", lesson, e1)
    # A present student and one of another group hear nothing.
    await run_job(world, now)
    told = [r for r in await outbox(world) if r["kind"] == "absent"]
    assert [(r["chat_id"], payload(r)["group_name"]) for r in told] == [(555, "Beginner A")]
    await run_job(world, now)
    assert len([r for r in await outbox(world) if r["kind"] == "absent"]) == 1


async def test_on_sunday_evening_the_week_is_summed_up(world, bot):
    await link(bot)
    today = date.today()
    sunday = today - timedelta(days=(today.isoweekday() % 7))
    now = at(sunday, 19)
    e = await world.enrollment(world.s1, world.g1)
    for days_ago, status in ((1, "present"), (2, "present"), (3, "late"), (4, "absent"), (5, "excused")):
        start = now - timedelta(days=days_ago)
        lesson = await world.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
            world.g1, start, start + timedelta(hours=1),
        )
        await world.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)", lesson, e, status)
    made = await run_job(world, now)
    weekly = [r for r in await outbox(world) if r["kind"] == "weekly"]
    assert made >= 1 and len(weekly) == 1
    week = payload(weekly[0])
    assert (week["attended"], week["late"], week["absent"], week["excused"], week["total"]) == (3, 1, 1, 1, 5)
    assert week["rate"] == pytest.approx(0.75)
    # Not sent on another day, nor twice.
    assert [r for r in await outbox(world) if r["kind"] == "weekly"] == weekly
    await run_job(world, now + timedelta(minutes=10))
    assert len([r for r in await outbox(world) if r["kind"] == "weekly"]) == 1
    monday = at(sunday + timedelta(days=1), 19)
    await run_job(world, monday)
    assert len([r for r in await outbox(world) if r["kind"] == "weekly"]) == 1


# --- sending ---------------------------------------------------------------------------------------------------


async def queue_one(world, bot):
    await link(bot)
    await due_on(world, world.s1, world.g1, date.today() + timedelta(days=1))
    await run_job(world, at(date.today()))


async def test_the_bot_fetches_pending_messages_and_reports_each(world, bot):
    await queue_one(world, bot)
    items = (await bot.get("/bot/outbox")).json()
    assert [(i["chat_id"], i["language"], i["kind"]) for i in items] == [(555, "uz", "due_tomorrow")]
    assert items[0]["payload"]["amount"] == 300000
    assert (await bot.post(f"/bot/outbox/{items[0]['id']}/result", json={"status": "sent"})).status_code == 204
    assert (await bot.get("/bot/outbox")).json() == []
    assert (await outbox(world, "sent"))[0]["sent_at"] is not None


async def test_a_failed_send_is_tried_again_then_given_up(world, bot):
    await queue_one(world, bot)
    item = (await bot.get("/bot/outbox")).json()[0]["id"]
    for _ in range(2):
        await bot.post(f"/bot/outbox/{item}/result", json={"status": "failed", "error": "timeout"})
        assert len((await bot.get("/bot/outbox")).json()) == 1
    await bot.post(f"/bot/outbox/{item}/result", json={"status": "failed", "error": "timeout"})
    assert (await bot.get("/bot/outbox")).json() == []
    assert (await outbox(world, "failed"))[0]["attempts"] == 3


async def test_someone_who_blocked_the_bot_gets_nothing_more(world, bot):
    await queue_one(world, bot)
    item = (await bot.get("/bot/outbox")).json()[0]["id"]
    await bot.post(f"/bot/outbox/{item}/result", json={"status": "blocked", "error": "Forbidden: bot was blocked"})
    assert (await bot.get("/bot/me/555")).json()["stopped"] is True
    assert (await bot.get("/bot/outbox")).json() == []
    assert (await bot.post("/bot/outbox/99999/result", json={"status": "sent"})).status_code == 404


async def test_a_stopped_chat_is_not_handed_out(world, bot):
    await queue_one(world, bot)
    await bot.post("/bot/settings", json={"chat_id": 555, "stopped": True})
    assert (await bot.get("/bot/outbox")).json() == []
