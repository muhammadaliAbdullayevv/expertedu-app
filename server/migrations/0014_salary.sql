-- Teacher salary: an optional percent per group, month closings that
-- freeze what was earned, and payouts.

alter table groups add column salary_percent numeric(5, 2)
  check (salary_percent is null or salary_percent between 0 and 100);

-- A closed month ("Oyni yopish"): never recomputed, whatever changes later.
create table salary_months (
  month date primary key check (extract(day from month) = 1),
  closed_at timestamptz not null default now(),
  closed_by bigint references users(id)
);

-- One teacher's frozen result for a closed month.
create table salary_runs (
  id bigserial primary key,
  month date not null references salary_months(month),
  teacher_id bigint not null references teachers(id),
  collected bigint not null,
  earned bigint not null,
  constraint uq_salary_runs unique (month, teacher_id)
);

-- Frozen per-student lines, with the percent that was used.
create table salary_run_lines (
  id bigserial primary key,
  run_id bigint not null references salary_runs(id),
  student_id bigint references students(id),
  student_name text not null,
  group_id bigint references groups(id),
  group_name text not null,
  collected bigint not null,
  percent numeric(5, 2),
  share bigint not null
);
create index idx_salary_run_lines_run on salary_run_lines (run_id);

-- Money paid out to a teacher for a month. Each payout also has its
-- expenses row (the cash that left), created and voided with it.
create table salary_payouts (
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
create index idx_salary_payouts_month on salary_payouts (month, teacher_id) where voided_at is null;

-- Payouts already recorded as salary expenses.
insert into salary_payouts (teacher_id, month, amount, paid_on, method, note, expense_id, paid_by, created_at, voided_at, voided_by, void_reason)
select teacher_id, salary_month, amount, spent_on, method, note, id, created_by, created_at, voided_at, voided_by, void_reason
from expenses where category = 'salary';
