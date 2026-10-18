"""DEV-ONLY: replaces the LOCAL database's test data with a big, believable
center to try the app at full size: the headquarters and four filiallar, each
with an admin; 10 language subjects, 20 teachers, 20 groups, 400 students (a
few in two groups, some in two branches), a profile picture for every student
and teacher, 10 weeks of attendance with real habits (good, late, chronic
absentees), monthly charges and payments with real behaviour (on time, late,
partial, prepaid, in debt for 1-3 months), requests, expenses and salaries.

Runs only against a database on this computer and refuses anything else.
Everything money-related goes through the real rules (charges, allocation,
receipts); the history is backdated. Pictures are cartoon avatars made by
DiceBear (no real people).

    cd server && set -a && . ~/.local/share/expertedu-local/env && set +a
    .venv/bin/python local/seed_big.py

Logins afterwards (all demo1234): owner 90 000 00 01; admins 90 000 00 02
(Bosh ofis), ..03 Chilonzor, ..04 Yunusobod, ..05 Mirzo Ulug'bek, ..06 Sergeli.
"""

import asyncio
import os
import random
import shutil
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

DATABASE_URL = os.environ["DATABASE_URL"]
if "127.0.0.1" not in DATABASE_URL and "localhost" not in DATABASE_URL:
    sys.exit("Refusing to seed a database that is not on this computer.")
os.environ.setdefault("JWT_SECRET", "local")

import asyncpg  # noqa: E402
import httpx  # noqa: E402

import seed_local  # noqa: E402
from app import clock  # noqa: E402
from app.money import service as money  # noqa: E402
from seed_local import PASSWORD, Api  # noqa: E402

if "127.0.0.1" not in seed_local.API and "localhost" not in seed_local.API:
    sys.exit("Refusing to talk to a server that is not on this computer.")

rng = random.Random(20261018)
TODAY = clock.today()
TZ = ZoneInfo("Asia/Tashkent")

# --- who -------------------------------------------------------------------------------------------------------

MALE = ["Aziz", "Botir", "Sardor", "Jasur", "Otabek", "Bekzod", "Dilshod", "Rustam", "Akmal", "Farhod", "Timur",
        "Anvar", "Davron", "Eldor", "Jahongir", "Shaxzod", "Javlon", "Sherzod", "Doston", "Jamshid", "Nodir",
        "Ulugbek", "Islom", "Abdulloh", "Muhammad", "Sanjar", "Behruz", "Husan", "Javohir", "Mirzo", "Ravshan",
        "Zafar", "Asadbek", "Diyor", "Humoyun", "Kamron", "Lazizbek", "Murod", "Nurbek", "Sarvar"]
FEMALE = ["Zilola", "Malika", "Nigora", "Feruza", "Madina", "Laylo", "Dilnoza", "Gulnora", "Kamola", "Nodira",
          "Sabina", "Yulduz", "Umida", "Sevara", "Aziza", "Mohira", "Nilufar", "Shahzoda", "Dilfuza", "Barno",
          "Gulbahor", "Hilola", "Iroda", "Lola", "Maftuna", "Nargiza", "Odina", "Ruxshona", "Sitora", "Zarina",
          "Madinabonu", "Asal", "Charos", "Durdona", "Farangiz", "Hayotxon", "Komila", "Lobar", "Muniso", "Robiya"]
SURNAMES = ["Aliyev", "Nazarov", "Karimov", "Yusupov", "Rahmonov", "Abdullayev", "Tursunov", "Hasanov", "Ergashev",
            "Qodirov", "Ismoilov", "Saidov", "Sodiqov", "Ibragimov", "Rahimov", "Mirzayev", "Nurmatov", "Soliyev",
            "Jo'rayev", "Normatov", "Xolmatov", "Berdiyev", "Umarov", "Ochilov", "Murodov", "Shokirov", "Zokirov",
            "Davlatov", "Bobojonov", "Haydarov", "Mamatov", "Orifov", "Pulatov", "Rasulov", "Sultonov", "Toshmatov",
            "Valiyev", "Xudoyberdiyev", "Yo'ldoshev", "Zakirov"]
DISTRICTS = ["Chilonzor", "Yunusobod", "Mirzo Ulug'bek", "Sergeli", "Yashnobod", "Shayxontohur", "Olmazor",
             "Uchtepa", "Bektemir", "Mirobod"]
HEARD = ["instagram", "telegram", "referral", "walk_in", "other"]
NOTES = [None] * 8 + ["Kechqurun keladi", "Ota-onasi bilan gaplashilgan", "Imtihonga tayyorlanadi",
                      "Do'sti bilan birga yozildi", "Chegirma so'radi"]


def surname(base: str, female: bool) -> str:
    return base + "a" if female else base


_used_names: set[str] = set()


def person(female: bool) -> str:
    for _ in range(1000):
        first = rng.choice(FEMALE if female else MALE)
        last = surname(rng.choice(SURNAMES), female)
        name = f"{first} {last}"
        if name not in _used_names:
            _used_names.add(name)
            return name
    raise RuntimeError("out of names")


_phone_counter = 1_000_000


def next_phone() -> str:
    global _phone_counter
    _phone_counter += 1
    return f"99890{_phone_counter:07d}"


# --- the center ------------------------------------------------------------------------------------------------

BRANCHES = [  # name, admin phone, admin name
    ("Bosh ofis", "998900000002", "Bosh ofis admini"),
    ("Chilonzor", "998900000003", "Chilonzor admini"),
    ("Yunusobod", "998900000004", "Yunusobod admini"),
    ("Mirzo Ulug'bek", "998900000005", "Mirzo Ulug'bek admini"),
    ("Sergeli", "998900000006", "Sergeli admini"),
]
SUBJECTS = ["Ingliz tili", "IELTS", "Rus tili", "Nemis tili", "Koreys tili", "Yapon tili", "Xitoy tili",
            "Fransuz tili", "Arab tili", "Turk tili"]

# branch -> groups: name, subject, level, fee, (mode, day, prorate), weekdays, start, end, teacher, female
FIXED = "fixed_day"
ANNIV = "student_anniversary"
PLAN = {
    "Bosh ofis": [
        ("Beginner A", "Ingliz tili", "Beginner", 320000, (FIXED, 1, True), [1, 3, 5], "09:00", "10:30", "Madina Karimova", True),
        ("Intermediate B", "Ingliz tili", "Intermediate", 400000, (FIXED, 1, True), [2, 4, 6], "16:30", "18:00", "Sardor Aliyev", False),
        ("IELTS 6.5", "IELTS", "IELTS 6.5", 600000, (FIXED, 5, False), [1, 3, 5], "18:30", "20:00", "Aziza Rustamova", True),
        ("IELTS 7.5", "IELTS", "IELTS 7.5", 750000, (ANNIV, None, False), [2, 4, 6], "10:00", "11:30", "Bahrom Qodirov", False),
    ],
    "Chilonzor": [
        ("Rus tili A1", "Rus tili", "A1", 300000, (FIXED, 1, True), [1, 3, 5], "10:00", "11:30", "Olga Petrova", True),
        ("Rus tili B1", "Rus tili", "B1", 340000, (FIXED, 10, True), [2, 4, 6], "15:00", "16:30", "Elena Smirnova", True),
        ("Nemis tili A1", "Nemis tili", "A1", 450000, (FIXED, 15, True), [1, 3, 5], "17:00", "18:30", "Jasur Rahimov", False),
        ("Nemis tili A2", "Nemis tili", "A2", 480000, (FIXED, 15, True), [2, 4, 6], "17:00", "18:30", "Gulnora Hasanova", True),
    ],
    "Yunusobod": [
        ("Koreys tili Beginner", "Koreys tili", "Beginner", 450000, (FIXED, 20, True), [1, 3, 5], "17:00", "18:30", "Kim Min-jun", False),
        ("TOPIK-2", "Koreys tili", "TOPIK-2", 520000, (FIXED, 20, True), [2, 4, 6], "18:30", "20:00", "Park Ji-woo", True),
        ("Yapon tili N5", "Yapon tili", "N5", 480000, (FIXED, 1, True), [2, 4], "14:00", "15:30", "Dilshod Yusupov", False),
        ("HSK-1", "Xitoy tili", "HSK-1", 500000, (FIXED, 25, True), [1, 3], "15:30", "17:00", "Li Wei", False),
    ],
    "Mirzo Ulug'bek": [
        ("Kids English", "Ingliz tili", "Kids", 280000, (FIXED, 1, True), [1, 3, 5], "15:00", "16:00", "Zilola Nazarova", True),
        ("Pre-Intermediate", "Ingliz tili", "Pre-Intermediate", 360000, (FIXED, 10, True), [2, 4, 6], "09:30", "11:00", "Otabek Ismoilov", False),
        ("Fransuz tili A1", "Fransuz tili", "A1", 430000, (ANNIV, None, False), [1, 3, 5], "11:00", "12:30", "Nilufar Ismoilova", True),
        ("Fransuz tili A2", "Fransuz tili", "A2", 450000, (FIXED, 5, True), [2, 4], "16:00", "17:30", "Sabina Tursunova", True),
    ],
    "Sergeli": [
        ("Arab tili Beginner", "Arab tili", "Beginner", 330000, (FIXED, 1, True), [2, 4, 6], "10:00", "11:30", "Abdulloh Saidov", False),
        ("Turk tili A1", "Turk tili", "A1", 400000, (FIXED, 15, True), [1, 3, 5], "14:00", "15:30", "Mehmet Yildiz", False),
        ("Speaking Club", "Ingliz tili", "Upper-Intermediate", 380000, (FIXED, 1, True), [2, 4], "18:30", "20:00", "Dilnoza Karimova", True),
        ("Rus tili Kids", "Rus tili", "Kids", 270000, (FIXED, 10, True), [1, 3, 5], "16:00", "17:00", "Svetlana Ivanova", True),
    ],
}
# Teachers who also work in a second branch.
ALSO_IN = {"Sardor Aliyev": "Mirzo Ulug'bek", "Olga Petrova": "Sergeli", "Dilnoza Karimova": "Bosh ofis"}


# SEED_SHAPE=prod: the same center on the four branches that exist on the real
# server (same ids, names and admin ids), so the data can be carried over there.
SHAPE_PROD = os.environ.get("SEED_SHAPE") == "prod"
if SHAPE_PROD:
    BRANCHES = [  # name, local stand-in admin phone, admin name; ids as on the real server
        ("Bosh ofis", "998900000002", "Bosh ofis admini"),
        ("Turon", "998900000003", "Turon admini"),
        ("Iqro", "998900000004", "Iqro admini"),
        ("Ziyo", "998900000005", "Ziyo admini"),
    ]
    PROD_IDS = {"Bosh ofis": 1, "Turon": 2, "Iqro": 3, "Ziyo": 4}
    PROD_ADMIN_IDS = {"Bosh ofis": 3, "Turon": 4, "Iqro": 5, "Ziyo": 6}
    PLAN = {
        "Bosh ofis": PLAN["Bosh ofis"] + [PLAN["Sergeli"][2]],
        "Turon": PLAN["Chilonzor"] + [PLAN["Sergeli"][3]],
        "Iqro": PLAN["Yunusobod"] + [PLAN["Sergeli"][0]],
        "Ziyo": PLAN["Mirzo Ulug'bek"] + [PLAN["Sergeli"][1]],
    }
    ALSO_IN = {"Sardor Aliyev": "Ziyo", "Olga Petrova": "Iqro", "Dilnoza Karimova": "Turon"}


def sizes() -> list[int]:
    out = [rng.randint(15, 25) for _ in range(20)]
    while sum(out) != 400:
        i = rng.randrange(20)
        if sum(out) > 400 and out[i] > 14:
            out[i] -= 1
        elif sum(out) < 400 and out[i] < 25:
            out[i] += 1
    return out


def step(text: str) -> None:
    print(f"\n== {text}", flush=True)


# --- 1. start clean ----------------------------------------------------------------------------------------------


def wipe() -> None:
    step("Eski test ma'lumotlari tozalanadi")
    subprocess.run(
        ["psql", DATABASE_URL, "-q", "-v", "ON_ERROR_STOP=1", "-v", "do_commit=true", "-f", str(ROOT / "ops/wipe_demo_data.sql")],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    photos = ROOT / "photos"
    if photos.exists():
        for f in photos.iterdir():
            if f.is_file():
                f.unlink()


async def reset_prod_shape() -> None:
    """Empties every table and recreates exactly the real server's accounts
    and branches (same ids), with stand-in logins, so what is seeded can be
    moved there as it is."""
    from app.security import hash_password

    step("Mahalliy baza haqiqiy serverning tuzilmasiga keltiriladi")
    conn = await asyncpg.connect(DATABASE_URL)
    tables = [r["tablename"] for r in await conn.fetch("select tablename from pg_tables where schemaname = 'public'")]
    await conn.execute("truncate table " + ", ".join(f'"{t}"' for t in tables) + " restart identity cascade")
    pw = hash_password(PASSWORD)
    for name, bid in PROD_IDS.items():
        await conn.execute("insert into branches (id, name, is_headquarters) values ($1, $2, $3)", bid, name, bid == 1)
    await conn.execute(
        "insert into users (id, phone, password_hash, full_name, role) values (1, '998900000001', $1, 'Madina Karimova', 'owner')",
        pw,
    )
    for name, phone_, admin_name in BRANCHES:
        uid = PROD_ADMIN_IDS[name]
        await conn.execute(
            "insert into users (id, phone, password_hash, full_name, role) values ($1, $2, $3, $4, 'admin')",
            uid, phone_, pw, admin_name,
        )
        await conn.execute("insert into user_branches (user_id, branch_id) values ($1, $2)", uid, PROD_IDS[name])
    await conn.execute("select setval('users_id_seq', 6), setval('branches_id_seq', 4)")
    await conn.close()
    photos = ROOT / "photos"
    if photos.exists():
        for f in photos.iterdir():
            if f.is_file():
                f.unlink()


# --- 2. branches, admins, subjects, teachers, groups -------------------------------------------------------------


def build_center() -> dict:
    owner = Api()
    owner.login("998900000001")
    step("Filiallar va ularning adminlari")
    existing = {b["name"]: b for b in owner.get("/branches")}
    admins: dict[str, Api] = {}
    ids: dict[str, int] = {}
    for name, ph, admin_name in BRANCHES:
        if SHAPE_PROD:
            ids[name] = existing[name]["id"]
        elif name in existing:
            ids[name] = existing[name]["id"]
            owner.post("/staff", json={"phone": ph, "full_name": admin_name, "password": PASSWORD, "branch_id": ids[name]})
        else:
            made = owner.post(
                "/branches",
                json={"name": name, "admin_full_name": admin_name, "admin_phone": ph, "admin_password": PASSWORD},
            )
            ids[name] = made["id"]
        admins[name] = Api()
        admins[name].login(ph)
        admins[name].me = admins[name].get("/me")["user_id"]

    step("Fanlar (10 ta til)")
    subject_ids = {s: owner.post("/subjects", json={"name": s})["id"] for s in SUBJECTS}

    step("O'qituvchilar (20) va guruhlar (20)")
    groups: list[dict] = []
    teachers: dict[str, int] = {}
    n = 0
    for branch, plan in PLAN.items():
        adm = admins[branch]
        for gi, (gname, subject, level, fee, (mode, day, prorate), days, start, end, teacher, female) in enumerate(plan):
            n += 1
            t = adm.post("/teachers", json={"full_name": teacher, "phone": next_phone(), "note": None})
            teachers[teacher] = t["id"]
            g = adm.post(
                "/groups",
                json={
                    "subject_id": subject_ids[subject], "name": gname, "teacher_id": t["id"], "fee_amount": fee,
                    "billing_mode": mode, "billing_day": day, "prorate_first_period": prorate, "level": level,
                    "start_date": str(TODAY - timedelta(days=200)),
                },
            )
            adm.put(
                f"/groups/{g['id']}/schedule",
                json={"slots": [{"weekday": d, "starts_at": start, "ends_at": end, "room": f"{branch[0]}{gi + 1}-xona"} for d in days]},
            )
            groups.append({"id": g["id"], "branch": branch, "name": gname, "fee": fee, "teacher": t["id"]})
    for i, (teacher, other) in enumerate(ALSO_IN.items()):
        home = next(g["branch"] for g in groups if g["teacher"] == teachers[teacher])
        owner.put(f"/teachers/{teachers[teacher]}/branches", json={"branch_ids": [ids[home], ids[other]]})

    step("O'qituvchi oyligi qoidalari")
    for i, tid in enumerate(teachers.values()):
        if i % 5 == 4:
            owner.put(f"/finance/teachers/{tid}/salary", json={"method": "fixed", "fixed": 2_800_000})
        else:
            owner.put(f"/finance/teachers/{tid}/salary", json={"method": "percent", "percent": 30 + 5 * (i % 4)})
    return {"owner": owner, "admins": admins, "branch_ids": ids, "groups": groups, "teachers": teachers}


# --- 3. students -----------------------------------------------------------------------------------------------


def build_students(c: dict) -> list[dict]:
    step("400 ta o'quvchi")
    students: list[dict] = []
    per_group = sizes()
    for g, count in zip(c["groups"], per_group):
        adm = c["admins"][g["branch"]]
        cap = count + rng.choice([0, 0, 1, 2, 4])
        adm.call("PATCH", f"/groups/{g['id']}", json={"capacity": cap})
        for _ in range(count):
            female = rng.random() < 0.5
            ph = next_phone()
            # Many joined long ago; a few in the last days.
            days_ago = rng.choice([rng.randint(60, 180)] * 4 + [rng.randint(15, 60)] * 3 + [rng.randint(0, 14)] * 2)
            made = adm.post(
                "/students/with-enrollment",
                json={
                    "full_name": person(female), "phone": ph, "group_id": g["id"],
                    "joined_at": str(TODAY - timedelta(days=days_ago)), "parent_phone": next_phone(),
                    "heard_from": rng.choice(HEARD), "note": rng.choice(NOTES),
                },
            )
            students.append({"id": made["student"]["id"], "phone": ph, "name": made["student"]["full_name"],
                             "branch": g["branch"], "group": g["id"], "female": female})
    # A few attend two groups in the same branch.
    step("Ba'zilari ikkinchi guruhga ham qatnaydi; ba'zilari boshqa filialda ham o'qiydi")
    by_branch: dict[str, list[dict]] = {}
    for g in c["groups"]:
        by_branch.setdefault(g["branch"], []).append(g)
    for s in rng.sample(students, 34):
        others = [g for g in by_branch[s["branch"]] if g["id"] != s["group"]]
        g2 = rng.choice(others)
        c["admins"][s["branch"]].post(
            f"/students/{s['id']}/add-to-group",
            json={"group_id": g2["id"], "joined_at": str(TODAY - timedelta(days=rng.randint(5, 70)))},
        )
    # A few study in two BRANCHES: same person, same profile.
    for s in rng.sample(students, 10):
        other_branch = rng.choice([b for b in by_branch if b != s["branch"]])
        adm = c["admins"][other_branch]
        adm.post(f"/students/{s['id']}/join-branch", json={"phone": s["phone"]})
        adm.post(
            f"/students/{s['id']}/add-to-group",
            json={"group_id": rng.choice(by_branch[other_branch])["id"],
                  "joined_at": str(TODAY - timedelta(days=rng.randint(5, 60)))},
        )
    return students


# --- 4. charges, payments, attendance (straight into the database, backdated) ---------------------------------


def stamp(day: date, hour: int | None = None) -> datetime:
    """A moment on [day] in the center's time, never in the future."""
    moment = datetime.combine(day, time(hour if hour is not None else rng.randint(9, 18), rng.randint(0, 59)), tzinfo=TZ)
    return min(moment, datetime.now(TZ) - timedelta(minutes=5))


async def money_and_attendance(c: dict) -> None:
    conn = await asyncpg.connect(DATABASE_URL)
    step("Oylik hisoblar")
    await money.generate_charges(conn, TODAY)

    step("To'lovlar (o'z vaqtida, kechikkan, qisman, oldindan, qarzdor)")
    rows = await conn.fetch(
        """
        select e.id as enrollment_id, e.student_id, g.branch_id, b.name as branch
        from enrollments e join groups g on g.id = e.group_id join branches b on b.id = g.branch_id
        where e.status = 'active' order by e.id
        """
    )
    admin_ids = {name: adm.me for name, adm in c["admins"].items()}
    methods = ["cash"] * 11 + ["card"] * 6 + ["click_payme"] * 3
    counts = {"good": 0, "late": 0, "partial": 0, "debtor": 0, "prepaid": 0}
    for row in rows:
        charges = await conn.fetch(
            "select due_date, amount from charge_balances where enrollment_id = $1 and status = 'active' "
            "and due_date <= $2 order by due_date",
            row["enrollment_id"], TODAY,
        )
        if not charges:
            continue
        roll = rng.random()
        persona = "good" if roll < 0.60 else "late" if roll < 0.74 else "partial" if roll < 0.82 else (
            "debtor" if roll < 0.96 else "prepaid")
        counts[persona] += 1
        unpaid_tail = rng.choice([1, 1, 2, 3]) if persona == "debtor" else 0
        for i, ch in enumerate(charges):
            last = i == len(charges) - 1
            if persona == "debtor" and i >= len(charges) - unpaid_tail:
                break
            amount = ch["amount"]
            delay = rng.randint(0, 4)
            if persona == "late":
                delay = rng.randint(6, 22)
                if last and rng.random() < 0.5:
                    break  # still has not paid the newest one
            elif persona == "partial" and last:
                amount = int(amount * rng.choice([0.4, 0.5, 0.6, 0.75]) // 10000 * 10000) or 100000
            elif persona == "prepaid" and last:
                amount = amount + rng.choice([200000, 300000, 400000])
            if ch["due_date"] + timedelta(days=delay) > TODAY:
                delay = max((TODAY - ch["due_date"]).days, 0)
            await money.record_payment(
                conn, student_id=row["student_id"], amount=int(amount), method=rng.choice(methods),
                user_id=admin_ids[row["branch"]], enrollment_id=row["enrollment_id"],
                received_at=stamp(ch["due_date"] + timedelta(days=delay)),
            )
    print("  ", counts)

    step("Davomat (oxirgi 10 hafta)")
    groups = await conn.fetch("select id, teacher_id from groups order by id")
    habits: dict[int, float] = {}
    made = 0
    for gi, g in enumerate(groups):
        slots = await conn.fetch("select weekday, starts_at, ends_at from group_schedules where group_id = $1", g["id"])
        enrollments = await conn.fetch(
            "select id, student_id, joined_at, ended_at from enrollments where group_id = $1", g["id"]
        )
        days = [TODAY - timedelta(days=k) for k in range(70, 0, -1)]
        lesson_days = [d for d in days if any(s["weekday"] == d.isoweekday() for s in slots)]
        for li, d in enumerate(lesson_days):
            if gi % 7 == 3 and li >= len(lesson_days) - 2:
                continue  # an admin forgot to mark the last two lessons of this group
            for s in (s for s in slots if s["weekday"] == d.isoweekday()):
                lesson = await conn.fetchval(
                    """
                    insert into lessons (group_id, starts_at, ends_at, teacher_id)
                    values ($1, ($2::date + $3::time) at time zone 'Asia/Tashkent',
                            ($2::date + $4::time) at time zone 'Asia/Tashkent', $5)
                    on conflict (group_id, starts_at) do update set group_id = excluded.group_id returning id
                    """,
                    g["id"], d, s["starts_at"], s["ends_at"], g["teacher_id"],
                )
                batch = []
                for e in enrollments:
                    if e["joined_at"] > d or (e["ended_at"] is not None and e["ended_at"] < d):
                        continue
                    base = habits.setdefault(
                        e["student_id"],
                        rng.choices([0.97, 0.88, 0.74, 0.5], weights=[52, 28, 12, 8])[0],
                    )
                    r = rng.random()
                    status = (
                        "present" if r < base - 0.07
                        else "late" if r < base
                        else "excused" if r < base + (1 - base) * 0.3
                        else "absent"
                    )
                    batch.append((lesson, e["id"], status))
                await conn.executemany(
                    "insert into attendance (lesson_id, enrollment_id, status) values ($1, $2, $3) on conflict do nothing",
                    batch,
                )
                made += len(batch)
    print("  ", made, "ta davomat belgisi")
    await conn.close()


# --- 5. requests, expenses, salaries -----------------------------------------------------------------------------


def requests_and_costs(c: dict) -> None:
    step("Qabul: so'rovlar, sinov darslari")
    by_branch: dict[str, list[dict]] = {}
    for g in c["groups"]:
        by_branch.setdefault(g["branch"], []).append(g)
    for branch, adm in c["admins"].items():
        for i in range(7):
            g = rng.choice(by_branch[branch])
            extra: dict = {"group_id": g["id"], "parent_phone": next_phone(), "address": f"{rng.choice(DISTRICTS)}, {rng.randint(1, 25)}-mavze"}
            if i % 3 == 0:
                try:
                    lessons = adm.get(f"/groups/{g['id']}/trial-dates", params={"count": 1})
                except RuntimeError:
                    lessons = []
                if lessons:
                    extra["trial_starts_at"] = lessons[0]["starts_at"]
            body = {"full_name": person(rng.random() < 0.5), "phone": next_phone(), "client_id": str(uuid.uuid4()),
                    "on_duplicate": "merge", "source": rng.choice(HEARD)}
            try:
                lead = adm.post("/leads", json={**body, **extra}, headers={"Idempotency-Key": str(uuid.uuid4())})
            except RuntimeError:  # the trial lesson was full: a request without it
                extra.pop("trial_starts_at", None)
                lead = adm.post("/leads", json={**body, "client_id": str(uuid.uuid4()), **extra},
                                headers={"Idempotency-Key": str(uuid.uuid4())})
            if i == 5:
                adm.post(f"/leads/{lead['id']}/stage",
                         json={"version": lead["version"], "stage": "not_interested", "reason": "Qimmat"})

    step("Xarajatlar va oyliklar")
    for name, bid in c["branch_ids"].items():
        for months_back in range(3):
            day = (TODAY.replace(day=1) - timedelta(days=30 * months_back)).replace(day=3)
            if day > TODAY:
                continue
            for category, amount, note in [("rent", rng.choice([5_500_000, 6_000_000, 7_000_000]), "Ijara"),
                                           ("utilities", rng.randint(700_000, 1_100_000), "Elektr, suv, internet"),
                                           ("marketing", rng.randint(500_000, 1_800_000), "Instagram reklama")]:
                c["owner"].post("/expenses", json={"category": category, "amount": amount,
                                                   "spent_on": str(day + timedelta(days=rng.randint(0, 6))),
                                                   "note": note, "method": "cash"},
                                headers={"X-Branch": str(bid)})
    previous = (TODAY.replace(day=1) - timedelta(days=1)).replace(day=1)
    try:
        month = c["owner"].post("/finance/salaries/close", params={"month": str(previous)})
        for line in [t for t in month["teachers"] if t.get("remaining", 0) > 0][:12]:
            c["owner"].post("/expenses", json={"category": "salary", "amount": line["remaining"],
                                               "spent_on": str(previous + timedelta(days=rng.randint(26, 28))),
                                               "teacher_id": line["teacher_id"], "salary_month": str(previous),
                                               "method": "cash"})
    except RuntimeError as e:
        print("  (oyliklar yopilmadi:", str(e)[:140], ")")


def leave_and_archive(c: dict, students: list[dict]) -> None:
    step("Bir nechta o'quvchi arxivga o'tadi")
    reasons = ["Boshqa shaharga ko'chib ketdi", "Vaqti yo'q", "Boshqa markazga o'tdi", "Moliyaviy qiyinchilik"]
    gone = 0
    for s in rng.sample(students, 60):
        adm = c["admins"][s["branch"]]
        profile = adm.get(f"/students/{s['id']}/profile")
        if len([g for g in profile["groups"] if g["status"] == "active"]) == 1 and gone < 22:
            adm.post(f"/students/{s['id']}/archive", json={"note": rng.choice(reasons)})
            gone += 1


# --- 6. pictures -----------------------------------------------------------------------------------------------


def avatar(seed: str) -> bytes:
    url = f"https://api.dicebear.com/9.x/avataaars/png?seed={seed}&size=200&backgroundColor=b6e3f4,c0aede,d1d4f9,ffd5dc,ffdfbf"
    for attempt in range(4):
        try:
            r = httpx.get(url, timeout=30)
            if r.status_code == 200 and r.content[:4] == b"\x89PNG":
                return r.content
        except httpx.HTTPError:
            pass
    raise RuntimeError(f"no avatar for {seed}")


def pictures(c: dict, students: list[dict]) -> None:
    step("Rasmlar (hamma o'quvchi va o'qituvchiga)")
    people = [("students", s["id"], s["branch"], s["name"]) for s in students]
    teacher_rows = c["owner"].get("/teachers", headers={"X-Branch": "all"})
    home = {}
    for g in c["groups"]:
        home[g["teacher"]] = g["branch"]
    people += [("teachers", t["id"], home[t["id"]], t["full_name"]) for t in teacher_rows if t["id"] in home]
    with ThreadPoolExecutor(10) as pool:
        pngs = list(pool.map(lambda p: avatar(f"{p[0]}-{p[1]}-{p[3]}"), people))
    for (group, pid, branch, _), png in zip(people, pngs):
        c["admins"][branch].call(
            "PUT", f"/photos/{group}/{pid}", content=png, headers={"Content-Type": "image/png"}
        )
    print("  ", len(people), "ta rasm")


def main() -> None:
    if SHAPE_PROD:
        asyncio.run(reset_prod_shape())
    else:
        wipe()
    c = build_center()
    students = build_students(c)
    asyncio.run(money_and_attendance(c))
    requests_and_costs(c)
    leave_and_archive(c, students)
    # Today: lessons around the clock, a request nobody answered, calls, payment days.
    asyncio.run(seed_local.today_demo_db())
    seed_local.today_demo_api()
    pictures(c, students)
    print("\nTayyor. Kirish (hammasi demo1234): egasi 90 000 00 01; adminlar 90 000 00 02 (Bosh ofis), ..03 Chilonzor, "
          "..04 Yunusobod, ..05 Mirzo Ulug'bek, ..06 Sergeli.")


if __name__ == "__main__":
    main()
