create table groups (
  id bigserial primary key,
  name text not null,
  fee_amount bigint not null,
  due_day smallint not null check (due_day between 1 and 31),
  is_active boolean not null default true,
  note text,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

create table students (
  id bigserial primary key,
  full_name text not null,
  phone text not null,
  telegram_username text,
  note text,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

create table enrollments (
  id bigserial primary key,
  student_id bigint not null references students(id),
  group_id bigint not null references groups(id),
  joined_at date not null,
  status text not null check (status in ('active','withdrawn')) default 'active',
  ended_at date,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index idx_enrollments_group_active on enrollments(group_id) where status = 'active';
create index idx_enrollments_student on enrollments(student_id);

create table transactions (
  id bigserial primary key,
  enrollment_id bigint not null references enrollments(id),
  kind text not null check (kind in ('charge','payment')),
  amount bigint not null,
  period_start date,
  due_date date,
  is_prorated boolean not null default false,
  source text not null default 'auto_recurring' check (source in ('auto_recurring','manual')),
  note text,
  occurred_at timestamptz not null default now(),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create unique index uq_charge_enrollment_due_date
  on transactions (enrollment_id, due_date) where kind = 'charge';
create index idx_transactions_enrollment on transactions(enrollment_id);

create table sms_log (
  id bigserial primary key,
  enrollment_id bigint references enrollments(id),
  transaction_id bigint references transactions(id),
  phone text not null,
  message text not null,
  status text not null check (status in ('queued','sent','failed')),
  error text,
  created_at timestamptz not null default now()
);
