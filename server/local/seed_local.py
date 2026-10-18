"""DEV-ONLY: fills the LOCAL database with a complete, believable test center.

Runs only against a database on this computer (127.0.0.1) and refuses anything
else, so it can never touch the real server. Everything goes through the API
wherever it can (so the money rules, charges and audit log are the real ones);
attendance, which has no "mark a past lesson" shortcut, is written directly.

Sign in afterwards: 90 000 00 01 / demo1234 (owner), 90 000 00 02 / demo1234 (admin).
"""

import asyncio
import os
import random
import sys
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

DATABASE_URL = os.environ["DATABASE_URL"]
if "127.0.0.1" not in DATABASE_URL and "localhost" not in DATABASE_URL:
    sys.exit("Refusing to seed a database that is not on this computer.")
os.environ.setdefault("JWT_SECRET", "local")

import asyncpg  # noqa: E402
import httpx  # noqa: E402

from app import clock  # noqa: E402
from app.money import service as money  # noqa: E402
from app.security import hash_password  # noqa: E402

API = os.environ.get("EXPERTEDU_LOCAL_API", "http://127.0.0.1:8765")
PASSWORD = "demo1234"
random.seed(2026)
TODAY = clock.today()

FIRST = ["Botir", "Akmal", "Zilola", "Dilshod", "Sevara", "Otabek", "Malika", "Sardor", "Nigora", "Bekzod",
         "Feruza", "Jahongir", "Madina", "Aziz", "Laylo", "Anvar", "Dilnoza", "Rustam", "Gulnora", "Shaxzod",
         "Kamola", "Davron", "Nodira", "Timur", "Sabina", "Eldor", "Yulduz", "Farhod", "Umida", "Javlon"]
LAST = ["Aliyev", "Nazarov", "Karimov", "Yusupova", "Rahmonov", "Abdullayeva", "Tursunov", "Hasanova", "Ergashev",
        "Qodirova", "Ismoilov", "Saidova", "Sodiqov", "Ibragimov", "Rahimova", "Mirzayev", "Nurmatova", "Soliyev"]


class Api:
    def __init__(self) -> None:
        self.http = httpx.Client(base_url=API, timeout=60)
        self.headers: dict[str, str] = {}

    def login(self, phone: str) -> None:
        r = self.http.post("/auth/login", json={"phone": phone, "password": PASSWORD})
        r.raise_for_status()
        self.headers = {"Authorization": f"Bearer {r.json()['token']}"}

    def call(self, method: str, path: str, ok=(200, 201, 204), **kw):
        r = self.http.request(method, path, headers={**self.headers, **kw.pop("headers", {})}, **kw)
        if r.status_code not in ok:
            raise RuntimeError(f"{method} {path} -> {r.status_code}: {r.text[:300]}")
        return r.json() if r.content else None

    def get(self, path, **kw):
        return self.call("GET", path, **kw)

    def post(self, path, **kw):
        return self.call("POST", path, **kw)

    def put(self, path, **kw):
        return self.call("PUT", path, **kw)


def phone(n: int) -> str:
    return f"99890{n:07d}"


async def create_users() -> None:
    conn = await asyncpg.connect(DATABASE_URL)
    if await conn.fetchval("select count(*) from users") == 0:
        pw = hash_password(PASSWORD)
        await conn.execute(
            "insert into users (phone, password_hash, full_name, role) values "
            "('998900000001', $1, 'Madina Karimova', 'owner'), ('998900000002', $1, 'Admin Ma''mur', 'admin')",
            pw,
        )
    await conn.close()


GROUPS = [
    # name, subject, teacher, level, fee, billing (mode, day, prorate), capacity, days, start, end
    ("Beginner A", "Ingliz tili", "Madina Karimova", "Beginner", 310000, ("fixed_day", 1, True), 16, [1, 3, 5], "09:00", "10:30"),
    ("Intermediate", "Ingliz tili", "Sardor Aliyev", "Intermediate", 390000, ("fixed_day", 15, True), 14, [2, 4, 6], "16:30", "18:00"),
    ("IELTS 6.5", "IELTS", "Aziza Rustamova", "IELTS", 550000, ("fixed_day", 5, False), 12, [1, 3, 5], "18:30", "20:00"),
    ("A1", "Fransuz tili", "Nilufar Ismoilova", "A1", 420000, ("student_anniversary", None, False), 10, [1, 3, 5], "10:30", "12:00"),
    ("9-sinf", "Matematika", "Jasur Rahimov", "9-sinf", 350000, ("fixed_day", 10, True), 15, [2, 4], "15:00", "16:30"),
    ("Fizika 10", "Fizika", "Jahongir Rashidov", "10-sinf", 330000, ("fixed_day", 1, True), 12, [2, 4], "14:00", "15:30"),
    ("Rus tili", "Rus tili", "Olga Petrova", "Beginner", 300000, ("fixed_day", 1, True), 15, [2, 4, 6], "10:00", "11:30"),
    ("Koreys tili", "Koreys tili", "Kim Min-jun", "Beginner", 450000, ("fixed_day", 20, True), 12, [1, 3, 5], "17:00", "18:30"),
    ("Python", "Dasturlash", "Botir Nazarov", "Beginner", 600000, ("fixed_day", 1, True), 12, [2, 4, 6], "19:00", "20:30"),
    ("Tarix", "Tarix", "Akmal Yusupov", "9-sinf", 280000, ("fixed_day", 25, True), 14, [3, 5], "16:00", "17:30"),
]
# Rows of GROUPS that are exactly full (so "To'lgan" can be tried) and how many students each gets.
SIZES = [15, 13, 11, 10, 14, 9, 15, 10, 11, 8]


def main_api() -> dict:
    api = Api()
    api.login("998900000001")
    ids: dict = {"groups": []}

    print("Fanlar, o'qituvchilar, guruhlar...")
    subjects = {}
    for _, subject, *_ in GROUPS:
        if subject not in subjects:
            subjects[subject] = api.post("/subjects", json={"name": subject})["id"]
    teachers = {}
    for i, (_, _, teacher, *_) in enumerate(GROUPS):
        if teacher not in teachers:
            teachers[teacher] = api.post("/teachers", json={"full_name": teacher, "phone": phone(1110000 + i)})["id"]
    ids["teachers"] = teachers
    for name, subject, teacher, level, fee, (mode, day, prorate), cap, days, start, end in GROUPS:
        g = api.post(
            "/groups",
            json={
                "subject_id": subjects[subject], "name": name, "teacher_id": teachers[teacher], "fee_amount": fee,
                "billing_mode": mode, "billing_day": day, "prorate_first_period": prorate, "level": level,
                "capacity": cap, "start_date": str(TODAY - timedelta(days=80)),
            },
        )
        api.put(
            f"/groups/{g['id']}/schedule",
            json={"slots": [{"weekday": d, "starts_at": start, "ends_at": end} for d in days]},
        )
        ids["groups"].append(g["id"])

    print("O'qituvchi oyligi qoidalari...")
    names = list(teachers)
    for i, t in enumerate(names):
        if i % 4 == 3:
            api.put(f"/finance/teachers/{teachers[t]}/salary", json={"method": "fixed", "fixed": 2_500_000})
        else:
            api.put(f"/finance/teachers/{teachers[t]}/salary", json={"method": "percent", "percent": 30 + 5 * (i % 3)})
    api.put(f"/finance/groups/{ids['groups'][2]}/salary", json={"method": "percent", "percent": 45})

    print("O'quvchilar...")
    students: list[dict] = []
    n = 0
    for gi, size in enumerate(SIZES):
        for k in range(size):
            n += 1
            name = f"{FIRST[n % len(FIRST)]} {LAST[(n * 7) % len(LAST)]}"
            joined = TODAY - timedelta(days=random.choice([20, 28, 33, 40, 47, 55, 60, 75]) if k > 1 else random.choice([1, 3, 6]))
            s = api.post(
                "/students/with-enrollment",
                json={
                    "full_name": name, "phone": phone(2000000 + n), "group_id": ids["groups"][gi],
                    "joined_at": str(joined), "parent_phone": phone(3000000 + n),
                    "heard_from": random.choice(["instagram", "telegram", "referral", "walk_in", "other"]),
                    "note": random.choice([None, None, "Kechqurun keladi", "Ota-onasi bilan gaplashilgan"]),
                },
            )
            students.append({"id": s["student"]["id"], "group": ids["groups"][gi], "n": n})
    ids["students"] = students

    print("Ba'zi o'quvchilar ikkinchi guruhga qo'shiladi...")
    for i, s in enumerate(students[::9]):
        # Never the group they are already in (a step of 1..9 around the ring).
        other = ids["groups"][(ids["groups"].index(s["group"]) + 1 + (3 + i) % 9) % len(ids["groups"])]
        api.post(
            f"/students/{s['id']}/add-to-group",
            json={"group_id": other, "joined_at": str(TODAY - timedelta(days=random.choice([4, 12, 25])))},
        )
    return ids


async def charges_attendance_payments(ids: dict) -> None:
    conn = await asyncpg.connect(DATABASE_URL)
    # A student registered when they joined, not today -- so "Yangi" means what it says.
    await conn.execute(
        "update students s set created_at = (select min(e.joined_at)::timestamp at time zone 'Asia/Tashkent' "
        "from enrollments e where e.student_id = s.id) where exists (select 1 from enrollments e where e.student_id = s.id)"
    )
    print("Oylik hisoblar...")
    await money.generate_charges(conn, TODAY)

    print("Davomat (har guruhning oxirgi 10 darsi)...")
    for gid in ids["groups"]:
        group = await conn.fetchrow("select id, teacher_id from groups where id = $1", gid)
        slots = await conn.fetch("select weekday, starts_at, ends_at from group_schedules where group_id = $1", gid)
        enrollments = await conn.fetch("select id from enrollments where group_id = $1 and status = 'active'", gid)
        made, d = 0, TODAY
        while made < 10 and d > TODAY - timedelta(days=90):
            d -= timedelta(days=1)
            for sl in (s for s in slots if s["weekday"] == d.isoweekday()):
                tz = "Asia/Tashkent"
                lesson = await conn.fetchval(
                    """
                    insert into lessons (group_id, starts_at, ends_at, teacher_id)
                    values ($1, ($2::date + $3::time) at time zone $5, ($2::date + $4::time) at time zone $5, $6)
                    on conflict (group_id, starts_at) do update set group_id = excluded.group_id returning id
                    """,
                    gid, d, sl["starts_at"], sl["ends_at"], tz, group["teacher_id"],
                )
                for e in enrollments:
                    r = (e["id"] * 31 + d.timetuple().tm_yday * 17) % 100
                    t = e["id"] % 7
                    status = (
                        "absent" if (t == 0 and r < 45) or (t == 1 and r < 20) or r < 8
                        else "late" if r < 15 else "excused" if r < 18 else "present"
                    )
                    await conn.execute(
                        "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3) "
                        "on conflict do nothing", lesson, e["id"], status,
                    )
                made += 1
    await conn.close()


def payments_and_rest(ids: dict) -> None:
    api = Api()
    api.login("998900000001")

    print("To'lovlar (to'liq, qisman, qarzdor, oldindan to'lagan, bitta bekor qilingan)...")
    methods = ["cash", "card", "click_payme"]
    cancelled_one = False
    for i, s in enumerate(ids["students"]):
        profile = api.get(f"/students/{s['id']}/profile")
        groups = [g for g in profile["groups"] if g["status"] == "active"]
        owed = [g for g in groups if g["balance"] > 0]
        kind = i % 10
        if not owed or kind in (7, 8):  # leaves a debtor
            continue
        for g in owed:
            amount = g["balance"] // 2 if kind == 6 else g["balance"] + (150_000 if kind == 9 else 0)
            p = api.post(
                f"/enrollments/{g['enrollment_id']}/payments",
                json={"amount": amount, "method": methods[(i + g["group_id"]) % 3]},
            )
            if not cancelled_one and kind == 0:
                api.post(f"/payments/{p['id']}/cancel", json={"reason": "Xato kiritilgan"})
                api.post(
                    f"/enrollments/{g['enrollment_id']}/payments",
                    json={"amount": amount, "method": "cash"},
                )
                cancelled_one = True

    print("Arxiv: bir nechta o'quvchi arxivga o'tadi (ma'lumotlari saqlanadi)...")
    gone = 0
    for s in ids["students"][5::13]:
        profile = api.get(f"/students/{s['id']}/profile")
        if len(profile["groups"]) == 1:
            api.post(f"/students/{s['id']}/archive", json={"note": "Boshqa shaharga ko'chib ketdi"})
            gone += 1
        if gone >= 4:
            break

    print("Amallar: bittasi guruhdan chiqariladi, bittasi guruhini almashtiradi...")
    removed = moved = False
    for s in ids["students"][2::9]:
        profile = api.get(f"/students/{s['id']}/profile")
        mine = [g for g in profile["groups"] if g["status"] == "active"]
        if not removed and len(mine) >= 2:
            api.post(f"/students/{s['id']}/remove-from-group",
                     json={"group_id": mine[0]["group_id"], "note": "Dars vaqti to'g'ri kelmadi"})
            removed = True
        elif not moved and len(mine) == 1:
            other = next(g for g in ids["groups"] if g != mine[0]["group_id"])
            api.post(f"/students/{s['id']}/transfer",
                     json={"from_group_id": mine[0]["group_id"], "to_group_id": other, "note": "Darajasi oshdi"})
            moved = True
        if removed and moved:
            break

    print("Qabul: guruhli, sinovli, guruhsiz va arxivdagi odamlar...")
    groups = ids["groups"]

    def lead(name, ph, **extra):
        return api.post(
            "/leads",
            json={"full_name": name, "phone": ph, "client_id": str(uuid.uuid4()), "on_duplicate": "merge", **extra},
            headers={"Idempotency-Key": str(uuid.uuid4())},
        )

    for i, (name, gi) in enumerate([("Nodira Ismoilova", 0), ("Sevara Tursunova", 1), ("Rustam Soliyev", 4), ("Zilola Nurmatova", 3)]):
        extra = {"group_id": groups[gi], "parent_phone": phone(4000000 + i), "address": "Chilonzor, 7-kvartal"}
        if i % 2 == 0:
            lesson = api.get(f"/groups/{groups[gi]}/trial-dates", params={"count": 1})[0]
            extra["trial_starts_at"] = lesson["starts_at"]
        lead(name, phone(5000000 + i), **extra)
    subjects = {s["name"]: s["id"] for s in api.get("/subjects")}
    waiting = [
        ("Kutuvchi Fransuz 1", "Fransuz tili", "A1", "kechqurun, du-chor-ju"),
        ("Kutuvchi Fransuz 2", "Fransuz tili", "A1", "kechqurun"),
        ("Kutuvchi Fransuz 3", "Fransuz tili", "A1", "kunduzi"),
        ("Kutuvchi Fransuz 4", "Fransuz tili", "A1", "se-pay-sha"),
        ("Kutuvchi IELTS 1", "IELTS", "IELTS", "hafta oxiri"),
        ("Kutuvchi IELTS 2", "IELTS", "IELTS", "ertalab"),
        ("Kutuvchi Koreys", "Koreys tili", "Beginner", "kechqurun"),
    ]
    for i, (name, subject, level, note) in enumerate(waiting):
        lead(name, phone(6000000 + i), subject_id=subjects[subject], level=level, note=note,
             parent_phone=phone(6500000 + i), address="Yunusobod, 4-mavze")
    for i in range(2):
        gone_lead = lead(f"Arxivdagi {i + 1}", phone(7000000 + i), group_id=groups[i])
        api.post(
            f"/leads/{gone_lead['id']}/stage",
            json={"version": gone_lead["version"], "stage": "not_interested", "reason": "Qimmat"},
        )
    converted = lead("Yangi O'quvchi Bo'ldi", phone(8000000), group_id=groups[6], address="Mirzo Ulug'bek")
    api.post(
        f"/leads/{converted['id']}/enroll",
        json={"full_name": "Yangi O'quvchi Bo'ldi", "phone": phone(8000000), "group_id": groups[6],
              "joined_at": str(TODAY), "first_payment_amount": 150000, "first_payment_method": "cash"},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )

    print("Xarajatlar va oylik...")
    for category, amount, note in [("rent", 6_000_000, "Ijara"), ("utilities", 850_000, "Elektr va suv"),
                                   ("marketing", 1_200_000, "Instagram reklama"), ("supplies", 430_000, "Marker, qog'oz")]:
        api.post("/expenses", json={"category": category, "amount": amount,
                                    "spent_on": str(TODAY - timedelta(days=random.randint(1, 20))), "note": note, "method": "cash"})
    previous = (TODAY.replace(day=1) - timedelta(days=1)).replace(day=1)
    try:
        month = api.post("/finance/salaries/close", params={"month": str(previous)})
        line = next((t for t in month["teachers"] if t.get("remaining", 0) > 0), None)
        if line:
            api.post("/expenses", json={"category": "salary", "amount": max(line["remaining"] // 2, 1),
                                        "spent_on": str(TODAY), "teacher_id": line["teacher_id"],
                                        "salary_month": str(previous), "method": "cash"})
    except RuntimeError as e:
        print("  (oylik oyi yopilmadi:", str(e)[:120], ")")


def branches_demo() -> None:
    """Two more branches with their own admin, teacher, groups and students, and
    one person who studies in two branches (to try the shared-identity flow)."""
    owner = Api()
    owner.login("998900000001")
    if len(owner.get("/branches")) > 1:
        return
    print("Filiallar: Chilonzor va Yunusobod (admin, o'qituvchi, guruhlar, o'quvchilar)...")
    subjects = {s["name"]: s["id"] for s in owner.get("/subjects")}
    plan = [
        ("Chilonzor", "998900000003", "Chilonzor admini", "Dilfuza Hamidova", 8100000,
         [("Ingliz tili", "Beginner B", 280000, [1, 3, 5], "09:00", "10:30"), ("Matematika", "Algebra 8", 240000, [2, 4], "15:00", "16:30")]),
        ("Yunusobod", "998900000004", "Yunusobod admini", "Rustam Qodirov", 8200000,
         [("Ingliz tili", "Speaking club", 300000, [2, 4, 6], "18:00", "19:30"), ("IELTS", "IELTS 7", 520000, [1, 3, 5], "18:30", "20:00")]),
    ]
    first_names = ["Aziza", "Bobur", "Kamola", "Sherzod", "Nilufar", "Doston", "Mohira", "Jamshid"]
    number = 3_000_000
    for branch, admin_phone, admin_name, teacher_name, base, groups in plan:
        b = owner.post("/branches", json={"name": branch})
        owner.post("/staff", json={"phone": admin_phone, "full_name": admin_name, "password": PASSWORD, "branch_id": b["id"]})
        admin = Api()
        admin.login(admin_phone)
        teacher = admin.post("/teachers", json={"full_name": teacher_name, "phone": phone(base)})
        for gi, (subject, gname, fee, days, start, end) in enumerate(groups):
            g = admin.post("/groups", json={
                "subject_id": subjects[subject], "name": gname, "teacher_id": teacher["id"], "fee_amount": fee,
                "billing_day": 1, "capacity": 12, "level": gname, "start_date": str(TODAY - timedelta(days=60)),
            })
            admin.put(f"/groups/{g['id']}/schedule",
                      json={"slots": [{"weekday": d, "starts_at": start, "ends_at": end} for d in days]})
            for i in range(6):
                st = admin.post("/students/with-enrollment", json={
                    "full_name": f"{first_names[(i + gi) % 8]} {LAST[(i * 3 + gi) % len(LAST)]}",
                    "phone": phone(number), "group_id": g["id"],
                    "joined_at": str(TODAY.replace(day=1)),
                })
                number += 1
                enrollment = st["enrollment_id"]
                if i % 3 != 2:  # two of three pay; the rest owe
                    admin.post(f"/enrollments/{enrollment}/payments", json={"amount": fee, "method": "cash"})
        admin.post("/leads", json={"full_name": f"{branch} so'rovi", "phone": phone(base + 1), "source": "instagram"})
    # One student of Bosh ofis also studies in Chilonzor.
    students = owner.get("/students")
    shared = students[3]
    chilonzor = Api()
    chilonzor.login("998900000003")
    chilonzor.post(f"/students/{shared['id']}/join-branch", json={"phone": shared["phone"]})
    target = next(g for g in chilonzor.get("/groups") if g["name"] == "Algebra 8")
    added = chilonzor.post(f"/students/{shared['id']}/add-to-group",
                           json={"group_id": target["id"], "joined_at": str(TODAY.replace(day=1))})
    chilonzor.post(f"/enrollments/{added['enrollment_id']}/payments", json={"amount": 100000, "method": "cash"})


def main() -> None:
    asyncio.run(create_users())
    ids = main_api()
    asyncio.run(charges_attendance_payments(ids))
    payments_and_rest(ids)
    branches_demo()
    print("\nTayyor. Kirish: 90 000 00 01 / demo1234 (egasi), 90 000 00 02 / demo1234 (Bosh ofis admini),")
    print("90 000 00 03 (Chilonzor admini), 90 000 00 04 (Yunusobod admini) -- hammasi demo1234.")


if __name__ == "__main__":
    main()
