# Audit — Expert Edu Center CRM (Phase 0)

Date: 2026-10-17. Read-only inspection; no code was changed. Production was queried for row counts only.

## 0. Blocker found first

**`docs/design/` does not exist.** There are no V2 screenshots in the repo (`docs/` did not exist at all). Phases 2–7 are meant to match those screenshots in layout, hierarchy and spacing. Until they are added I can only follow the written description (sidebar groups, Ctrl+K bar, 14 px cards, DM Sans, `#5B4DDB`). Please add them before Phase 2.

## 1. What exists

**Stack.** Flutter 3.44 (Riverpod, go_router) for Android, Windows and Fedora. Backend is FastAPI + asyncpg with raw SQL on PostgreSQL, hand-written migrations (`server/migrations/0001–0011`, rollbacks in `migrations/rollback/`, no tracking table). Deployed on one VPS behind a systemd unit. 76 server tests (real throwaway Postgres), ~25 Dart tests.

**Production data right now:** 126 students, 10 teachers, 10 groups, 125 enrollments, **152 charges, 1 payment**, 1 lead, 1 user. All of it is test data, as you said.

### Screens (desktop ≥ 840 px uses a sidebar, phone uses a bottom bar)

| Area | Screens | State |
|---|---|---|
| Home | Dashboard (desktop and phone versions) | works; numbers inherit the money problems in §3 |
| Qabul | pipeline, leads list, trials, follow-ups, overview, lead panel, new-lead / trial / enroll dialogs | works, offline-first (SQLite + outbox) |
| Jadval | week view, attendance sheet, per-group weekly slots | works |
| Subjects → groups → roster | list screens | works, phone-style navigation on desktop |
| O'quvchilar | list, add-student wizard | works; no side panel, no saved views |
| Qarzdorlar | debtors list | works, but see §3 |
| Moliya (owner) | summary, salaries, expenses | works, but see §3 |
| Statistika | charts | works |
| Settings | groups, teachers, staff, profile | works |
| Missing vs V2 | command bar (Ctrl+K), "+ Yangi", course finder, "Sinovdan keyin" screen as a dialog, teacher profile/workload, group side panel, "To'lov qabul qilish" panel/sheet, day list/date jump | not built |

### Backend (what it is)

- Auth: JWT, roles `owner` / `admin` only. No teacher login. Owner-only routes via `require_owner`.
- Money lives in **one table, `transactions`** (`kind` = `charge` | `payment`), keyed by `enrollment_id`. Balance = Σcharges − Σpayments, computed in SQL at read time. Good: nothing is stored as an editable balance.
- Admissions: `leads`, `trial_sessions`, `trial_bookings`, `follow_up_tasks`, append-only `lead_interactions`, `idempotency_keys`. Enrollment of a lead is one transaction with an Idempotency-Key.
- Schedule: `group_schedules` (weekly slots), `lessons` (a row only once marked/cancelled/extra), `attendance`.
- Finance: `teachers.salary_percent`, `transactions.teacher_id` (set by a trigger at payment time), `expenses` (voided, never deleted), salary payouts as `expenses` rows.
- Time: `clock.today()` uses `Asia/Tashkent`; SQL buckets use `at time zone`.

## 2. What to keep (do not rewrite)

- Auth, staff, idempotency, housekeeping, audit-style `lead_interactions`.
- The whole Qabul/trial machinery (leads, trial sessions and bookings, phone-dedup lock, optimistic `version`, offline outbox/sync). A trial **already** creates no charge and no enrollment and never becomes a student, which matches the V2 rule.
- Schedule/attendance tables and the clash checks (teacher, room, group, trials).
- Expenses with void-not-delete; `staff_logins`; desktop installer, updater and backups.
- `billing.py` date maths and its tests, the Dart ledger FIFO calculator (as a reference for the allocation rules).
- Test harness (`conftest.py` starting a real Postgres) — new money tests should use it.

## 3. Money-logic problems (why the debt cannot be trusted)

1. **Withdrawal hard-deletes charges** (`routes/enrollments.py`, `withdraw_enrollment`: `delete from transactions … kind='charge'`). Violates "never hard-delete charges". A withdrawn student's history silently changes.
2. **Payments cannot be cancelled or reversed at all.** There is no endpoint. A wrong payment is permanent. No reversal, no reason, no who/when.
3. **Payment `method` is dropped.** `POST /enrollments/{id}/payments` accepts only `amount` and `note`; the column `method` is only filled by the add-student wizard. The Naqd/Karta/Click split V2 needs does not exist for ordinary payments. There is also no `received_by` (only `created_by`) and no receipt number.
4. **No allocation.** Payments are not linked to charges. "Oldest unpaid first" is recomputed on the fly in two places that must agree (`billing.oldest_unpaid_due` in Python, `enrollment_ledger_calculator.dart` in Dart). Per-charge paid status is a client-side calculation. Salary cannot be computed per charge/student from payments, and a cancelled payment cannot be traced to what it paid.
5. **Balance is per enrollment, not per student.** `list_students` sums across all enrollments, `debtors` is per enrollment, the dashboard debt counts `student_id` once per positive-balance enrollment. A student overpaid in one group and indebted in another shows inconsistent totals, and overpayment is never a credit usable elsewhere.
6. **Debt includes charges nobody should pay yet.** Charges are created on the group's due day, "in advance", for every active enrollment, with a per-group `due_day`. With the test data (125 enrollments, 152 charges, 1 payment) nearly everyone is a debtor. V2 wants one billing day (a setting, default the 1st); here it is per group.
7. **Debt age buckets (0–7, 8–30, 30+) do not exist**; only `oldest_unpaid_due` is returned.
8. **Proration is "days to next due day"** (period between due days), not "remaining days of the calendar month". When `due_day` ≠ 1 the first charge differs from the V2 rule. It is rounded with Python `round()` (banker's rounding) — fine for tests, but must be one documented rule. A `first_month: full` option exists on enrollment already.
9. **Discounts are applied to every future charge** (stored on the enrollment); `discounted_fee` for percent follows the group's current fee. Acceptable, but charges store no snapshot of the base fee, so a changed group fee silently changes future months only and past ones can't be explained.
10. **Charges are generated by an hourly background loop** inside the API process (`jobs/recurring_charges.py`). It is idempotent (unique index), but has no record of "run for month M", and withdrawing after a charge deletes it (point 1).
11. **Dashboard "Oylik reja" = Σ group fee over active enrollments**, ignoring discounts and proration — it will never match what is billed.
12. **Salary is a SUM of `payment` transactions by `teacher_id` in a calendar month × percent.** Close to the V2 cash-basis rule, but:
    - no per-group override of the percent,
    - no month closing / snapshot — changing a percent rewrites history,
    - cancelled payments don't exist, so refunds can't reduce a month,
    - trial exclusion is moot (trials never create payments) but not asserted,
    - `teacher_id` is stamped from the group's teacher at payment time via trigger; a payment on a charge for an older period is attributed to the *current* teacher,
    - payouts are `expenses` rows with `category='salary'`, not a `SalaryPayout` entity (no "paid by", but `created_by` exists).
13. **Money is `bigint` so'm** — correct. Percent salary uses `Decimal` with ROUND_HALF_UP — correct. `numeric(5,2)` percent — fine.

## 4. Why the Qabul numbers don't match

Several different denominators coexist:

- Dashboard `open_leads` counts the six `OPEN_STAGES`, including `follow_up_later`; the pipeline board and "Yangi" tile count different subsets.
- Report `new_inquiries` is *created in range*, `enrollments` is *enrolled in range* (a lead created last month who enrolled today counts here but not in the cohort), `cohort_enrolled` is created-in-range AND currently enrolled. Three numbers all called "conversion"/"enrolled" with three bases.
- Trial counts are by **session date**, leads by **created date**, so a window can show more trials than leads.
- The legacy `/inquiries` adapter (kept for old app builds) maps 9 stages into 5 and is still reachable.
- The test database also holds students that were created straight in "O'quvchilar" (126) while only 1 lead exists, so "leads → students" can never reconcile: **students may be created without a lead**, which breaks the V2 rule "every person starts as a Lead".

Fix direction (Phase 3): one definition per number, each labelled with its denominator in the UI, one funnel built from lead events.

## 5. Other bugs and risks

- Students can still be created directly (`POST /students`, add-student wizard), bypassing Lead.
- `students` has no archive/status; there is no way to archive instead of delete (no delete exists, which is safe, but no "archived" either). Same for `groups` (`is_active`) and `teachers` (`is_active`) — those do archive.
- No generic **audit log**. Only `lead_interactions` (leads), `expenses` void fields, and `created_by` columns. Payments/enrollment changes/price changes are untracked.
- Group has `fee_amount`, `due_day`, `capacity` but no level, no start date, no room (rooms are free text on schedule slots), no weekdays on the group itself (they're in `group_schedules`). V2 "Group" needs level, start date, status; `Room` is not an entity.
- `Subject` has no levels. V2 course finder filters by level.
- Lead has no desired weekdays/time of day; has `preferred_trial_date` only.
- `SalaryRun`/`SalaryPayout`, `PaymentAllocation`, `AuditLog`, `Room` do not exist.
- Migrations have no tracking table; applied by hand with `psql -1`. Constraint from prod: migrations may not ALTER `users` (owned by `postgres`).
- Deploy is manual (rsync + psql + restart).
- No seed command; test data was loaded into production by hand. No "dev-only" guard exists.
- Excel import of students does not exist.

## 6. Verdict

The CRM shell, admissions and schedule are in good shape and are kept. The money layer is the weak part: one table with no allocation, no cancellation, no month snapshot, hard-deleted charges on withdrawal, and several inconsistent balance definitions. Phase 1 replaces that layer with one domain module and database functions, migrates the existing 152 charges / 1 payment forward without loss, and keeps the current endpoints working (as thin wrappers) until the UI moves over.
