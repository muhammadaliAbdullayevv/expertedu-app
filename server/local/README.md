# Expert Edu on this computer only

A full copy of the backend that runs **on this computer** with its **own database**.
The desktop app built for it never talks to the real server.

## First time

```sh
server/local/expertedu-local.sh setup
```

It makes a PostgreSQL in `~/.local/share/expertedu-local`, the tables, a complete set of
test data, and two user services (`expertedu-local-db`, `expertedu-local-api`) that start
when you log in. Then build the app for it:

```sh
BUILD_ARGS="--dart-define=API_BASE_URL=http://127.0.0.1:8765" linux/packaging/build-rpm.sh
sudo dnf reinstall build/dist/expert-edu-center-*.fc44.x86_64.rpm
```

Sign in with `90 000 00 01` / `demo1234` (owner) or `90 000 00 02` / `demo1234` (admin).
The sidebar shows **Mahalliy rejim** so you always know which data you are on.

## Everyday

| | |
|---|---|
| `expertedu-local.sh status` | is it running? |
| `expertedu-local.sh stop` / `start` | stop or start both services |
| `expertedu-local.sh reset` | throw the local data away and make the test data again |
| `systemctl --user disable --now expertedu-local-api expertedu-local-db` | stop it starting at login |

## What the test data has

10 groups with teachers, days, times, prices (both billing modes), seat limits (several full),
about 115 students (some in two groups, a few archived), attendance for each group's last
10 lessons, payments (paid, half-paid, ahead, debtors, one cancelled), teacher pay rules,
expenses, and in Qabul: people with a group, with a booked trial, waiting for a group that
does not exist yet, archived, and one already turned into a student.

`seed_local.py` refuses to run against anything but a database on this computer.
