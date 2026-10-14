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

-- A subject (e.g. "Ingliz tili") can have several groups under it (e.g.
-- Beginner/Intermediate cohorts) -- the home screen browses subjects
-- first, then that subject's groups, then a group's own roster.
create table if not exists subjects (
  id bigserial primary key,
  name text not null unique,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

create table if not exists groups (
  id bigserial primary key,
  subject_id bigint references subjects(id),
  name text not null,
  teacher_name text,
  fee_amount bigint not null,
  due_day smallint not null check (due_day between 1 and 31),
  is_active boolean not null default true,
  note text,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

create table if not exists students (
  id bigserial primary key,
  full_name text not null,
  phone text not null,
  telegram_username text,
  note text,
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
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_enrollments_group_active on enrollments(group_id) where status = 'active';
create index if not exists idx_enrollments_student on enrollments(student_id);

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
  occurred_at timestamptz not null default now(),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create unique index if not exists uq_charge_enrollment_due_date
  on transactions (enrollment_id, due_date) where kind = 'charge';
create index if not exists idx_transactions_enrollment on transactions(enrollment_id);

-- A phone/walk-in inquiry -- lighter-weight than a Student, logged the
-- moment an operator takes the call, before anyone has committed to a
-- group. Converting one creates a real Student (see routes/inquiries.py).
create table if not exists inquiries (
  id bigserial primary key,
  full_name text not null,
  phone text not null,
  note text,
  subject_id bigint references subjects(id),
  trial_date date,
  status text not null check (status in ('new','contacted','scheduled','converted','lost')) default 'new',
  converted_student_id bigint references students(id),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_inquiries_status on inquiries(status);

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
