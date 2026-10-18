"""The bot in a course's group chat: connecting it with the group page's code, who may answer
(Telegram ids held in the CRM), the teacher's homework questions and the group reminders."""

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
CHAT = -1001234567890
TEACHER_PHONE = "998905551111"
TEACHER_TG = 500
ADMIN_TG = 600
OTHER_TG = 700


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
    await w.pool.execute("update teachers set telegram_user_id = $2 where id = $1", w.t1, TEACHER_TG)
    w.owner_phone = await w.pool.fetchval("select phone from users where role = 'owner' limit 1")
    w.admin1_phone = await w.pool.fetchval(
        "select u.phone from users u join user_branches ub on ub.user_id = u.id where ub.branch_id = $1", w.b1
    )
    w.admin1_id = await w.pool.fetchval(
        "select u.id from users u join user_branches ub on ub.user_id = u.id where ub.branch_id = $1", w.b1
    )
    await w.pool.execute("insert into staff_telegram (user_id, telegram_user_id) values ($1, $2)", w.admin1_id, ADMIN_TG)
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


async def connect(bot, world, chat=CHAT, group=None):
    """Connects a chat the way people do: a code from the group's page, then /connect in Telegram."""
    made = await world.owner.post(f"/groups/{group or world.g1}/telegram/code")
    assert made.status_code == 201, made.text
    return await bot.post("/bot/connect", json={"chat_id": chat, "title": "Beginner A", "code": made.json()["code"]})


# --- the group page: a code and the state of the connection ---------------------------------------------------


async def test_the_group_page_hands_out_a_one_time_code_and_a_link(world):
    status_ = (await world.owner.get(f"/groups/{world.g1}/telegram")).json()
    assert status_["connected"] is False and status_["code"] is None
    made = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()
    assert len(made["code"]) == 8 and made["code"].isalnum() and made["code"] == made["code"].upper()
    assert made["link"] == f"https://t.me/Expert_AI_Admin_bot?startgroup={made['code']}"
    assert made["code_expires_at"] is not None and made["connected"] is False
    # a page reload shows the same code; a new one replaces it
    assert (await world.owner.get(f"/groups/{world.g1}/telegram")).json()["code"] == made["code"]
    newer = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()
    assert newer["code"] != made["code"]


async def test_a_branch_admin_manages_only_their_own_groups_telegram_section(world):
    assert (await world.a1.post(f"/groups/{world.g1}/telegram/code")).status_code == 201
    assert (await world.a2.get(f"/groups/{world.g1}/telegram")).status_code == 404
    assert (await world.a2.post(f"/groups/{world.g1}/telegram/code")).status_code == 404
    assert (await world.a2.delete(f"/groups/{world.g1}/telegram")).status_code == 404


async def test_the_code_connects_the_chat_once(world, bot):
    made = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()["code"]
    ok = await bot.post("/bot/connect", json={"chat_id": CHAT, "title": "Beginner A (chat)", "code": made.lower()})  # any case
    assert ok.status_code == 200 and ok.json()["group_name"] == "Beginner A" and ok.json()["teacher_name"] == "Madina"
    page = (await world.owner.get(f"/groups/{world.g1}/telegram")).json()
    assert page["connected"] and page["chat_title"] == "Beginner A (chat)" and page["code"] is None and page["connected_by"]
    assert (await bot.get(f"/bot/group-chat/{CHAT}")).json()["connected"] is True
    # used: it does not work a second time, for this or another chat
    assert (await bot.post("/bot/connect", json={"chat_id": -2, "code": made})).status_code == 400


async def test_a_wrong_expired_or_replaced_code_is_refused(world, bot):
    assert (await bot.post("/bot/connect", json={"chat_id": CHAT, "code": "ZZZZZZZZ"})).status_code == 400
    first = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()["code"]
    second = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()["code"]
    assert (await bot.post("/bot/connect", json={"chat_id": CHAT, "code": first})).status_code == 400
    await world.pool.execute("update telegram_connect_codes set expires_at = now() - interval '1 minute' where code = $1", second)
    assert (await bot.post("/bot/connect", json={"chat_id": CHAT, "code": second})).status_code == 400
    assert await world.pool.fetchval("select count(*) from telegram_groups") == 0


async def test_connecting_again_moves_the_group_to_the_new_chat(world, bot):
    await connect(bot, world, chat=-10)
    await connect(bot, world, chat=-11)
    assert [r["chat_id"] for r in await world.pool.fetch("select chat_id from telegram_groups")] == [-11]
    await connect(bot, world, chat=-11, group=world.g2)  # the same chat, another group
    assert [r["group_id"] for r in await world.pool.fetch("select group_id from telegram_groups")] == [world.g2]


async def test_disconnecting_from_the_group_page_also_voids_the_open_code(world, bot):
    await connect(bot, world)
    code = (await world.owner.post(f"/groups/{world.g1}/telegram/code")).json()["code"]
    page = (await world.owner.delete(f"/groups/{world.g1}/telegram")).json()
    assert page["connected"] is False and page["code"] is None
    assert (await bot.get(f"/bot/group-chat/{CHAT}")).json()["connected"] is False
    assert (await bot.post("/bot/connect", json={"chat_id": CHAT, "code": code})).status_code == 400


# --- Telegram ids in the CRM -----------------------------------------------------------------------------------------


async def test_a_teachers_telegram_id_is_set_changed_and_kept_unique(world):
    t = (await world.a1.patch(f"/teachers/{world.t1}", json={"telegram_user_id": 123})).json()
    assert t["telegram_user_id"] == 123
    other = (await world.a1.post("/teachers", json={"full_name": "Olim Qodirov", "telegram_user_id": 456})).json()
    assert other["telegram_user_id"] == 456
    clash = await world.a1.patch(f"/teachers/{other['id']}", json={"telegram_user_id": 123})
    assert clash.status_code == 409
    clash = await world.a1.post("/teachers", json={"full_name": "Yana Biri", "telegram_user_id": 123})
    assert clash.status_code == 409
    cleared = (await world.a1.patch(f"/teachers/{world.t1}", json={"telegram_user_id": None})).json()
    assert cleared["telegram_user_id"] is None
    assert (await world.a1.get("/teachers")).json()[0].keys() >= {"telegram_user_id"}


async def test_an_admins_telegram_id_is_set_cleared_and_kept_unique(world):
    admin = world.admin2_id
    done = (await world.owner.patch(f"/staff/{admin}", json={"telegram_user_id": 999})).json()
    assert done["telegram_user_id"] == 999
    assert (await world.owner.patch(f"/staff/{world.admin1_id}", json={"telegram_user_id": 999})).status_code == 409
    assert (await world.owner.patch(f"/staff/{admin}", json={"full_name": "Yangi Ism"})).json()["telegram_user_id"] == 999  # untouched
    assert (await world.owner.patch(f"/staff/{admin}", json={"telegram_user_id": None})).json()["telegram_user_id"] is None
    made = await world.owner.post(
        "/staff", json={"phone": "998900000077", "full_name": "Yangi Admin", "password": "secret12", "telegram_user_id": 321}
    )
    assert made.status_code == 201 and made.json()["telegram_user_id"] == 321


async def test_sharing_a_verified_number_fills_in_the_telegram_id(world, bot):
    async def register(tg, phone):
        r = await bot.post("/bot/telegram-id", json={"telegram_user_id": tg, "phone": phone})
        assert r.status_code == 200, r.text
        return r.json()

    assert await register(8001, "+998 90 555 11 11") == {"role": "teacher", "name": "Madina"}
    assert await world.pool.fetchval("select telegram_user_id from teachers where id = $1", world.t1) == 8001
    assert await register(8002, world.admin1_phone) == {"role": "admin", "name": await world.pool.fetchval("select full_name from users where id = $1", world.admin1_id)}
    assert await world.pool.fetchval("select telegram_user_id from staff_telegram where user_id = $1", world.admin1_id) == 8002
    assert (await register(8003, world.owner_phone))["role"] == "owner"
    assert await register(8004, "998900009999") == {"role": None, "name": None}  # nobody
    # the same account moving to another person takes the id with it
    assert (await register(8001, world.admin1_phone))["role"] == "admin"
    assert await world.pool.fetchval("select telegram_user_id from teachers where id = $1", world.t1) is None


# --- who may answer ------------------------------------------------------------------------------------------------


async def pending(bot):
    r = await bot.get("/bot/feedback/pending")
    assert r.status_code == 200, r.text
    return r.json()


async def answer(bot, world, enrollment, homework="good", who=TEACHER_TG, chat=CHAT, owner=False, lesson=None):
    """The teacher (by default) taps an answer; [who] is the Telegram user id, [owner] the bot's OWNER_IDS claim."""
    lesson = lesson or await world.pool.fetchval("select id from lessons order by id desc limit 1")
    return await bot.post(
        "/bot/feedback/answer",
        json={
            "chat_id": chat, "lesson_id": lesson, "enrollment_id": enrollment, "homework": homework,
            "telegram_user_id": who, "is_owner": owner, "name": "Telegram Name",
        },
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


async def test_only_the_teacher_the_owner_and_the_branch_admin_can_answer(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    e = round_["question"]["enrollment_id"]
    lesson = round_["lesson_id"]
    # nobody the CRM knows: a student, a stranger, a Telegram admin of the chat with no place in the CRM
    assert (await answer(bot, world, e, who=OTHER_TG, lesson=lesson)).status_code == 403
    assert (await answer(bot, world, e, who=1, lesson=lesson)).status_code == 403
    # the group's teacher, the owner (the bot says so), the admin of this group's branch
    assert (await answer(bot, world, e, who=TEACHER_TG, lesson=lesson)).status_code == 200
    assert (await answer(bot, world, e, who=OTHER_TG, owner=True, lesson=lesson)).status_code == 200
    assert (await answer(bot, world, e, who=ADMIN_TG, lesson=lesson)).status_code == 200
    # an admin of another branch, another group's teacher
    await world.pool.execute("insert into staff_telegram (user_id, telegram_user_id) values ($1, 701)", world.admin2_id)
    await world.pool.execute("update teachers set telegram_user_id = 702 where id = $1", world.t2)
    assert (await answer(bot, world, e, who=701, lesson=lesson)).status_code == 403
    assert (await answer(bot, world, e, who=702, lesson=lesson)).status_code == 403


async def test_the_owner_is_a_claim_only_the_bot_can_make_and_anyone_else_is_still_checked(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    e, lesson = round_["question"]["enrollment_id"], round_["lesson_id"]
    ok = await answer(bot, world, e, who=OTHER_TG, owner=True, lesson=lesson)
    assert ok.status_code == 200
    assert await world.pool.fetchval("select answered_by from lesson_feedback where enrollment_id = $1", e) == "Telegram Name"


async def test_an_inactive_teacher_or_a_substitute_teacher(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    e, lesson = round_["question"]["enrollment_id"], round_["lesson_id"]
    await world.pool.execute("update teachers set is_active = false where id = $1", world.t1)
    assert (await answer(bot, world, e, lesson=lesson)).status_code == 403
    await world.pool.execute("update teachers set is_active = true where id = $1", world.t1)
    # a substitute who teaches this one lesson may answer for it
    await world.pool.execute("update teachers set telegram_user_id = 703 where id = $1", world.t2)
    assert (await answer(bot, world, e, who=703, lesson=lesson)).status_code == 403
    await world.pool.execute("update lessons set teacher_id = $2 where id = $1", lesson, world.t2)
    assert (await answer(bot, world, e, who=703, lesson=lesson)).status_code == 200


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
    for method, path in (("GET", "/bot/feedback/pending"), ("GET", "/bot/group-chat/1"), ("GET", "/bot/group-outbox")):
        assert (await anonymous.request(method, path)).status_code == 401
    assert (await anonymous.post("/bot/connect", json={})).status_code == 401


# --- the student's profile shows it ---------------------------------------------------------------------------------


async def test_the_profile_shows_how_the_homework_goes(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    lesson = round_["lesson_id"]
    aziza = round_["question"]["enrollment_id"]
    botir = (await answer(bot, world, aziza, "great", lesson=lesson)).json()["question"]["enrollment_id"]
    await answer(bot, world, botir, "weak", lesson=lesson)

    profile = (await world.a1.get(f"/students/{world.s1}/profile")).json()
    assert profile["homework"] == {"great": 0, "good": 0, "weak": 1, "bad": 0, "none": 0, "total": 1, "score": 2.0, "recent": ["weak"]}
    assert [(h["group_name"], h["homework"]) for h in profile["homework_marks"]] == [("Beginner A", "weak")]
    assert profile["groups"][0]["homework"]["total"] == 1
    other = (await world.a1.get(f"/students/{world.s1b}/profile")).json()
    assert other["homework"]["great"] == 1 and other["homework"]["score"] == 4.0


async def test_skipped_answers_are_not_counted_and_a_fresh_profile_is_empty(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    await answer(bot, world, round_["question"]["enrollment_id"], "skipped", lesson=round_["lesson_id"])
    profile = (await world.a1.get(f"/students/{world.s1b}/profile")).json()
    assert profile["homework"]["total"] == 0 and profile["homework"]["score"] is None and profile["homework_marks"] == []
    empty = (await world.a1.get(f"/students/{world.s1}/profile")).json()
    assert empty["homework"] == {"great": 0, "good": 0, "weak": 0, "bad": 0, "none": 0, "total": 0, "score": None, "recent": []}


async def test_another_branch_does_not_see_the_homework(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    await answer(bot, world, round_["question"]["enrollment_id"], "good", lesson=round_["lesson_id"])
    assert (await world.a2.get(f"/students/{world.s1b}/profile")).status_code == 404


# --- reminding the teacher about unanswered questions -----------------------------------------------------------------


async def posted_question(bot, world):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    await bot.post(f"/bot/feedback/{round_['lesson_id']}/asked", json={"message_id": 55})
    return round_


async def age_prompt(world, minutes):
    await world.pool.execute("update telegram_prompts set created_at = now() - make_interval(mins => $1)", minutes)


async def test_an_unanswered_question_is_brought_up_once_after_half_an_hour(world, bot):
    round_ = await posted_question(bot, world)
    assert (await bot.get("/bot/feedback/reminders")).json() == []  # too soon
    await age_prompt(world, 45)
    (reminder,) = (await bot.get("/bot/feedback/reminders")).json()
    assert reminder == {"lesson_id": round_["lesson_id"], "chat_id": CHAT, "message_id": 55, "group_name": "Beginner A", "remaining": 2}
    assert (await bot.post(f"/bot/feedback/{round_['lesson_id']}/reminded")).status_code == 204
    assert (await bot.get("/bot/feedback/reminders")).json() == []  # once only


async def test_the_reminder_counts_only_who_is_still_waiting(world, bot):
    round_ = await posted_question(bot, world)
    await answer(bot, world, round_["question"]["enrollment_id"], "good", lesson=round_["lesson_id"])
    await age_prompt(world, 45)
    (reminder,) = (await bot.get("/bot/feedback/reminders")).json()
    assert reminder["remaining"] == 1


async def test_a_finished_or_day_old_question_is_not_reminded(world, bot):
    round_ = await posted_question(bot, world)
    first = round_["question"]["enrollment_id"]
    second = (await answer(bot, world, first, "good", lesson=round_["lesson_id"])).json()["question"]["enrollment_id"]
    await age_prompt(world, 45)
    await answer(bot, world, second, "good", lesson=round_["lesson_id"])  # everyone answered
    assert (await bot.get("/bot/feedback/reminders")).json() == []
    # a question nobody touched for a day is let go
    await world.pool.execute("update telegram_prompts set status = 'asked', reminded_at = null")
    await world.pool.execute("delete from lesson_feedback")
    await age_prompt(world, 60 * 25)
    assert (await bot.get("/bot/feedback/reminders")).json() == []


async def test_a_question_not_yet_posted_is_not_reminded(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    await age_prompt(world, 45)
    assert (await bot.get("/bot/feedback/reminders")).json() == []


# --- the student's own homework view ---------------------------------------------------------------------------------


async def test_a_linked_student_sees_their_homework_in_me_and_the_week_summary(world, bot):
    await connect(bot, world)
    await run_job(world, ending_soon())
    (round_,) = await pending(bot)
    aziza = round_["question"]["enrollment_id"]
    botir = (await answer(bot, world, aziza, "great", lesson=round_["lesson_id"])).json()["question"]["enrollment_id"]
    await answer(bot, world, botir, "weak", lesson=round_["lesson_id"])
    await bot.post("/bot/link", json={"chat_id": 555, "phone": "998901110001"})
    me = (await bot.get("/bot/me/555")).json()
    assert me["homework"]["weak"] == 1 and me["homework"]["total"] == 1 and me["homework"]["score"] == 2.0
    assert [(h["group_name"], h["homework"]) for h in me["homework"]["recent"]] == [("Beginner A", "weak")]
    # a student with no answers has an empty block
    await bot.post("/bot/link", json={"chat_id": 556, "phone": "998901110002"})
    assert (await bot.get("/bot/me/556")).json()["homework"] == {
        "great": 0, "good": 0, "weak": 0, "bad": 0, "none": 0, "total": 0, "score": None, "recent": [],
    }


async def test_the_sunday_message_carries_the_weeks_homework_average(world, bot):
    import json

    today = date.today()
    sunday = today - timedelta(days=(today.isoweekday() % 7))
    now = datetime.combine(sunday, time(19), tzinfo=TZ)
    e = await world.enrollment(world.s1, world.g1)
    for days_ago, rating in ((1, "great"), (2, "weak"), (3, "skipped")):
        start = now - timedelta(days=days_ago)
        lesson = await world.pool.fetchval(
            "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id",
            world.g1, start, start + timedelta(hours=1),
        )
        await world.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, 'present')", lesson, e)
        await world.pool.execute("insert into lesson_feedback (lesson_id, enrollment_id, homework) values ($1, $2, $3)", lesson, e, rating)
    await bot.post("/bot/link", json={"chat_id": 555, "phone": "998901110001"})
    await run_job(world, now)
    (weekly,) = [r for r in await world.pool.fetch("select * from telegram_outbox where kind = 'weekly'")]
    data = weekly["payload"] if isinstance(weekly["payload"], dict) else json.loads(weekly["payload"])
    assert data["homework_total"] == 2 and data["homework_score"] == 3.0  # (4 + 2) / 2; the skipped one is not counted
    assert data["attended"] == 3


async def test_a_week_without_homework_answers_has_no_homework_line(world, bot):
    import json

    today = date.today()
    sunday = today - timedelta(days=(today.isoweekday() % 7))
    now = datetime.combine(sunday, time(19), tzinfo=TZ)
    e = await world.enrollment(world.s1, world.g1)
    start = now - timedelta(days=1)
    lesson = await world.pool.fetchval(
        "insert into lessons (group_id, starts_at, ends_at) values ($1, $2, $3) returning id", world.g1, start, start + timedelta(hours=1)
    )
    await world.pool.execute("insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, 'present')", lesson, e)
    await bot.post("/bot/link", json={"chat_id": 555, "phone": "998901110001"})
    await run_job(world, now)
    (weekly,) = [r for r in await world.pool.fetch("select * from telegram_outbox where kind = 'weekly'")]
    data = weekly["payload"] if isinstance(weekly["payload"], dict) else json.loads(weekly["payload"])
    assert "homework_total" not in data


# --- one general reminder for the whole group ------------------------------------------------------------------------


async def due_in(world, student, group, days):
    await world.pool.execute(
        "update charges set period_start = $1, due_date = $1, period_end = $1::date + 30 where enrollment_id = $2",
        date.today() + timedelta(days=days), await world.enrollment(student, group),
    )


async def outbox_rows(world):
    return await world.pool.fetch("select * from telegram_group_outbox order by id")


async def test_a_payment_due_tomorrow_gets_one_general_reminder_in_the_group_without_names_or_amounts(world, bot):
    await connect(bot, world)
    await due_in(world, world.s1, world.g1, 1)
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    (row,) = await outbox_rows(world)
    assert row["kind"] == "payment_soon" and row["chat_id"] == CHAT
    data = json.loads(row["payload"]) if isinstance(row["payload"], str) else row["payload"]
    assert data == {"group_name": "Beginner A", "when": "tomorrow", "due_date": str(date.today() + timedelta(days=1))}
    assert "Botir" not in str(data) and "300000" not in str(data)
    # told once, however often the job runs
    await run_job(world, datetime.combine(date.today(), time(10, 30), tzinfo=TZ))
    assert len(await outbox_rows(world)) == 1
    # and again on the day itself
    await due_in(world, world.s1, world.g1, 0)
    await run_job(world, datetime.combine(date.today(), time(11), tzinfo=TZ))
    assert [json.loads(r["payload"])["when"] if isinstance(r["payload"], str) else r["payload"]["when"] for r in await outbox_rows(world)] == ["tomorrow", "today"]


async def test_students_told_privately_do_not_make_the_group_reminder(world, bot):
    await connect(bot, world)
    await due_in(world, world.s1, world.g1, 1)
    await bot.post("/bot/link", json={"chat_id": 555, "phone": "998901110001"})
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    assert await outbox_rows(world) == []
    # one more student in the group who has not started the bot: now the group is reminded
    await due_in(world, world.s1b, world.g1, 1)
    await run_job(world, datetime.combine(date.today(), time(10, 5), tzinfo=TZ))
    assert len(await outbox_rows(world)) == 1


async def test_no_reminder_for_a_paid_charge_an_unconnected_group_or_at_night(world, bot):
    await due_in(world, world.s1, world.g1, 1)
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    assert await outbox_rows(world) == []  # not connected
    await connect(bot, world)
    await run_job(world, datetime.combine(date.today(), time(23), tzinfo=TZ))
    assert await outbox_rows(world) == []  # night
    await due_in(world, world.s1, world.g1, 5)
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    assert await outbox_rows(world) == []  # not due yet


async def test_the_bot_fetches_group_messages_and_reports_them(world, bot):
    await connect(bot, world)
    await due_in(world, world.s1, world.g1, 1)
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    (item,) = (await bot.get("/bot/group-outbox")).json()
    assert item["kind"] == "payment_soon" and item["chat_id"] == CHAT and item["payload"]["group_name"] == "Beginner A"
    # a failure is tried again, three times in all
    for attempt in (1, 2):
        await bot.post(f"/bot/group-outbox/{item['id']}/result", json={"status": "failed", "error": "boom"})
        assert len((await bot.get("/bot/group-outbox")).json()) == 1, attempt
    await bot.post(f"/bot/group-outbox/{item['id']}/result", json={"status": "failed", "error": "boom"})
    assert (await bot.get("/bot/group-outbox")).json() == []
    assert (await outbox_rows(world))[0]["status"] == "failed"
    assert (await bot.post("/bot/group-outbox/9999/result", json={"status": "sent"})).status_code == 404


async def test_a_sent_group_message_is_not_offered_again(world, bot):
    await connect(bot, world)
    await due_in(world, world.s1, world.g1, 1)
    await run_job(world, datetime.combine(date.today(), time(10), tzinfo=TZ))
    (item,) = (await bot.get("/bot/group-outbox")).json()
    assert (await bot.post(f"/bot/group-outbox/{item['id']}/result", json={"status": "sent"})).status_code == 204
    assert (await bot.get("/bot/group-outbox")).json() == []
