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

## Phases (nothing is deployed until all are done and tested)

1. Foundation: tables, backfill, Scope, `/branches`, staff with a branch, `/me`.
2. Core: groups, students, enrollments, payments, teachers, timetable.
3. Qabul: leads, trials, follow-ups, funnel, counts, dashboard, debtors, stats.
4. Owner money per branch (Moliya filters, payouts per branch).
5. App: branch selector (owner), branch label (admin), Filial chips in "Hammasi", cross-branch student flow, branch choice in the owner's transfer search, teachers' branches, staff with a branch.
6. Docs, migration rehearsal on a copy of production, deploy.

Every phase has tests proving an admin of branch A can never read or change branch B's data, directly or by id.
