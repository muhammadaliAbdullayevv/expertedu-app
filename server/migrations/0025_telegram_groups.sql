-- Telegram groups: a course's group chat is connected to its CRM group; a few minutes
-- before each lesson ends the bot asks the teacher, student by student, how the
-- homework was done (lesson_feedback), and the answers show on the student's profile.
-- Also: how a chat was linked to a student ('group' = they typed the number they
-- registered with, inside a connected group's join flow).

alter table telegram_links add column method text not null default 'contact'
  check (method in ('contact', 'group'));

create table telegram_groups (
  chat_id bigint primary key,
  group_id bigint not null unique references groups(id),
  title text,
  connected_by text,
  connected_at timestamptz not null default now()
);

create table telegram_prompts (
  lesson_id bigint primary key references lessons(id) on delete cascade,
  chat_id bigint not null,
  status text not null default 'pending' check (status in ('pending', 'asked', 'done')),
  message_id bigint,
  created_at timestamptz not null default now()
);
create index idx_telegram_prompts_pending on telegram_prompts (created_at) where status = 'pending';

create table lesson_feedback (
  id bigserial primary key,
  lesson_id bigint not null references lessons(id) on delete cascade,
  enrollment_id bigint not null references enrollments(id),
  -- How well the student prepared (the homework): great > good > weak > bad > none.
  homework text not null check (homework in ('great', 'good', 'weak', 'bad', 'none', 'skipped')),
  answered_by text,
  answered_at timestamptz not null default now(),
  constraint uq_lesson_feedback unique (lesson_id, enrollment_id)
);
create index idx_lesson_feedback_enrollment on lesson_feedback (enrollment_id);
