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
  created_at timestamptz not null default now(),
  last_login_at timestamptz
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
  created_at timestamptz not null default now()
);

create table if not exists groups (
  id bigserial primary key,
  subject_id bigint references subjects(id),
  name text not null,
  teacher_id bigint references teachers(id),
  fee_amount bigint not null,
  due_day smallint not null check (due_day between 1 and 31),
  capacity int check (capacity > 0),
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
  created_at timestamptz not null default now()
);
create unique index if not exists uq_charge_enrollment_due_date
  on transactions (enrollment_id, due_date) where kind = 'charge';
create index if not exists idx_transactions_enrollment on transactions(enrollment_id);

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
