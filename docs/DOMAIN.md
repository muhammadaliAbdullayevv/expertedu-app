# Domain model and migration plan

Adapts the V2 model to the real backend (FastAPI + Postgres). Money is **integer so'm**; time zone **Asia/Tashkent** (`clock.today()` and `at time zone` in SQL). Nothing is hard-deleted: money rows are cancelled/reversed, people and groups archived, each with **reason, who, when**.

Legend: **have** = exists and kept, **change** = exists, needs work, **new** = does not exist.

## 1. Entities

| Entity | Status | Notes |
|---|---|---|
| Lead | have | Stages today are 9; V2 has 5 + Rad etdi + Keyinroq (see mapping §3). Add `desired_weekdays smallint[]`, `desired_time_of_day`, `level`. Every person starts as a Lead — `POST /students` direct creation to be removed in Phase 3 (kept for Excel import only, Phase 8). |
| Student | change | Add `archived_at/by/reason`. Created only via convert (or import). Never listed if only a trial. |
| Teacher | have | Pay rule (§2b): `salary_method` (`percent` / `fixed` / none) with `salary_percent` or `salary_fixed`. Add `archived_*` reason fields later. |
| Subject | have | Add `levels` (list or table) for the course finder. |
| Group | change | **Built (0015):** `billing_mode` (`fixed_day` / `student_anniversary`), `billing_day` (1-28, fixed_day only), `prorate_first_period`; own pay rule `salary_method` / `salary_percent` / `salary_fixed` (0014, wins over the teacher's). **Still to add:** `level`, `start_date`, `status` (active/paused/archived with reason), `room_id`. Weekdays/time stay in `group_schedules`. The old `due_day` is gone. |
| Room | new | `rooms(id, name, capacity, archived_at)`; `group_schedules.room` text becomes `room_id`; clash check on room already exists on the text value. |
| Enrollment | have | `joined_at` → V2 `start date`; `ended_at` nullable; discount kept; `status` active/withdrawn kept. Withdrawing no longer deletes charges. |
| Charge | **built** | `charges(id, enrollment_id, period_start, period_end, due_date = period_start, amount, base_fee, discount_amount, is_prorated, status active/cancelled, cancelled_at/by/reason)`; **unique (enrollment_id, period_start)** among active charges. One charge per enrollment per billing period. |
| Payment | new table | `payments(id, student_id, enrollment_id null, amount, method, received_by, received_at, receipt_no, note, status valid/cancelled, cancelled_at/by/reason)`. Cancelling inserts a **reversal row** (`kind='reversal'`, `reverses_id`) and marks the original cancelled — never a delete. |
| PaymentAllocation | new | `payment_allocations(id, payment_id, charge_id, amount, created_at)`. A reversal creates negative allocations dated at the cancel time. |
| TrialVisit | have | Today `trial_bookings` + `trial_sessions` (kinds dedicated/group_lesson). Equivalent to TrialVisit; no rename. Group-lesson trials already show on that lesson's attendance list as guests; add the "sinov" chip. No charge, no debt, never in O'quvchilar. |
| Attendance | have | `attendance` per (lesson, enrollment); trial guests via bookings. |
| SalaryRun | **built** | `salary_months` (a closed month) + `salary_runs` per teacher + `salary_run_lines` (per student for percent, one line for a fixed amount; each keeps the percent or method it used). Closing freezes the numbers. |
| SalaryPayout | **built** | `salary_payouts(id, teacher_id, month, amount, paid_on, method, paid_by, voided_*)`, each with its `expenses` row (the cash that left). |
| User | have | roles owner/admin; **teacher** role added in Phase 8 (needs a `users.role` check change — `users` is owned by `postgres` in production, so this goes through a one-off superuser step, never a normal migration). |
| AuditLog | new | `audit_log(id, at, user_id, entity, entity_id, action, reason, before jsonb, after jsonb)`. Written by the domain layer on every cancel/archive/price/percent/discount change. |

## 2. Money domain layer

All money rules in **one module**: `server/app/money/` (`rules.py` pure functions; `service.py` everything stored). Widgets and routes never compute money. Dart code shows what the server returns (the client FIFO calculator is retired in Phase 4).

- **Balance(student)** = Σ valid payments − Σ active charges, computed on read (views `charge_balances`, `enrollment_balances`, `student_balances`), never stored. Negative = debt. Overpayment = credit, auto-allocated to the next charge when it is created.
- **Allocation:** a payment goes to that student's **oldest unpaid active charge first** (by period start), across enrollments and groups. Remainder is credit. Cancelling a payment reverses its allocations; a cancelled charge returns what it had received as credit.
- **Debt age:** days since the oldest unpaid charge's due date → buckets 0–7, 8–30, 30+.
- **Discount:** applied at charge creation; the charge stores `base_fee` and `discount_amount` so every amount can be explained later.

### 2a. Billing is a per-group rule

Charges are generated per active enrollment, **idempotent per enrollment + billing period**, in advance (a period is charged on its first day). A period is `[period_start, period_end)`.

| `billing_mode` | Rule |
|---|---|
| `fixed_day` | Everyone in the group pays on `billing_day` (1-28) each month. A student who joins between billing days gets a **first period from the start date to the next billing day**, charged `fee × days_to_next_billing_day / days_in_that_cycle` (the cycle is previous billing day → next billing day), rounded half up — when the group's `prorate_first_period` is on (default). Off: the first charge is the full fee, for the same period. Joining exactly on a billing day is a full period. |
| `student_anniversary` | Each enrollment bills on its own start day every month: join on the 14th → due on the 14th. **No proration**, full fee each period. A start day the month lacks (31st) falls on that month's last day, and the day is not lost: Jan 31 → Feb 28/29 → Mar 31 → Apr 30. |

- **`next_due_date`** is exposed per enrollment (`/enrollments/by-student/{id}`, group roster): the first period start from today (today counts), none once the student has left. The dashboard's "to'lov kuni bugun" counts enrollments whose next due date is today.
- **Leaving:** `ended_at` stops billing: periods starting on or after that day are cancelled with a reason (so leaving the day you started owes nothing); the period they were in stays owed; old charges stay. Nothing is deleted.
- **A group's billing rule is locked once it has charges** (409): changing the grid would re-bill old periods. Switching will need an explicit "from this date" tool; the generator also never bills a period that starts before the end of the last charge.
- Per-student choice at enrollment (`first_month` = `full`/`prorated`) still overrides the group's switch for that one student.

### 2b. Teacher pay

Never hard-coded. **Per teacher, with an optional per-group override — the group's rule wins** for that group's money.

| Method | Meaning |
|---|---|
| `percent` | `percent` of the payment allocations that count in the month (rounded half up per student line, then summed). Cash basis: unpaid study adds nothing; a late payment counts when received; a cancelled payment subtracts in the month it is cancelled; advance payments count in the month received, once applied to a charge; trials never create payments. |
| `fixed` | A fixed monthly amount, whatever was paid. A **teacher's** fixed amount is paid once a month however many groups they teach; a **group's** fixed amount is paid to that group's teacher for that group. |

A teacher on a fixed amount whose group has its own percent earns both (the percent of that group's payments plus the fixed amount). A group on a fixed amount earns no percent on its own payments; the teacher's rule covers the teacher's other groups.

Fixed pay accrues for the current and past months from the month the teacher (or group) existed, never for future months, and not for inactive teachers/groups. **Oyni yopish** snapshots every line (percent lines, fixed lines, and the rule each used); closed months are read from the snapshot only, and money that would land in a closed month counts in the next open month.

### 2c. Who may do what

| | Owner | Admin |
|---|---|---|
| See Moliya, salary pages, payments, expenses | yes | yes |
| Take and cancel payments, record expenses | yes | yes |
| Record a salary payout — **only for a closed month, never above what is still owed** (for both roles) | yes | yes |
| **Void an expense or a salary payout** | yes | **no** |
| **Close a salary month** | yes | **no** |
| **Edit a teacher's or group's percent / fixed amount** | yes | **no** |
| **Manage users and roles** (Xodimlar) | yes | **no** |
| **Backups** | yes (server cron and the owner's PC) | no |
| Book a **second trial** for the same person | yes | no |

The owner/admin split is enforced on the server (`require_owner`), not only in the menu. Everything here is audit-logged: expenses and payouts (create, void), month closings, pay-rule changes, payment and charge cancellations, extra trials, settings.

A payout is checked under a per-teacher lock, so two payouts at once cannot both pass the balance check.

### 2d. Trials

A trial is free: **no charge, no debt**, and a trial person never appears in O'quvchilar. **One trial per person** (the same phone, across subjects); the limit is a setting (`app_settings.trial_limit_per_person`, default 1). Only the owner can book another, and it is written to the audit log (`extra_trial`). A trial that was cancelled, moved or missed does not use up the free one; moving a booking is not a new trial.

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

## 4. Settings

`app_settings` (one row, owner-only edit, audited): `trial_limit_per_person` (1). The time zone is `Asia/Tashkent` from server config. Billing and pay rules are per group / per teacher, not settings.

## 5. Migration plan (existing data → new model)

Rules: back up first (`pg_dump -Fc`), run on a restored copy with production ownership, **never ALTER `users`**, every migration has a rollback, existing endpoints keep working during the move. **None of 0012–0015 has been applied to production yet.** (Phase 1's 0013/0014 were rewritten in place for these rules — they had never left the dev machine.)

1. **0012** `app_settings` (trial limit) + append-only `audit_log`.
2. **0013** `charges` / `payments` / `payment_allocations` + views, with a backfill from `transactions`: each legacy charge becomes one charge whose period runs from its due date to the enrollment's next charge (or the group's next due day); payments get receipt numbers; allocations are laid end to end oldest first. `transactions` stays as a read-only legacy table.
3. **0014** teacher and group pay rules, month closings, run lines, payouts (existing salary expenses become payouts).
4. **0015** per-group billing: every existing group becomes `fixed_day` with its current due day as `billing_day` (29-31 would become 28); the `due_day` column is dropped.
5. Withdrawing cancels charges (with a reason) instead of deleting them — shipped with the same release.
6. Later: rooms, group level/start date/status, subject levels, lead preferences, the teacher role, and the dev-only seed command (`python -m app.dev_seed`, refuses to run unless `APP_ENV=dev`). The test data currently in production is removed in Phase 8 after an owner-approved backup.

### Rehearsal on a restored copy of production (real table owners, run as the app role)

All four migrations apply cleanly. **Production groups → new mode** (read before applying):

| Group | Active students | Mode | Billing day |
|---|---:|---|---:|
| Ingliz tili - Beginner | 14 | fixed_day | 5 |
| Ingliz tili - Intermediate | 11 | fixed_day | 5 |
| Matematika - 9-sinf | 15 | fixed_day | 10 |
| Fizika | 10 | fixed_day | 10 |
| Kimyo | 14 | fixed_day | 15 |
| Rus tili | 15 | fixed_day | 1 |
| Koreys tili | 10 | fixed_day | 20 |
| Dasturlash (Python) | 11 | fixed_day | 1 |
| Fransuz tili | 13 | fixed_day | 15 |
| Tarix | 12 | fixed_day | 25 |

No group is capped (all due days were ≤ 28) and none becomes `student_anniversary` — the old rule was already "fixed day with proration to the next due day", which is exactly `fixed_day`. Result: **all 126 students keep exactly the same balance** (total owed 30 101 134 so'm, 124 enrollments with debt, one payment of 248 387 fully allocated), and the new charge job would create **0** charges today.

## 6. Assumptions (defaults used until you answer)

1. Billing is per group (§2a); proration is `days to next billing day / days in that cycle`, half up, start day included.
2. A multi-month payment counts in **the month it was received** (once applied to charges — advance credit earns the teacher nothing until it pays a charge).
3. Substitute teachers are ignored for now.
4. Percent shares are rounded half up per student line, then summed.
5. Overpayment (credit) is per student and allocated automatically to the next charge.
6. A student in two groups with different teachers: each allocation is attributed to the teacher of the charge's group. Payments are allocated oldest charge first across both groups.
7. Cancelling a payment never changes a closed salary month; it reduces the next open month (or the month it is cancelled in).
8. A closed month freezes every line. Payouts are still recorded against it.
9. Payment `method` is required by the service; older app builds that send none are recorded as cash.
10. The legacy API keeps its sign (`balance` > 0 = owed, per enrollment); the money layer returns `balance = payments − charges` (negative = debt) per student.
11. A student who joins and leaves the same day owes nothing.
12. A salary payout writes a `salary_payouts` row and an `expenses` row together; voiding voids both.
13. The admin may record expenses and salary payouts; payouts need a closed month and stay within what is owed (also for the owner); voiding is owner-only.
14. Pay-rule and billing-rule edits are audited; the billing rule is locked once the group has charges.
15. Fixed salaries accrue per calendar month from the month the teacher/group was created; not for future months; not for inactive teachers/groups.
16. A fixed-day group cannot use the 29th–31st (billing day is capped at 28).
17. Existing 9 lead stages are kept internally; V2's names are a display mapping (§3).
18. Rooms become a table in Phase 5; until then room clashes use the existing text.
19. A new Teacher role (Phase 8) sees only their own groups, attendance and, if the owner allows it, their salary.
20. Phone/Android work is deferred until the owner says "build".

## 7. Open questions

1. **Existing test data:** may I remove the 126 test students/charges in Phase 8 (after a backup), or keep them until the pilot?
2. **Teacher login:** should teachers see only their own groups/attendance (default), and may they see their own salary?

Decided: no "change billing from date" tool for now (a group's billing rule stays locked once it has charges).
