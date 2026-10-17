-- Admissions: inquiries become leads, with an interaction timeline,
-- follow-up tasks, trial sessions and bookings, and idempotency keys for
-- retried and offline-queued writes.
--
-- A lead is never a student and never in a group. The only way a lead
-- becomes an enrollment is POST /leads/{id}/enroll, which links the
-- enrollment back here -- so the whole lead and trial history stays
-- attached to the person after they become a student.
--
-- The contact is identified by phone (digits only, 998 + 9 digits): the
-- student with that phone if there is one (uq_students_phone), plus every
-- lead with it. No separate contacts table -- it would only copy students'
-- names and phones.

-- Leads ----------------------------------------------------------------

alter table inquiries rename to leads;
drop index idx_inquiries_status;
-- Same names a fresh schema.sql gives them.
alter sequence inquiries_id_seq rename to leads_id_seq;
alter index inquiries_pkey rename to leads_pkey;
alter table leads rename constraint inquiries_subject_id_fkey to leads_subject_id_fkey;
alter table leads rename constraint inquiries_created_by_fkey to leads_created_by_fkey;
alter table leads rename constraint inquiries_converted_student_id_fkey to leads_student_id_fkey;

alter table leads rename column trial_date to preferred_trial_date;
alter table leads rename column converted_student_id to student_id;

alter table leads add column client_id uuid not null default gen_random_uuid();
alter table leads add column parent_phone text;
alter table leads add column source text
  check (source in ('instagram', 'telegram', 'referral', 'walk_in', 'other'));
alter table leads add column stage text;
alter table leads add column lost_reason text;
alter table leads add column assigned_to bigint references users(id);
alter table leads add column enrollment_id bigint references enrollments(id);
alter table leads add column enrolled_at timestamptz;
alter table leads add column closed_at timestamptz;
alter table leads add column version int not null default 1;
alter table leads add column updated_at timestamptz not null default now();

-- Old statuses -> stages. 'converted' only ever made a student, never an
-- enrollment, so it can't be 'enrolled' (which needs one): those keep
-- their student link and wait for a decision.
update leads set stage = case status
  when 'new' then 'new'
  when 'contacted' then 'contacted'
  when 'scheduled' then 'contacted'
  when 'converted' then 'decision_pending'
  else 'not_interested'
end;
update leads set closed_at = created_at where stage = 'not_interested';
update leads set assigned_to = created_by;
update leads
set phone = case
  when length(regexp_replace(phone, '\D', '', 'g')) = 9 then '998' || regexp_replace(phone, '\D', '', 'g')
  else regexp_replace(phone, '\D', '', 'g')
end
where phone ~ '\D' or length(phone) = 9;

alter table leads drop column status;
alter table leads alter column stage set not null;
alter table leads alter column stage set default 'new';
alter table leads add constraint leads_stage_check check (stage in (
  'new', 'contacted', 'trial_scheduled', 'trial_completed', 'decision_pending', 'follow_up_later',
  'enrolled', 'not_interested', 'unreachable'
));
alter table leads add constraint leads_enrolled_has_enrollment
  check ((stage = 'enrolled') = (enrollment_id is not null));
alter table leads add constraint leads_phone_format check (phone ~ '^998[0-9]{9}$');

alter table leads add constraint uq_leads_client_id unique (client_id);
-- One lead per enrollment: a retried conversion can't link a second one.
alter table leads add constraint uq_leads_enrollment unique (enrollment_id);
-- At most one open lead per phone per course. A second course is a
-- second lead; so is a new inquiry after an earlier one was closed.
-- Fails (rolling the whole file back) if old inquiries break this --
-- check before running.
create unique index uq_leads_open_phone_subject on leads (phone, coalesce(subject_id, 0))
  where stage not in ('enrolled', 'not_interested', 'unreachable');
create index idx_leads_stage on leads (stage);
create index idx_leads_phone on leads (phone);
create index idx_leads_created_at on leads (created_at);
create index idx_leads_student on leads (student_id) where student_id is not null;

-- Trials -----------------------------------------------------------------

-- A trial lesson slot: either a dedicated trial lesson, or guest seats at
-- one of a regular group's lessons ('group_lesson'). Either way nobody is
-- enrolled -- guests are trial_bookings, never enrollments.
create table trial_sessions (
  id bigserial primary key,
  kind text not null check (kind in ('dedicated', 'group_lesson')),
  subject_id bigint references subjects(id),
  group_id bigint references groups(id),
  teacher_id bigint references teachers(id),
  room text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  capacity int not null check (capacity > 0),
  status text not null default 'scheduled' check (status in ('scheduled', 'cancelled')),
  note text,
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trial_sessions_time_order check (ends_at > starts_at),
  constraint trial_sessions_group_kind check ((kind = 'group_lesson') = (group_id is not null))
);
create index idx_trial_sessions_starts_at on trial_sessions (starts_at);
create index idx_trial_sessions_teacher on trial_sessions (teacher_id, starts_at) where status = 'scheduled';

-- One lead's seat in one session. Attendance and the teacher's feedback
-- live here (one of each per booking) -- separate from anything about
-- regular groups. A reschedule keeps the old row as 'rescheduled'; the
-- new one points back at it.
create table trial_bookings (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  session_id bigint not null references trial_sessions(id) on delete restrict,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'attended', 'absent', 'cancelled', 'rescheduled')),
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
-- One upcoming trial per lead at a time: move or cancel it, don't stack.
create unique index uq_trial_bookings_lead_scheduled on trial_bookings (lead_id) where status = 'scheduled';
create index idx_trial_bookings_session on trial_bookings (session_id);
create index idx_trial_bookings_lead on trial_bookings (lead_id);

-- Follow-up tasks ----------------------------------------------------------

create table follow_up_tasks (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  title text not null,
  due_at timestamptz not null,
  assigned_to bigint references users(id),
  status text not null default 'open' check (status in ('open', 'done', 'cancelled')),
  completed_at timestamptz,
  completed_by bigint references users(id),
  version int not null default 1,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  constraint follow_up_tasks_completion check ((status = 'open') = (completed_at is null))
);
create index idx_follow_up_tasks_open_due on follow_up_tasks (due_at) where status = 'open';
create index idx_follow_up_tasks_lead on follow_up_tasks (lead_id);

-- Interaction timeline -------------------------------------------------

-- Calls, messages and notes staff log, plus a 'system' row for every
-- change the server makes to a lead, its trials or its tasks -- this is
-- the lead's audit trail, so rows are never updated or deleted.
create table lead_interactions (
  id bigserial primary key,
  lead_id bigint not null references leads(id) on delete restrict,
  kind text not null check (kind in ('call_in', 'call_out', 'sms', 'telegram', 'visit', 'note', 'system')),
  body text not null,
  old_stage text,
  new_stage text,
  booking_id bigint references trial_bookings(id),
  task_id bigint references follow_up_tasks(id),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index idx_lead_interactions_lead on lead_interactions (lead_id, created_at);

create function lead_interactions_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'lead_interactions is append-only';
end;
$$;
create trigger lead_interactions_append_only
  before update or delete on lead_interactions
  for each row execute function lead_interactions_append_only();

-- Every existing inquiry starts its timeline with its creation.
insert into lead_interactions (lead_id, kind, body, new_stage, created_by, created_at)
select id, 'system', 'So''rov yaratildi', stage, created_by, created_at from leads;

-- Idempotency --------------------------------------------------------------

-- A write sent with an Idempotency-Key header is done once: a retry with
-- the same key gets the stored response back instead of doing it again.
-- The key row is written in the same transaction as the write itself, so
-- a failed write leaves no key behind and can simply be retried.
create table idempotency_keys (
  key uuid primary key,
  user_id bigint not null references users(id),
  endpoint text not null,
  request_hash text not null,
  status_code int,
  response jsonb,
  created_at timestamptz not null default now()
);
create index idx_idempotency_keys_created_at on idempotency_keys (created_at);
