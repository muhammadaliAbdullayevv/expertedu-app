# Expert Edu Center

CRM for a single education center (Expert Learning Center): admissions
(leads, trial lessons, follow-ups), subjects and groups, students and
enrollments, monthly billing, payments and debts. The UI is in Uzbek.

- **App** — Flutter, one codebase for Windows, Linux and Android. The
  desktop is the main target. Windows 840 px and wider get the desktop
  layout (sidebar, dashboard, Qabul, Qarzdorlar, groups/teachers in
  Settings); narrower ones and phones get a compact bottom-bar app. See
  `lib/core/layout/breakpoints.dart`.
- **Server** — FastAPI + asyncpg on PostgreSQL, in `server/`. Single-tenant:
  one deployment = one center. Only owner/admin accounts log in.

## Repository layout

```
lib/                 Flutter app (features/<area>/{data,presentation})
server/app/          FastAPI app: routes/, billing.py, jobs/
server/migrations/   SQL migrations (applied by hand, in order)
server/schema.sql    Full current schema, for a fresh database
linux/packaging/     Fedora RPM spec, .desktop entry, icons, build script
branding/            Logo + generate_icons.py (all platform icons)
.github/workflows/   CI: Windows build
```

## Admissions ("Qabul")

Someone who calls or walks in is a **lead**, not a student: no group, no
charge. A lead moves through

    Yangi → Bog'lanildi → Sinov rejalashtirildi → Sinov o'tdi → Qaror kutilmoqda → O'quvchi bo'ldi

or closes as "Qiziqmadi" / "Bog'lanib bo'lmadi" ("Keyinroq bog'lanish" stays
open with a call-back task). The trial stages follow from trial bookings and
attendance; a no-show or cancelled trial sends the lead back to "Bog'lanildi"
with a follow-up task instead of closing it.

- **Contacts** are identified by phone: the student with that number (one
  student per phone) plus every lead made with it. At most one *open* lead
  per phone per course.
- **Trials** are sessions (time, teacher, room, seats) — dedicated, or guest
  seats at a regular group's lesson — and bookings with their own
  attendance and teacher feedback. Never an enrollment, never a charge.
  Teacher/room/group clashes and full sessions are refused.
- **Enrollment** happens only through "Guruhga yozish"
  (`POST /leads/{id}/enroll`): one transaction that reuses or creates the
  student, enrolls them with the first charge and optional first payment,
  and links it all to the lead. It requires an `Idempotency-Key`, so a
  retry returns the first result instead of enrolling twice.
- **History**: `lead_interactions` is the lead's timeline and audit trail
  (calls, notes, and a row for every change the server makes). It is
  append-only, enforced by a trigger; leads are never deleted.
- **Concurrent edits**: lead, task and session edits carry a `version`; an
  edit made from a stale copy gets a 409.
- **Reports** (`GET /admissions/report`): center-calendar dates, both ends
  inclusive. "So'rovdan o'quvchiga" = of the leads created in the period,
  how many are enrolled now; "Sinovdan o'quvchiga" = the same for leads with
  an attended trial in the period; show rate = attended ÷ (attended +
  absent). A booked trial never counts as an enrollment.

### Offline

Creating a lead, logging a call or note, adding a follow-up and booking a
trial work without a connection: they go to a local SQLite outbox
(`lib/services/sync/`) and `SyncEngine` sends them in order when the API is
back. Each queued write carries its own `Idempotency-Key`, so a resend after
a lost response is answered, not redone; a lead made offline whose phone
already has an open lead for that course is merged into it. Writes the
server refuses (e.g. the trial filled up) stay listed under
"N ta yuborilmagan" with the reason, to retry or discard. Stage changes,
attendance and enrollment need the server.

The old `/inquiries` API still works for app builds before 1.7, mapped onto
leads; its "convert" is refused (410), since only the enrollment step may
create a student now.

## Billing in short

- Each group has a monthly `fee_amount` and a `due_day` (1–31; 31 means the
  last day in shorter months).
- Enrolling a student creates the first charge right away — prorated to the
  next due day, or a full month if chosen in the "Yangi o'quvchi" dialog.
- `server/app/jobs/recurring_charges.py` runs at startup and hourly and adds
  each enrollment's full-fee charge on its due day (minus its discount).
  It's idempotent: a unique index makes a double charge impossible.
- Balance = charges − payments; payments settle the oldest charges first.
- "Today" is the center's date (`CENTER_TIMEZONE`, default `Asia/Tashkent`).

## Running the server

Requires Python 3.12+ and PostgreSQL.

```sh
cd server
python -m venv .venv && .venv/bin/pip install -r requirements.txt
psql "$DATABASE_URL" -f schema.sql                     # fresh database
DATABASE_URL=postgresql://... JWT_SECRET=... \
  .venv/bin/python scripts/create_owner.py 901234567 "Full Name" 'password'
DATABASE_URL=postgresql://... JWT_SECRET=... \
  .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `JWT_SECRET` | yes | Secret for login tokens |
| `JWT_EXPIRES_DAYS` | no | Token lifetime, default 90 |
| `CENTER_TIMEZONE` | no | Calendar used for due dates, default `Asia/Tashkent` |

Tests: `cd server && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest`.
Database tests start a throwaway PostgreSQL (needs `initdb`/`pg_ctl` on
PATH) or use an empty database in `TEST_DATABASE_URL`.

### Upgrading an existing database

Migrations aren't tracked or applied automatically. Apply each new file in
`server/migrations/` once, in order, after taking a backup:

```sh
pg_dump "$DATABASE_URL" -Fc -f backup.dump
psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f migrations/0008_admissions.sql
```

Rollbacks, where provided, are in `server/migrations/rollback/`.

## Running and building the app

Requires Flutter 3.44 (stable). The app talks to the production API by
default; point it elsewhere with `--dart-define=API_BASE_URL=...`.

```sh
flutter pub get
flutter run -d linux                                   # or -d windows, or a device
flutter run -d linux --dart-define=API_BASE_URL=http://127.0.0.1:8000
flutter analyze && flutter test
```

`test/integration/` runs the app's admissions code against a real API. It
creates data, so only point it at a throwaway server:

```sh
flutter test test/integration --dart-define=API_BASE_URL=http://127.0.0.1:8000 \
  --dart-define=E2E_PHONE=901234567 --dart-define=E2E_PASSWORD=...
```

| Platform | Build | Output |
|---|---|---|
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/` |
| Linux (Fedora RPM) | `linux/packaging/build-rpm.sh` | `build/dist/*.rpm` |
| Windows | push to `master`, or run the **Windows build** workflow | Actions → run → artifact `expert-edu-center-windows` |

Windows can only be built on Windows. Locally, that needs Visual Studio 2022
with "Desktop development with C++", then `flutter build windows --release`;
ship the whole `build\windows\x64\runner\Release\` folder.

Linux builds need `gtk3-devel` and `libsecret-devel`. Login tokens are kept in
the system keyring (GNOME Keyring on Fedora Workstation).

The version comes from `pubspec.yaml` (`version: 1.7.2+10` → RPM 1.7.2-10).
SQLite is bundled with the app (the `sqlite3` package's build hook), so
desktop builds need no system SQLite.
Android builds update themselves from `uploads/app/version.json` on the
server; desktop builds don't.

## Icons

Replace `branding/logo.png` and run `python3 branding/generate_icons.py`
(needs Pillow) to regenerate the Android, Linux and Windows icons and the
in-app logo mark.
