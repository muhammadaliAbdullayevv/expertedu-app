-- Expert Edu Center backend schema.
-- Single-tenant: one deployment == one education center, no shop/org
-- scoping. Only owner/admin accounts exist -- no teacher/student login.
-- Apply with: psql "$DATABASE_URL" -f schema.sql

create table if not exists users (
  id bigserial primary key,
  phone text not null unique,
  password_hash text not null,
  full_name text not null,
  role text not null check (role in ('owner','admin')),
  token_version int not null default 0,
  is_active boolean not null default true,
  failed_login_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

-- When each account last signed in (0009). Not a users column: in
-- production users belongs to the postgres superuser.
create table if not exists staff_logins (
  user_id bigint primary key references users(id),
  last_login_at timestamptz not null
);

-- A subject (e.g. "Ingliz tili") can have several groups under it (e.g.
-- Beginner/Intermediate cohorts) -- the home screen browses subjects
-- first, then that subject's groups, then a group's own roster.
create table if not exists subjects (
  id bigserial primary key,
  name text not null unique,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

create table if not exists teachers (
  id bigserial primary key,
  full_name text not null,
  phone text,
  note text,
  is_active boolean not null default true,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  -- Share of their groups' payments, in percent (owner only; 0011).
  salary_percent numeric(5, 2) check (salary_percent is null or salary_percent between 0 and 100),
  -- How they are paid: 'percent' of payments (salary_percent) or a 'fixed'
  -- monthly amount; a group's own rule wins (0014).
  salary_method text check (salary_method in ('percent', 'fixed')),
  salary_fixed bigint check (salary_fixed is null or salary_fixed >= 0)
);

create table if not exists groups (
  id bigserial primary key,
  subject_id bigint references subjects(id),
  name text not null,
  teacher_id bigint references teachers(id),
  fee_amount bigint not null,
  capacity int check (capacity > 0),
  is_active boolean not null default true,
  note text,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  -- Billing is a per-group rule (0015): everyone on billing_day, or each
  -- enrollment on its own start day.
  billing_mode text not null default 'fixed_day' check (billing_mode in ('fixed_day', 'student_anniversary')),
  billing_day smallint check (billing_day between 1 and 28),
  prorate_first_period boolean not null default true,
  -- This group's own pay rule; null salary_method = the teacher's (0014).
  salary_method text check (salary_method in ('percent', 'fixed')),
  salary_percent numeric(5, 2) check (salary_percent is null or salary_percent between 0 and 100),
  salary_fixed bigint check (salary_fixed is null or salary_fixed >= 0),
  constraint groups_billing_day_for_mode check ((billing_mode = 'fixed_day') = (billing_day is not null)),
  constraint groups_salary_rule check (
    salary_method is null
    or (salary_method = 'percent' and salary_percent is not null)
    or (salary_method = 'fixed' and salary_fixed is not null)
  )
);

create table if not exists students (
  id bigserial primary key,
  full_name text not null,
  phone text not null,
  telegram_username text,
  note text,
  parent_phone text,
  heard_from text check (heard_from in ('instagram','telegram','referral','walk_in','other')),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

-- A student can be enrolled in multiple groups at once, each its own
-- independent billing relationship. Rejoining after a withdrawal creates a
-- brand-new row rather than reactivating the old one, so proration-on-join
-- applies correctly again -- see routes/enrollments.py.
create table if not exists enrollments (
  id bigserial primary key,
  student_id bigint not null references students(id),
  group_id bigint not null references groups(id),
  joined_at date not null,
  status text not null check (status in ('active','withdrawn')) default 'active',
  ended_at date,
  discount_kind text check (discount_kind in ('amount','percent')),
  discount_value bigint check (discount_value >= 0),
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  constraint enrollments_discount_pair check ((discount_kind is null) = (discount_value is null)),
  constraint enrollments_discount_percent_max check (discount_kind is distinct from 'percent' or discount_value <= 100)
);
create index if not exists idx_enrollments_group_active on enrollments(group_id) where status = 'active';
create unique index if not exists uq_students_phone on students (phone);
create index if not exists idx_enrollments_student on enrollments(student_id);

-- LEGACY (kept as history since 0013): money now lives in charges, payments
-- and payment_allocations. Nothing writes here any more.
-- One table for both charges and payments (not two) -- see billing.py.
-- Billing is "in advance": due_date always equals period_start. The
-- partial unique index makes double-charging the same due date
-- structurally impossible, not just avoided by careful job logic.
create table if not exists transactions (
  id bigserial primary key,
  enrollment_id bigint not null references enrollments(id),
  kind text not null check (kind in ('charge','payment')),
  amount bigint not null,
  period_start date,
  due_date date,
  is_prorated boolean not null default false,
  source text not null default 'auto_recurring' check (source in ('auto_recurring','manual')),
  note text,
  method text check (method in ('cash','card','click_payme')),
  occurred_at timestamptz not null default now(),
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  -- Payments: the group's teacher when paid -- set by the trigger below.
  teacher_id bigint references teachers(id)
);
create unique index if not exists uq_charge_enrollment_due_date
  on transactions (enrollment_id, due_date) where kind = 'charge';
create index if not exists idx_transactions_enrollment on transactions(enrollment_id);
create index if not exists idx_transactions_payment_teacher on transactions (teacher_id, occurred_at) where kind = 'payment';
create or replace function transactions_payment_teacher() returns trigger language plpgsql as $$
begin
  if new.kind = 'payment' and new.teacher_id is null then
    select g.teacher_id into new.teacher_id
    from enrollments e join groups g on g.id = e.group_id
    where e.id = new.enrollment_id;
  end if;
  return new;
end;
$$;
drop trigger if exists transactions_payment_teacher on transactions;
create trigger transactions_payment_teacher
  before insert on transactions
  for each row execute function transactions_payment_teacher();


-- A lead: someone who called or walked in about a course -- not a student
-- and never in a group. Only POST /leads/{id}/enroll turns one into an
-- enrollment, which is linked back here so the lead's whole history stays
-- with the student. See migrations/0008_admissions.sql.
create table if not exists leads (
  id bigserial primary key,
  client_id uuid not null default gen_random_uuid(),
  full_name text not null,
  phone text not null,
  parent_phone text,
  note text,
  subject_id bigint references subjects(id),
  preferred_trial_date date,
  source text check (source in ('instagram','telegram','referral','walk_in','other')),
  stage text not null default 'new',
  lost_reason text,
  assigned_to bigint references users(id),
  student_id bigint references students(id),
  enrollment_id bigint references enrollments(id),
  enrolled_at timestamptz,
  closed_at timestamptz,
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint leads_stage_check check (stage in (
    'new','contacted','trial_scheduled','trial_completed','decision_pending','follow_up_later',
    'enrolled','not_interested','unreachable'
  )),
  constraint leads_enrolled_has_enrollment check ((stage = 'enrolled') = (enrollment_id is not null)),
  constraint leads_phone_format check (phone ~ '^998[0-9]{9}$'),
  constraint uq_leads_client_id unique (client_id),
  constraint uq_leads_enrollment unique (enrollment_id)
);
-- At most one open lead per phone per course.
create unique index if not exists uq_leads_open_phone_subject on leads (phone, coalesce(subject_id, 0))
  where stage not in ('enrolled','not_interested','unreachable');
create index if not exists idx_leads_stage on leads (stage);
create index if not exists idx_leads_phone on leads (phone);
create index if not exists idx_leads_created_at on leads (created_at);
create index if not exists idx_leads_student on leads (student_id) where student_id is not null;

-- A trial lesson slot: a dedicated trial lesson, or guest seats at one of
-- a regular group's lessons. Guests are trial_bookings, never enrollments.
create table if not exists trial_sessions (
  id bigserial primary key,
  kind text not null check (kind in ('dedicated','group_lesson')),
  subject_id bigint references subjects(id),
  group_id bigint references groups(id),
  teacher_id bigint references teachers(id),
  room text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity int not null check (capacity > 0),
  status text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  note text,
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trial_sessions_time_order check (ends_at > starts_at),
  constraint trial_sessions_group_kind check ((kind = 'group_lesson') = (group_id is not null))
);
create index if not exists idx_trial_sessions_starts_at on trial_sessions (starts_at);
create index if not exists idx_trial_sessions_teacher on trial_sessions (teacher_id, starts_at) where status = 'scheduled';

-- One lead's seat in one session, with its attendance and the teacher's
-- feedback -- separate from regular groups entirely.
create table if not exists trial_bookings (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  session_id bigint not null references trial_sessions(id) on delete restrict,
  status text not null default 'scheduled'
    check (status in ('scheduled','attended','absent','cancelled','rescheduled')),
  rescheduled_from_id bigint unique references trial_bookings(id),
  cancel_reason text,
  attendance_marked_at timestamptz,
  attendance_marked_by bigint references users(id),
  feedback text,
  recommended_level text,
  feedback_at timestamptz,
  feedback_by bigint references users(id),
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trial_bookings_feedback_attended check (feedback is null or status = 'attended')
);
create unique index if not exists uq_trial_bookings_lead_scheduled on trial_bookings (lead_id) where status = 'scheduled';
create index if not exists idx_trial_bookings_session on trial_bookings (session_id);
create index if not exists idx_trial_bookings_lead on trial_bookings (lead_id);

create table if not exists follow_up_tasks (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  title text not null,
  due_at timestamptz not null,
  assigned_to bigint references users(id),
  status text not null default 'open' check (status in ('open','done','cancelled')),
  completed_at timestamptz,
  completed_by bigint references users(id),
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  constraint follow_up_tasks_completion check ((status = 'open') = (completed_at is null))
);
create index if not exists idx_follow_up_tasks_open_due on follow_up_tasks (due_at) where status = 'open';
create index if not exists idx_follow_up_tasks_lead on follow_up_tasks (lead_id);

-- The lead's timeline and audit trail: logged calls and notes, plus a
-- 'system' row for every change the server makes. Never updated or deleted.
create table if not exists lead_interactions (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  kind text not null check (kind in ('call_in','call_out','sms','telegram','visit','note','system')),
  body text not null,
  old_stage text,
  new_stage text,
  booking_id bigint references trial_bookings(id),
  task_id bigint references follow_up_tasks(id),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_lead_interactions_lead on lead_interactions (lead_id, created_at);

create or replace function lead_interactions_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'lead_interactions is append-only';
end;
$$;
drop trigger if exists lead_interactions_append_only on lead_interactions;
create trigger lead_interactions_append_only
  before update or delete on lead_interactions
  for each row execute function lead_interactions_append_only();

-- A write sent with an Idempotency-Key is done once; a retry gets the
-- stored response back. See app/idempotency.py.
create table if not exists idempotency_keys (
  key uuid primary key,
  user_id bigint not null references users(id),
  endpoint text not null,
  request_hash text not null,
  status_code int,
  response jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_idempotency_keys_created_at on idempotency_keys (created_at);

-- Lesson schedule and attendance -- see migrations/0010_schedule_attendance.sql.
-- The timetable is computed from group_schedules; a lessons row exists
-- only once attendance is marked, the lesson is cancelled, or it's extra.
create table if not exists group_schedules (
  id bigserial primary key,
  group_id bigint not null references groups(id) on delete cascade,
  -- ISO weekday: 1 = Monday ... 7 = Sunday.
  weekday smallint not null check (weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null,
  room text,
  created_at timestamptz not null default now(),
  constraint group_schedules_time_order check (ends_at > starts_at)
);
create index if not exists idx_group_schedules_group on group_schedules (group_id);
create index if not exists idx_group_schedules_weekday on group_schedules (weekday);

create table if not exists lessons (
  id bigserial primary key,
  group_id bigint not null references groups(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  room text,
  -- Who taught it: the group's teacher at the time, kept for history.
  teacher_id bigint references teachers(id),
  status text not null default 'active' check (status in ('active', 'cancelled')),
  cancel_reason text,
  -- Not one of the group's weekly slots: added by hand.
  is_extra boolean not null default false,
  note text,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lessons_time_order check (ends_at > starts_at),
  -- One lesson per group per start time -- marking attendance twice for
  -- the same lesson finds the same row.
  constraint uq_lessons_group_start unique (group_id, starts_at)
);
create index if not exists idx_lessons_starts_at on lessons (starts_at);

-- Regular students' attendance. (Trial guests' attendance stays on
-- trial_bookings -- separate by design.)
create table if not exists attendance (
  id bigserial primary key,
  lesson_id bigint not null references lessons(id) on delete restrict,
  enrollment_id bigint not null references enrollments(id),
  status text not null check (status in ('present', 'late', 'absent', 'excused')),
  note text,
  marked_by bigint references users(id),
  marked_at timestamptz not null default now(),
  constraint uq_attendance_lesson_enrollment unique (lesson_id, enrollment_id)
);
create index if not exists idx_attendance_enrollment on attendance (enrollment_id);

-- Money the center spends. Never deleted: a mistake is voided, with who,
-- when and why, and voided rows count nowhere.
create table if not exists expenses (
  id bigserial primary key,
  category text not null
    check (category in ('salary', 'rent', 'utilities', 'marketing', 'supplies', 'tax', 'other')),
  amount bigint not null check (amount > 0),
  spent_on date not null,
  note text,
  method text check (method in ('cash', 'card', 'click_payme')),
  -- Salary payouts: whose, and for which month (its first day).
  teacher_id bigint references teachers(id),
  salary_month date,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by bigint references users(id),
  void_reason text,
  constraint expenses_salary_fields check (
    (category = 'salary') = (teacher_id is not null and salary_month is not null)
  ),
  constraint expenses_salary_month_first check (salary_month is null or extract(day from salary_month) = 1)
);
create index if not exists idx_expenses_spent_on on expenses (spent_on) where voided_at is null;
create index if not exists idx_expenses_salary on expenses (teacher_id, salary_month) where category = 'salary' and voided_at is null;

create table if not exists sms_log (
  id bigserial primary key,
  enrollment_id bigint references enrollments(id),
  transaction_id bigint references transactions(id),
  phone text not null,
  message text not null,
  status text not null check (status in ('queued','sent','failed')),
  error text,
  created_at timestamptz not null default now()
);

-- ---- 0012: settings and audit log ----
-- Center-wide settings (one row) and the audit log. Phase 1 of the V2 money rework.

-- Missing row = these defaults (see app/money/service.py get_settings).
-- Billing is per group, not here (0015).
create table if not exists app_settings (
  id boolean primary key default true check (id),
  -- Free trial lessons one person may have; only the owner can allow more.
  trial_limit_per_person smallint not null default 1 check (trial_limit_per_person >= 1),
  updated_by bigint references users(id),
  updated_at timestamptz not null default now()
);

-- Who did what, and why. Written by the domain layer on every cancel,
-- reversal, archive, month closing and settings or percent change. Never
-- updated or deleted.
create table if not exists audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  user_id bigint references users(id),
  entity text not null,
  entity_id bigint,
  action text not null,
  reason text,
  before jsonb,
  after jsonb
);
create index if not exists idx_audit_log_entity on audit_log (entity, entity_id, at);

create or replace function audit_log_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end;
$$;
create trigger audit_log_append_only
  before update or delete on audit_log
  for each row execute function audit_log_append_only();

-- ---- 0013: money core (charges, payments, allocations) ----
-- Money core: charges, payments and the allocations tying them together.
-- Replaces the single `transactions` table (kept, read-only, as history).

create table if not exists charges (
  id bigserial primary key,
  enrollment_id bigint not null references enrollments(id),
  -- The billing period this charge pays for: [period_start, period_end).
  -- Charged on its first day, so due_date is period_start.
  period_start date not null,
  period_end date not null,
  due_date date not null,
  amount bigint not null check (amount >= 0),
  -- What the amount was made of: the group's fee at the time, less the
  -- enrollment's discount (a prorated first period is smaller than both).
  base_fee bigint not null check (base_fee >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  is_prorated boolean not null default false,
  note text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  cancelled_at timestamptz,
  cancelled_by bigint references users(id),
  cancel_reason text,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  constraint charges_period_order check (period_end > period_start),
  constraint charges_due_on_start check (due_date = period_start),
  constraint charges_cancel_fields check (
    (status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)
  )
);
-- One live charge per enrollment per billing period: generating twice is harmless.
create unique index if not exists uq_charges_enrollment_period on charges (enrollment_id, period_start) where status = 'active';
create index if not exists idx_charges_enrollment on charges (enrollment_id);

-- A payment, or the reversal that cancels one. Cancelling never deletes:
-- the payment is marked cancelled and a 'reversal' row records the money
-- going back out, on the day it happened.
create table if not exists payments (
  id bigserial primary key,
  student_id bigint not null references students(id),
  -- Which group it was handed over for (informational; allocation is per student).
  enrollment_id bigint references enrollments(id),
  kind text not null default 'payment' check (kind in ('payment', 'reversal')),
  amount bigint not null check (amount > 0),
  -- Null only for payments recorded before methods existed.
  method text check (method in ('cash', 'card', 'click_payme')),
  received_by bigint references users(id),
  received_at timestamptz not null default now(),
  receipt_no text,
  note text,
  status text not null default 'valid' check (status in ('valid', 'cancelled')),
  -- On a reversal: the payment it cancels, and why.
  reverses_id bigint references payments(id),
  reason text,
  cancelled_at timestamptz,
  cancelled_by bigint references users(id),
  cancel_reason text,
  created_at timestamptz not null default now(),
  constraint payments_receipt_unique unique (receipt_no),
  constraint payments_reverses_once unique (reverses_id),
  constraint payments_reversal_fields check ((kind = 'reversal') = (reverses_id is not null)),
  constraint payments_cancel_fields check (
    (status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)
  ),
  constraint payments_reversal_valid check (kind = 'payment' or (status = 'valid' and reason is not null))
);
create index if not exists idx_payments_student on payments (student_id, received_at);
create sequence if not exists payment_receipt_seq;

-- Which part of which payment paid which charge. Signed and append-only:
-- cancelling a payment adds negative rows, it never edits old ones. The
-- teacher and group are the charge's at that moment, and counts_in_month
-- is the salary month the money belongs to (see money/service.py).
create table if not exists payment_allocations (
  id bigserial primary key,
  payment_id bigint not null references payments(id),
  charge_id bigint not null references charges(id),
  amount bigint not null check (amount <> 0),
  teacher_id bigint references teachers(id),
  group_id bigint references groups(id),
  counts_in_month date not null check (extract(day from counts_in_month) = 1),
  created_at timestamptz not null default now()
);
create index if not exists idx_allocations_payment on payment_allocations (payment_id);
create index if not exists idx_allocations_charge on payment_allocations (charge_id);
create index if not exists idx_allocations_salary on payment_allocations (counts_in_month, teacher_id);

-- Money is never deleted, and an allocation never edited.
create or replace function money_never_deleted() returns trigger language plpgsql as $$
begin
  raise exception '% rows are never deleted', tg_table_name;
end;
$$;
create or replace function allocations_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'payment_allocations is append-only';
end;
$$;
drop trigger if exists charges_never_deleted on charges;
create trigger charges_never_deleted before delete on charges
  for each row execute function money_never_deleted();
drop trigger if exists payments_never_deleted on payments;
create trigger payments_never_deleted before delete on payments
  for each row execute function money_never_deleted();
drop trigger if exists payment_allocations_append_only on payment_allocations;
create trigger payment_allocations_append_only before update or delete on payment_allocations
  for each row execute function allocations_append_only();

-- One definition of "how much is owed", used by every screen and report.
-- What each charge has been paid so far, and what's left of it.
create or replace view charge_balances as
select c.id as charge_id, c.enrollment_id, e.student_id, e.group_id, c.period_start, c.period_end, c.due_date,
       c.status, c.amount,
       coalesce(a.paid, 0)::bigint as paid,
       (c.amount - coalesce(a.paid, 0))::bigint as owed
from charges c
join enrollments e on e.id = c.enrollment_id
left join (select charge_id, sum(amount) as paid from payment_allocations group by charge_id) a on a.charge_id = c.id;

-- Per enrollment: active charges, what was allocated to them, what's owed.
create or replace view enrollment_balances as
select e.id as enrollment_id, e.student_id,
       coalesce(sum(cb.amount) filter (where cb.status = 'active'), 0)::bigint as charged,
       coalesce(sum(cb.paid) filter (where cb.status = 'active'), 0)::bigint as paid,
       (coalesce(sum(cb.amount) filter (where cb.status = 'active'), 0)
         - coalesce(sum(cb.paid) filter (where cb.status = 'active'), 0))::bigint as owed
from enrollments e
left join charge_balances cb on cb.enrollment_id = e.id
group by e.id;

-- Per student: valid payments minus active charges. Negative = debt,
-- positive = credit. Computed, never stored.
create or replace view student_balances as
select s.id as student_id,
       coalesce(p.total, 0)::bigint as paid,
       coalesce(c.total, 0)::bigint as charged,
       (coalesce(p.total, 0) - coalesce(c.total, 0))::bigint as balance
from students s
left join (
  select student_id, sum(amount) as total from payments
  where kind = 'payment' and status = 'valid' group by student_id
) p on p.student_id = s.id
left join (
  select e.student_id, sum(ch.amount) as total
  from charges ch join enrollments e on e.id = ch.enrollment_id
  where ch.status = 'active' group by e.student_id
) c on c.student_id = s.id;

-- ---- 0014: salary rules, runs and payouts ----
-- Teacher salary: an optional percent per group, month closings that
-- freeze what was earned, and payouts.

-- A closed month ("Oyni yopish"): never recomputed, whatever changes later.
create table if not exists salary_months (
  month date primary key check (extract(day from month) = 1),
  closed_at timestamptz not null default now(),
  closed_by bigint references users(id)
);

-- One teacher's frozen result for a closed month.
create table if not exists salary_runs (
  id bigserial primary key,
  month date not null references salary_months(month),
  teacher_id bigint not null references teachers(id),
  collected bigint not null,
  earned bigint not null,
  constraint uq_salary_runs unique (month, teacher_id)
);

-- Frozen per-student lines, with the percent that was used.
create table if not exists salary_run_lines (
  id bigserial primary key,
  run_id bigint not null references salary_runs(id),
  student_id bigint references students(id),
  student_name text not null,
  group_id bigint references groups(id),
  group_name text not null,
  collected bigint not null,
  percent numeric(5, 2),
  -- 'fixed' lines are the fixed monthly amount, not a share of payments.
  method text not null default 'percent' check (method in ('percent', 'fixed')),
  share bigint not null
);
create index if not exists idx_salary_run_lines_run on salary_run_lines (run_id);

-- Money paid out to a teacher for a month. Each payout also has its
-- expenses row (the cash that left), created and voided with it.
create table if not exists salary_payouts (
  id bigserial primary key,
  teacher_id bigint not null references teachers(id),
  month date not null check (extract(day from month) = 1),
  amount bigint not null check (amount > 0),
  paid_on date not null,
  method text check (method in ('cash', 'card', 'click_payme')),
  note text,
  expense_id bigint not null unique references expenses(id),
  paid_by bigint references users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by bigint references users(id),
  void_reason text,
  constraint salary_payouts_void_fields check ((voided_at is null) = (void_reason is null))
);
create index if not exists idx_salary_payouts_month on salary_payouts (month, teacher_id) where voided_at is null;

