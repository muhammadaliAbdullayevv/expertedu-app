"""The bot in a course's group chat: connecting it, telling people apart, and the
teacher's homework questions (routes/bot_groups.py)."""

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
CHAT = -1001234567890
TEACHER_PHONE = "998905551111"


@pytest.fixture
async def world(api):
    w = await World().build(api)
    # Madina (group 1's teacher) has a phone; the group meets every day 09:00-10:00.
    await w.pool.execute("update teachers set phone = $2 where id = $1", w.t1, TEACHER_PHONE)
    await w.a1.put(
        f"/groups/{w.g1}/schedule",
        json={"slots": [{"weekday": d, "starts_at": "09:00", "ends_at": "10:00"} for d in range(1, 8)]},
    )
    w.s1b = await w.student(w.a1, "Aziza Karimova", "998901110003", w.g1)
    w.owner_phone = await w.pool.fetchval("select phone from users where role = 'owner' limit 1")
    w.admin1_phone = await w.pool.fetchval(
        "select u.phone from users u join user_branches ub on ub.user_id = u.id where ub.branch_id = $1", w.b1
    )
    yield w
    await w.close()


@pytest.fixture
def bot(monkeypatch):
    monkeypatch.setattr(settings, "bot_api_key", KEY)
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test", headers={"X-Bot-Key": KEY})


def ending_soon() -> datetime:
    """Three minutes before today's 10:00 lesson ends."""
    return datetime.combine(date.today(), time(9, 57), tzinfo=TZ)


async def run_job(world, now: datetime) -> int:
    async with world.pool.acquire() as conn:
        return await telegram_notifier.generate(conn, now)


async def connect(bot, world, chat=CHAT, group=None, phone=None, verified=True):
    return await bot.post(
        "/bot/connect",
        json={"chat_id": chat, "title": "Beginner A", "group_id": group or world.g1, "phone": phone or world.owner_phone, "verified": verified},
    )


# --- connecting a chat --------------------------------------------------------------------------------------


async def test_who_may_connect_which_groups(world, bot):
    async def names(phone, verified=True):
        r = await bot.get("/bot/connectable", params={"phone": phone, "verified": verified})
        return sorted(g["name"] for g in r.json())

    assert await names(world.owner_phone) == ["Beginner A", "Beginner B"]
    assert await names(world.admin1_phone) == ["Beginner A"]
    assert await names(TEACHER_PHONE) == ["Beginner A"]
    assert await names("998900009999") == []
    # A staff login number that was only typed in (not verified by Telegram) gives nothing.
    assert await names(world.owner_phone, verified=False) == []
    assert await names(world.admin1_phone, verified=False) == []
    # ... but a teacher's number counts however it was given.
    assert await names(TEACHER_PHONE, verified=False) == ["Beginner A"]


async def test_connecting_a_chat_and_asking_about_it(world, bot):
    assert (await bot.get(f"/bot/group-chat/{CHAT}")).json() == {
        "connected": False, "group_id": None, "group_name": None, "subject_name": None, "branch_name": None, "teacher_name": None,
    }
    r = await connect(bot, world)
    assert r.status_code == 200 and r.json()["group_name"] == "Beginner A"
    info = (await bot.get(f"/bot/group-chat/{CHAT}")).json()
    assert info["connected"] and info["teacher_name"] == "Madina" and info["subject_name"] == "Ingliz tili"


async def test_only_those_who_manage_the_group_can_connect_it(world, bot):
    assert (await connect(bot, world, phone=TEACHER_PHONE)).status_code == 200
    assert (await connect(bot, world, chat=-2, group=world.g2, phone=TEACHER_PHONE)).status_code == 403  # not their group
    assert (await connect(bot, world, chat=-3, phone=world.owner_phone, verified=False)).status_code == 403
    assert (await connect(bot, world, chat=-4, phone="998900009999")).status_code == 403
    assert (await connect(bot, world, chat=-5, group=999999)).status_code == 404
    assert await world.pool.fetchval("select count(*) from telegram_groups") == 1


async def test_connecting_again_moves_the_group_to_the_new_chat(world, bot):
    await connect(bot, world, chat=-10)
    await connect(bot, world, chat=-11)
    assert [r["chat_id"] for r in await world.pool.fetch("select chat_id from telegram_groups")] == [-11]
    await connect(bot, world, chat=-11, group=world.g2)  # the same chat, another group
    assert [r["group_id"] for r in await world.pool.fetch("select group_id from telegram_groups")] == [world.g2]


async def test_disconnecting(world, bot):
    await connect(bot, world)
    stranger = await bot.delete("/bot/connect", params={"chat_id": CHAT, "phone": "998900009999"})
    assert stranger.status_code == 403
    assert (await bot.delete("/bot/connect", params={"chat_id": CHAT, "phone": TEACHER_PHONE})).status_code == 204
    assert (await bot.get(f"/bot/group-chat/{CHAT}")).json()["connected"] is False


# --- who is this person in the group ----------------------------------------------------------------------------


async def group_link(bot, phone, chat_id=777, group_chat=CHAT):
    r = await bot.post("/bot/link-in-group", json={"chat_id": chat_id, "group_chat_id": group_chat, "phone": phone})
    assert r.status_code == 200, r.text
    return r.json()


async def test_a_registered_number_typed_in_links_a_student_of_that_group(world, bot):
    await connect(bot, world)
    assert await group_link(bot, "+998 90 111 00 01") == {"status": "student", "name": "Botir Aliyev"}
    me = (await bot.get("/bot/me/777")).json()
    assert me["student_name"] == "Botir Aliyev"
    assert await world.pool.fetchval("select method from telegram_links where chat_id = 777") == "group"


async def test_a_number_that_is_not_in_this_group_is_not_accepted(world, bot):
    await connect(bot, world)
    # a real student, but of the other group
    assert (await group_link(bot, "998901110002"))["status"] == "none"
    assert (await group_link(bot, "998900009999"))["status"] == "none"
    assert (await bot.get("/bot/me/777")).status_code == 404
    # a student who left this group
    await world.pool.execute("update enrollments set status = 'withdrawn', ended_at = current_date where id = $1", await world.enrollment(world.s1, world.g1))
    assert (await group_link(bot, "998901110001"))["status"] == "none"


async def test_the_groups_teacher_is_told_apart_and_another_groups_teacher_is_not(world, bot):
    await connect(bot, world)
    assert await group_link(bot, TEACHER_PHONE) == {"status": "teacher", "name": "Madina"}
    other = await world.pool.fetchval("update teachers set phone = '998905552222' where id = $1 returning phone", world.t2)
    assert (await group_link(bot, other))["status"] == "none"
    assert (await bot.get("/bot/me/777")).status_code == 404  # a teacher is not linked as a student


async def test_a_chat_that_is_not_connected_accepts_nobody(world, bot):
    assert (await group_link(bot, "998901110001", group_chat=-999))["status"] == "none"


async def test_joining_through_the_group_clears_the_waiting_row(world, bot):
    await connect(bot, world)
    await bot.post("/bot/link", json={"chat_id": 777, "phone": "998907770000"})
    assert await world.pool.fetchval("select count(*) from telegram_pending where chat_id = 777") == 1
    await group_link(bot, "998901110001")
    assert await world.pool.fetchval("select count(*) from telegram_pending where chat_id = 777") == 0


# --- the homework questions ---------------------------------------------------------------------------------------


async def pending(bot):
    r = await bot.get("/bot/feedback/pending")
    assert r.status_code == 200, r.text
    return r.json()


async def answer(bot, world, enrollment, homework="good", phone=TEACHER_PHONE, chat=CHAT, verified=True, lesson=None):
    lesson = lesson or await world.pool.fetchval("select id from lessons order by id desc limit 1")
    return await bot.post(
        "/bot/feedback/answer",
        json={"chat_id": chat, "lesson_id": lesson, "enrollment_id": enrollment, "homework": homework, "actor_phone": phone, "verified": verified},
    )


async def test_the_question_comes_five_minutes_before_the_lesson_ends(world, bot):
    await connect(bot, world)
    day = date.today()
    assert await run_job(world, datetime.combine(day, time(9, 40), tzinfo=TZ)) == 0
    assert await pending(bot) == []
    assert await run_job(world, datetime.combine(day, time(9, 56), tzinfo=TZ)) == 1
    (round_,) = await pending(bot)
    assert round_["chat_id"] == CHAT and round_["group_name"] == "Beginner A" and round_["subject_name"] == "Ingliz tili"
    assert round_["question"]["student_name"] == "Aziza Karimova"  # alphabetical
    assert (round_["question"]["number"], round_["question"]["total"]) == (1, 2)
    # It is asked once however often the job runs.
    assert await run_job(world, ending_soon()) == 0
    assert await world.pool.fetchval("select count(*) from lessons where group_id = $1", world.g1) == 1


async def test_nothing_is_asked_for_a_cancelled_lesson_a_late_one_or_an_unconnected_group(world, bot):
    day = date.today()
    assert await run_job(world, ending_soon()) == 0  # not connected
    await connect(bot, world)
    assert await run_job(world, datetime.combine(day, time(12, 30), tzinfo=TZ)) == 0  # over two hours ago
    starts = datetime.combine(day, time(9, 0), tzinfo=TZ)
    cancel = await world.a1.post("/lessons/cancel", json={"group_id": world.g1, "starts_at": starts.isoformat(), "reason": "bayram"})
    assert cancel.status_code in (200, 201), cancel.text
    assert await run_job(world, ending_soon()) == 0


async def test_the_teacher_answers_student_by_student_and_it_is_kept(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    lesson = round_["lesson_id"]
    assert (await bot.post(f"/bot/feedback/{lesson}/asked", json={"message_id": 55})).status_code == 204
    assert await pending(bot) == []  # posted: not offered again

    aziza = round_["question"]["enrollment_id"]
    first = (await answer(bot, world, aziza, "great", lesson=lesson)).json()
    assert first["done"] is False and first["question"]["student_name"] == "Botir Aliyev"
    assert (first["answered"], first["total"], first["question"]["number"]) == (1, 2, 2)
    last = (await answer(bot, world, first["question"]["enrollment_id"], "none", lesson=lesson)).json()
    assert last["done"] is True and last["question"] is None
    rows = await world.pool.fetch("select homework, answered_by from lesson_feedback order by id")
    assert [(r["homework"], r["answered_by"]) for r in rows] == [("great", "Madina"), ("none", "Madina")]
    assert await world.pool.fetchval("select status from telegram_prompts") == "done"


async def test_an_answer_can_be_changed_and_a_student_can_be_skipped(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    e = round_["question"]["enrollment_id"]
    await answer(bot, world, e, "weak", lesson=round_["lesson_id"])
    await answer(bot, world, e, "good", lesson=round_["lesson_id"])
    assert await world.pool.fetchval("select homework from lesson_feedback where enrollment_id = $1", e) == "good"
    other = (await answer(bot, world, e, "good", lesson=round_["lesson_id"])).json()["question"]["enrollment_id"]
    done = (await answer(bot, world, other, "skipped", lesson=round_["lesson_id"])).json()
    assert done["done"] is True


async def test_students_marked_absent_or_excused_are_not_asked_about(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    lesson = await world.pool.fetchval("select id from lessons")
    for student, status in ((world.s1, "absent"),):
        await world.pool.execute(
            "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3)",
            lesson, await world.enrollment(student, world.g1), status,
        )
    (round_,) = await pending(bot)
    assert (round_["question"]["student_name"], round_["question"]["total"]) == ("Aziza Karimova", 1)
    done = (await answer(bot, world, round_["question"]["enrollment_id"], "good", lesson=lesson)).json()
    assert done["done"] is True


async def test_a_round_with_nobody_to_ask_is_dropped(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    lesson = await world.pool.fetchval("select id from lessons")
    for student in (world.s1, world.s1b):
        await world.pool.execute(
            "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, 'excused')",
            lesson, await world.enrollment(student, world.g1),
        )
    assert await pending(bot) == []
    assert await world.pool.fetchval("select status from telegram_prompts") == "done"


async def test_only_the_teacher_or_the_right_staff_can_answer(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    e = round_["question"]["enrollment_id"]
    lesson = round_["lesson_id"]
    assert (await answer(bot, world, e, phone="998901110001", lesson=lesson)).status_code == 403  # a student
    assert (await answer(bot, world, e, phone="998900009999", lesson=lesson)).status_code == 403  # a stranger
    assert (await answer(bot, world, e, phone=world.owner_phone, verified=False, lesson=lesson)).status_code == 403  # typed in
    assert (await answer(bot, world, e, phone=world.admin1_phone, verified=False, lesson=lesson)).status_code == 403
    assert (await answer(bot, world, e, phone=world.owner_phone, lesson=lesson)).status_code == 200
    assert (await answer(bot, world, e, phone=world.admin1_phone, lesson=lesson)).status_code == 200
    admin2 = await world.pool.fetchval(
        "select u.phone from users u join user_branches ub on ub.user_id = u.id where ub.branch_id = $1", world.b2
    )
    assert (await answer(bot, world, e, phone=admin2, lesson=lesson)).status_code == 403  # another branch
    # another group's teacher
    await world.pool.execute("update teachers set phone = '998905552222' where id = $1", world.t2)
    assert (await answer(bot, world, e, phone="998905552222", lesson=lesson)).status_code == 403
    # a teacher whose number was typed into the join flow may answer
    assert (await answer(bot, world, e, phone=TEACHER_PHONE, verified=False, lesson=lesson)).status_code == 200


async def test_an_answer_for_another_chat_or_another_groups_student_is_refused(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    lesson = round_["lesson_id"]
    assert (await answer(bot, world, round_["question"]["enrollment_id"], chat=-999, lesson=lesson)).status_code == 404
    stranger = await world.enrollment(world.s2, world.g2)
    assert (await answer(bot, world, stranger, lesson=lesson)).status_code == 400
    assert await world.pool.fetchval("select count(*) from lesson_feedback") == 0


async def test_the_new_routes_need_the_bot_key(world, bot):
    anonymous = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")
    for method, path in (("GET", "/bot/feedback/pending"), ("GET", "/bot/group-chat/1"), ("GET", "/bot/connectable?phone=1")):
        assert (await anonymous.request(method, path)).status_code == 401
    assert (await anonymous.post("/bot/connect", json={})).status_code == 401
