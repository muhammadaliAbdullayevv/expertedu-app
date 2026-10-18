# Branches (Bosh ofis + 4 filiallar)

One server, one database, one app build for every laptop. Every record belongs to a
branch and **the server** decides what each login may see -- never the app.

## Decisions (owner, 2026-10-18)

| Topic | Decision |
|---|---|
| Who sees what | **Owner**: all branches together ("Hammasi") or one at a time. **Admin**: exactly one branch, fixed. |
| Money (Moliya, teacher pay, expenses) | Owner only (already built). |
| One person, many branches | **One student record** per person (name, phones, address, photo shared). Phone stays unique across the center. |
| What a second branch's admin sees of a student from another branch | **Only the shared identity**; groups, payments, attendance, debts, notes and actions of other branches are hidden. Owner sees all. |
| Duplicate phone at another branch | "Bu raqam bilan o'quvchi allaqachon *Filial* da mavjud" + button **Shu o'quvchini mening filialimga qo'shish** (links the same student; no duplicate). |
| Moving a student to another branch | **Owner only**; the group search then has a Filial choice and lists that branch's groups. |
| Teachers | A teacher can work at several branches; paid per branch; owner sees the branch(es) and pay (total in "Hammasi", that branch's in a branch view). |
| Prices | Per group (already), so branches differ naturally. Courses (subjects) are shared. |
| Trial limit | One rule for the whole center (owner sets it): one free trial per person across branches. |

## Data model

- `branches(id, name, is_headquarters, is_active)`; id 1 = "Bosh ofis" (all existing data goes there).
- `user_branches(user_id, branch_id)` -- an admin's branch (a side table: `users` is owned by postgres in production). The owner has none.
- `branch_id` on `groups`, `leads`, `expenses`, `trial_sessions`, `student_events`, `salary_payouts`.
- `teacher_branches(teacher_id, branch_id)`; `student_branches(student_id, branch_id, archived_at)` -- a student is visible to a branch only through this link; **archiving is per branch** (it moves from `students.archived_at` to the link).
- Everything else hangs off a group, so it follows the group's branch: enrollments, lessons, attendance, charges, payments (via enrollment), allocations, salary lines.

## The request flow

1. Login -> token (unchanged). `GET /me` also returns the account's branch (admin) or the branch list (owner).
2. Every request is turned into a **Scope**: admin = `[their branch]` always (any header is ignored); owner = the `X-Branch` header if sent, else all branches.
3. Every query filters by the scope (`branch_id = any($ids)` / `$ids is null` for all) and every lookup by id returns **404** for a record outside the scope -- never 403, so existence does not leak.
4. Writes put the record in the scope's branch (an owner in "Hammasi" must choose a branch when creating).

## What was built on the server (phases 1-4, tested)

- Tables and backfill: migration `0022_branches.sql` (everything existing -> Bosh ofis, admins -> their branch, teachers and students linked to Bosh ofis; students' archive and note moved onto the link; payments, pay lines, events, expenses, trial sessions, leads and groups carry `branch_id`; a record made without a branch is Bosh ofis).
- `deps.get_scope` is a dependency of every router (see `main.py`); `tests/test_branches.py::test_every_route_is_inside_a_branch_scope` fails if a route escapes it. Helpers in `scope.py`; deep helpers (`lock_lead`, `fetch_lead`, trial fetches) read the request's ambient scope.
- Money: payments carry the branch, a payment only pays that branch's charges (`apply_credit`), balances come from `student_branch_balances`. Teacher pay lines carry the branch; payouts are made in, and capped by, one branch.
- A teacher with a fixed salary is counted in their first branch.

## Phases (nothing is deployed until all are done and tested)

1. Foundation: tables, backfill, Scope, `/branches`, staff with a branch, `/me`.
2. Core: groups, students, enrollments, payments, teachers, timetable.
3. Qabul: leads, trials, follow-ups, funnel, counts, dashboard, debtors, stats.
4. Owner money per branch (Moliya filters, payouts per branch).
5. App: branch selector (owner), branch label (admin), Filial chips in "Hammasi", cross-branch student flow, branch choice in the owner's transfer search, teachers' branches, staff with a branch.
6. Docs, migration rehearsal on a copy of production, deploy.

Every phase has tests proving an admin of branch A can never read or change branch B's data, directly or by id.

## What was built in the app (phase 5, tested)

- **Owner**: a switcher under the logo -- *Hammasi* or one branch. Every request carries it (`X-Branch`); changing it reloads every page and closes a course/group left open. Lists show a **Filial** column/label only when every branch is in view. A new teacher, group, expense or salary payout first asks *which branch* (and switches the view to it); Qabul says where a group-less request goes.
- **Admin**: the branch name under the logo, nothing to choose; no Moliya in the menu.
- **Same person in two branches**: typing a number that belongs to another branch shows "Bu raqam bilan o'quvchi allaqachon *Filial* filialida mavjud" with **Shu o'quvchini mening filialimga qo'shish** (no duplicate); that branch then sees only the shared details and keeps its own groups, payments, attendance, notes and archive.
- **Moving a student to another branch** is the owner's: the new-group search has Filial pills (Hammasi / each branch) and labels each group.
- **Teachers** can work in several branches (owner: *Filiallarni o'zgartirish*); pay is worked out and paid per branch.
- **Settings**: *Filiallar* (add, rename, switch off; never Bosh ofis) and *Xodimlar* with the admin's branch.

Local demo (after `expertedu-local.sh reset` or `seed`): owner `90 000 00 01`, Bosh ofis admin `…02`, Chilonzor admin `…03`, Yunusobod admin `…04`, all `demo1234`; one Bosh ofis student also studies in Chilonzor.

## Deploy checklist (not done yet)

1. Back up the database (`pg_dump -Fc`), as before.
2. Apply `0020_photos.sql`, `0021_student_actions.sql`, `0022_branches.sql` in order (`psql -1 -v ON_ERROR_STOP=1`); they never ALTER `users` (the branch of an admin is in `user_branches`).
3. Create `/opt/expertedu/photos`, set `PHOTOS_DIR` in `/etc/expertedu.env`, include it in backups; exclude `photos/` from the code rsync.
4. Rehearse the migrations on a restored copy of production (real table owners), then deploy and restart.
5. In the app: Settings -> Filiallar (add the four), Xodimlar (put each admin in a branch), then move each branch's groups and teachers over (owner moves a group's branch by creating it in the right branch -- there is no bulk move yet).
