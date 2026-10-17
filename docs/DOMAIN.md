# Domain model and migration plan

Adapts the V2 model to the real backend (FastAPI + Postgres). Money is **integer so'm**; time zone **Asia/Tashkent** (`clock.today()` and `at time zone` in SQL). Nothing is hard-deleted: money rows are cancelled/reversed, people and groups archived, each with **reason, who, when**.

Legend: **have** = exists and kept, **change** = exists, needs work, **new** = does not exist.

## 1. Entities

| Entity | Status | Notes |
|---|---|---|
| Lead | have | Stages today are 9; V2 has 5 + Rad etdi + Keyinroq (see mapping §3). Add `desired_weekdays smallint[]`, `desired_time_of_day`, `level`. Every person starts as a Lead — `POST /students` direct creation to be removed in Phase 3 (kept for Excel import only, Phase 8). |
| Student | change | Add `archived_at/by/reason`. Created only via convert (or import). Never listed if only a trial. |
| Teacher | have | `salary_percent` kept. Add `archived_*` reason fields. |
| Subject | have | Add `levels` (list or table) for the course finder. |
| Group | change | Add `level`, `start_date`, `status` (active/paused/archived with reason), `room_id`, `salary_percent` (nullable per-group override). Weekdays/time stay in `group_schedules` (weekly slots) — query them for the "weekdays[], start/end" view. Remove per-group `due_day` in favour of a global billing day (§4). |
| Room | new | `rooms(id, name, capacity, archived_at)`; `group_schedules.room` text becomes `room_id`; clash check on room already exists on the text value. |
| Enrollment | have | `joined_at` → V2 `start date`; `ended_at` nullable; discount kept; `status` active/withdrawn kept. Withdrawing no longer deletes charges. |
| Charge | new table | Split out of `transactions`: `charges(id, enrollment_id, period_month date, amount, base_fee, discount_applied, is_prorated, status active/cancelled, cancelled_at/by/reason, created_at)`; **unique (enrollment_id, period_month)** among non-cancelled. |
| Payment | new table | `payments(id, student_id, enrollment_id null, amount, method, received_by, received_at, receipt_no, note, status valid/cancelled, cancelled_at/by/reason)`. Cancelling inserts a **reversal row** (`kind='reversal'`, `reverses_id`) and marks the original cancelled — never a delete. |
| PaymentAllocation | new | `payment_allocations(id, payment_id, charge_id, amount, created_at)`. A reversal creates negative allocations dated at the cancel time. |
| TrialVisit | have | Today `trial_bookings` + `trial_sessions` (kinds dedicated/group_lesson). Equivalent to TrialVisit; no rename. Group-lesson trials already show on that lesson's attendance list as guests; add the "sinov" chip. No charge, no debt, never in O'quvchilar. |
| Attendance | have | `attendance` per (lesson, enrollment); trial guests via bookings. |
| SalaryRun | new | `salary_runs(id, teacher_id, month, status open/closed, percent_snapshot, closed_at/by)` + `salary_run_lines` (per student/payment allocation snapshot). Closing freezes the numbers. |
| SalaryPayout | new | `salary_payouts(id, teacher_id, month, amount, paid_at, paid_by, method, voided_*)`. Existing salary `expenses` rows are migrated into this and the expense rows kept as the cash-out record (§5). |
| User | have | roles owner/admin; **teacher** role added in Phase 8 (needs a `users.role` check change — `users` is owned by `postgres` in production, so this goes through a one-off superuser step, never a normal migration). |
| AuditLog | new | `audit_log(id, at, user_id, entity, entity_id, action, reason, before jsonb, after jsonb)`. Written by the domain layer on every cancel/archive/price/percent/discount change. |

## 2. Money domain layer

All money rules in **one module**: `server/app/money/` (pure functions: proration, allocation, balance, debt age, salary) plus thin SQL for loading rows. Widgets and routes never compute money. Dart code shows what the server returns (the client FIFO calculator is retired in Phase 4).

- **Balance(student)** = Σ valid payments − Σ active charges, computed on read, never stored. Negative = debt. Overpayment = credit that is auto-allocated to the next charge when it is created.
- **Allocation:** a payment goes to that student's **oldest unpaid active charge first**, across enrollments, ordered by period then id. Remainder becomes credit (unallocated amount). Cancelling a payment reverses its allocations and re-flows nothing silently: the freed charges become unpaid again; a later payment is allocated normally.
- **Debt age:** days since the oldest unpaid charge's due date → buckets 0–7, 8–30, 30+.
- **Charge generation:** per active enrollment, for each month on the billing day (global setting, default 1). Idempotent (unique enrollment+month). Enrollments starting mid-month get a first prorated charge; the generator never back-charges months before `start date`.
- **Proration (default):** `round_half_up(fee × remaining_days / days_in_month)` where `remaining_days` counts the start date through the end of the month. Setting `first_month = full` switches to the full fee.
- **Discount:** applied at charge creation; the charge stores `base_fee` and the discount used so every amount can be explained later.
- **Salary(month M, teacher T)** = Σ allocations where charge's group is taught by T **at the allocation's payment time**, payment valid, received in M (center time), non-trial — times the percent (group override, else teacher percent), round half up per line then summed. Cancelled payments subtract in the month they are cancelled. Late payments count when received. Unpaid study adds nothing.
- **Oyni yopish** writes the run snapshot (percent used, lines, total). Closed months are read from the snapshot only.

## 3. Lead stage mapping

| Today | V2 |
|---|---|
| new | Yangi |
| contacted | Bog'lanildi |
| trial_scheduled, trial_completed | Sinov darsi |
| decision_pending | To'lov kutilmoqda |
| enrolled | Guruhga qo'shildi |
| not_interested, unreachable | Rad etildi (reason required) |
| follow_up_later | Keyinroq |

The existing 9-stage column stays (the offline outbox and old builds depend on it); V2 stages are a **mapping in one function** used by the board, report and dashboard so all of them count the same way.

## 4. Settings (new `settings` table)

`billing_day` (1), `first_month_mode` (`prorated`), `timezone` (`Asia/Tashkent`), `trial_limit_per_person` (1; owner may override). Owner-only edit, every change audited.

## 5. Migration plan (existing data → new model)

Rules: back up first (`pg_dump -Fc`), run on a restored copy with production ownership, **never ALTER `users`**, every migration has a rollback, existing endpoints keep working during the move.

1. **0012 settings + audit_log + rooms** (additive).
2. **0013 charges/payments/allocations** (additive). Backfill:
   - each `transactions` charge → `charges` (`period_month` = first day of `due_date`; if two charges fall in one month for an enrollment because `due_day` ≠ 1, the first prorated one keeps the month and the report lists collisions *before* running);
   - the 1 payment → `payments` + allocation to the oldest charge;
   - `transactions` stays as a read-only legacy table until Phase 4 retires its writers; routes switch to the domain layer first.
3. **0014 groups/lead fields** (level, start_date, status, room_id, salary_percent override, desired weekdays/time). All nullable first.
4. **0015 salary runs/payouts** (additive); salary `expenses` rows copied to `salary_payouts` (expenses stay for cash-flow).
5. Remove the withdraw-deletes-charges behaviour in the same release as step 2: withdrawing marks future charges cancelled with reason `withdrawn`.
6. Dev-only seed command (`python -m app.dev_seed`) refuses to run unless `APP_ENV=dev`; the test data currently in production is removed in Phase 8 after an owner-approved backup (nothing is deleted before then).

Each step is tested on a restored copy with production ownership, per the notes from the 0009 incident.

## 5b. Phase 1 status (built)

Migrations `0012_settings_audit`, `0013_money_core` (with backfill and the `charge_balances` / `enrollment_balances` / `student_balances` views), `0014_salary`. Rules in `server/app/money/rules.py` (pure), everything stored in `server/app/money/service.py`. Routes call the service; no money maths is left in routes or widgets. `transactions` stays as a read-only legacy table.

Rehearsed on a restored copy of production (real table owners, run as the app role): charges 30 349 521 so'm before and after, the one payment (248 387) fully allocated, debt 30 101 134 across 124 enrollments before and after. 27 enrollments had two charges in one month (the prorated first charge plus the old per-group due day); those were merged into one charge each, amounts added, and logged in `audit_log` as `migrated_merge`. Not deployed yet.

Deliberately not done in Phase 1: rooms, group `level`/`start_date`/`status`, lead desired weekdays, subject levels (they belong to the phases that use them: 3 and 5); the `users` role for teachers (Phase 8); the Flutter screens.

## 6. Assumptions (defaults used until you answer)

1. A trial is free; **one trial per person**, a second only by the owner.
2. First month is **prorated** over the remaining calendar days, with a setting for a full month.
3. Teacher percent is **per teacher, with an optional per-group override**; never hard-coded.
4. A multi-month payment counts in **the month it was received**.
5. Substitute teachers are ignored for now.
6. One global billing day (default the 1st); per-group `due_day` is retired.
7. Remaining calendar days **include** the start date.
8. Percent shares are rounded half up per line, then summed.
9. Overpayment (credit) is per student and allocated automatically to the next charge.
10. Cancelling a payment never changes already-closed salary months; it reduces the month in which it is cancelled.
11. A student in two groups with different teachers: each allocation is attributed to the teacher of the charge's group.
12. A new Teacher role (Phase 8) can only see their own groups, attendance and, if the owner allows it, their salary.
13. Existing 9 lead stages are kept internally; V2's 5 + Rad etildi + Keyinroq is a display mapping (§3).
14. Rooms become a table in Phase 5; until then room clashes use the existing text.
16. Salary counts allocations, not raw payments: money a student paid in advance (credit) becomes a teacher's pay when it is applied to a charge, in the month the payment was received. If that month is already closed, it counts in the next open month. A payment with nothing to pay yet earns the teacher nothing yet.
17. A closed month ("Oyni yopish") freezes every teacher's lines and totals. Payouts are still recorded against it. A cancelled payment from a closed month reduces the next open month.
18. Payment `method` is required by the service; older app builds that send none are recorded as cash.
19. The legacy API keeps its sign (`balance` > 0 = owed, per enrollment); the new money layer returns `balance = payments - charges` (negative = debt) per student. Old endpoints are retired as the new screens land.
20. A student who joins and leaves on the same day owes nothing (their first charge is cancelled, with a reason).
21. The old per-group `due_day` is ignored; the global `billing_day` (1-28, default 1) decides. The column stays until the group screens change in Phase 5.
22. A salary payout writes both a `salary_payouts` row and an `expenses` row (the cash that left), together; voiding voids both.
15. `docs/design/` screenshots are missing; UI assumptions come from the written brief only.

## 7. Open questions

1. **Screenshots:** `docs/design/` does not exist. Please add the V2 screenshots before Phase 2.
2. **Trial limit:** one free trial per person, second only by the owner — confirm?
3. **First month:** prorated by remaining calendar days (default) or full month by default?
4. **Teacher percent:** per teacher with optional per-group override — confirm? Is 30% a typical number, or does it differ a lot?
5. **Multi-month payments:** counted in the month received (default). Confirm.
6. **Billing day:** one global day (the 1st) instead of each group's own due day. Is that right for you, or do some groups bill on other days?
7. **Existing test data:** may I remove the 126 test students/charges in Phase 8 (after a backup), or do you want them kept until the pilot?
8. **Teacher login:** should teachers see only their own groups/attendance (default), and may they see their own salary?
