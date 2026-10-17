# Expert Edu Center

CRM for a single education center (Expert Learning Center): call inquiries,
subjects and groups, students and enrollments, monthly billing, payments and
debts. The UI is in Uzbek.

- **App** — Flutter, one codebase for Android, Windows and Linux.
  Phones get a compact bottom-bar app; windows 840 px and wider get the
  desktop layout (sidebar, dashboard, Qarzdorlar, groups/teachers in
  Settings). See `lib/core/layout/breakpoints.dart`.
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

Tests: `cd server && .venv/bin/python -m pytest`

### Upgrading an existing database

Migrations aren't tracked or applied automatically. Apply each new file in
`server/migrations/` once, in order, after taking a backup:

```sh
pg_dump "$DATABASE_URL" -Fc -f backup.dump
psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f migrations/0007_student_intake.sql
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

The version comes from `pubspec.yaml` (`version: 1.6.0+7` → RPM 1.6.0-7).
Android builds update themselves from `uploads/app/version.json` on the
server; desktop builds don't.

## Icons

Replace `branding/logo.png` and run `python3 branding/generate_icons.py`
(needs Pillow) to regenerate the Android, Linux and Windows icons and the
in-app logo mark.
