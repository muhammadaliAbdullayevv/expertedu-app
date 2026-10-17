-- Teachers become their own records (picked from a list when creating a
-- group) instead of a name typed onto each group -- groundwork for teacher
-- salaries too. Existing typed names are carried over: every distinct one
-- becomes a teacher, and its groups point at it.
create table teachers (
  id bigserial primary key,
  full_name text not null,
  phone text,
  note text,
  is_active boolean not null default true,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

alter table groups add column teacher_id bigint references teachers(id);

insert into teachers (full_name)
select distinct btrim(teacher_name) from groups
where teacher_name is not null and btrim(teacher_name) <> '';

update groups g set teacher_id = t.id
from teachers t
where btrim(g.teacher_name) = t.full_name;

-- The name now lives on the teacher; API responses still carry a
-- teacher_name (joined in), so older app builds keep working unchanged.
alter table groups drop column teacher_name;
