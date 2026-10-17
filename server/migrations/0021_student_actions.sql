-- Archiving a student, removing one from a group, moving one to another group
-- and putting one back: all keep every lesson, charge and payment. The student
-- is only marked (archived_at), his enrollments are ended, and each action is
-- written to student_events with the comment and what he still owed -- the
-- "Amallar" tab of his profile.
alter table students add column archived_at timestamptz;

create table student_events (
  id bigserial primary key,
  student_id bigint not null references students(id),
  kind text not null check (kind in ('added', 'removed', 'transferred', 'archived', 'unarchived', 'activated')),
  -- The group it was about (and the one he moved to), with names as they were then.
  group_id bigint references groups(id),
  group_name text,
  to_group_id bigint references groups(id),
  to_group_name text,
  enrollment_id bigint references enrollments(id),
  to_enrollment_id bigint references enrollments(id),
  note text,
  -- What he still owed on that group (or in all, for archived) at that moment.
  debt bigint,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index idx_student_events_student on student_events (student_id, created_at desc, id desc);

-- People who left every group they were ever in are the archive, as the
-- Arxiv tab already showed them; those who never joined a group are not.
update students s
set archived_at = coalesce(
  (select max(e.ended_at) from enrollments e where e.student_id = s.id)::timestamptz, now())
where exists (select 1 from enrollments e where e.student_id = s.id)
  and not exists (select 1 from enrollments e where e.student_id = s.id and e.status = 'active');
