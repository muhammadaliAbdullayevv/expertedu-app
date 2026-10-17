-- Lesson schedule and attendance.
--
-- A group's week is a set of slots (weekday + local start/end time + room,
-- in the center's calendar). The timetable is computed from those slots;
-- a `lessons` row only exists once something happened to one lesson --
-- attendance marked, the lesson cancelled, or an extra lesson added -- so
-- nothing has to be generated ahead of time, and changing the schedule
-- changes every lesson that hasn't happened yet.

create table group_schedules (
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
create index idx_group_schedules_group on group_schedules (group_id);
create index idx_group_schedules_weekday on group_schedules (weekday);

create table lessons (
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
create index idx_lessons_starts_at on lessons (starts_at);

-- Regular students' attendance. (Trial guests' attendance stays on
-- trial_bookings -- separate by design.)
create table attendance (
  id bigserial primary key,
  lesson_id bigint not null references lessons(id) on delete restrict,
  enrollment_id bigint not null references enrollments(id),
  status text not null check (status in ('present', 'late', 'absent', 'excused')),
  note text,
  marked_by bigint references users(id),
  marked_at timestamptz not null default now(),
  constraint uq_attendance_lesson_enrollment unique (lesson_id, enrollment_id)
);
create index idx_attendance_enrollment on attendance (enrollment_id);
