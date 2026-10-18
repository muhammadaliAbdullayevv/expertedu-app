-- Branches: Bosh ofis and the filiallar (docs/BRANCHES.md). Everything that
-- exists today goes to branch 1, "Bosh ofis", so nothing changes for anyone
-- until the owner adds the other branches.
--
-- A record created without naming a branch belongs to Bosh ofis (the column
-- default of 1): the API always names one, so this only catches hand-made SQL.

create table branches (
  id bigserial primary key,
  name text not null unique,
  is_headquarters boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into branches (name, is_headquarters) values ('Bosh ofis', true);

-- An admin works in exactly one branch; the owner has none (sees all).
-- A side table, not a users column: in production users belongs to postgres.
create table user_branches (
  user_id bigint primary key references users(id),
  branch_id bigint not null references branches(id)
);
insert into user_branches (user_id, branch_id) select id, 1 from users where role = 'admin';

alter table groups add column branch_id bigint not null default 1 references branches(id);
alter table leads add column branch_id bigint not null default 1 references branches(id);
alter table expenses add column branch_id bigint not null default 1 references branches(id);
alter table trial_sessions add column branch_id bigint not null default 1 references branches(id);
alter table student_events add column branch_id bigint not null default 1 references branches(id);
alter table salary_payouts add column branch_id bigint not null default 1 references branches(id);
create index idx_groups_branch on groups (branch_id);
create index idx_leads_branch on leads (branch_id);

-- One open lead per phone per course *in a branch* (a person may be a lead at
-- two branches).
drop index uq_leads_open_phone_subject;
create unique index uq_leads_open_phone_subject on leads (phone, coalesce(subject_id, 0), branch_id)
  where stage not in ('enrolled','not_interested','unreachable');

-- A teacher may work at several branches.
create table teacher_branches (
  teacher_id bigint not null references teachers(id),
  branch_id bigint not null references branches(id),
  primary key (teacher_id, branch_id)
);
insert into teacher_branches (teacher_id, branch_id) select id, 1 from teachers;

-- A student is one person; a branch sees them only through this link. The
-- archive is per branch.
create table student_branches (
  student_id bigint not null references students(id),
  branch_id bigint not null references branches(id),
  archived_at timestamptz,
  -- The branch's own note about him (the Izohlar tab); students.note is no
  -- longer used -- notes of one branch are not shown in another.
  note text,
  linked_at timestamptz not null default now(),
  primary key (student_id, branch_id)
);
create index idx_student_branches_branch on student_branches (branch_id);
insert into student_branches (student_id, branch_id, archived_at, note)
  select id, 1, archived_at, note from students;
alter table students drop column archived_at;

-- Money is per branch: a payment is taken in one branch and only ever pays
-- that branch's charges, so no branch collects another's debt and each has
-- its own ledger for a student who studies at two.
alter table payments add column branch_id bigint not null default 1 references branches(id);
update payments p set branch_id = g.branch_id
from enrollments e join groups g on g.id = e.group_id
where p.enrollment_id = e.id;

create view student_branch_balances as
select sb.student_id, sb.branch_id,
       coalesce(p.total, 0)::bigint as paid,
       coalesce(c.total, 0)::bigint as charged,
       (coalesce(p.total, 0) - coalesce(c.total, 0))::bigint as balance
from student_branches sb
left join (
  select student_id, branch_id, sum(amount) as total from payments
  where kind = 'payment' and status = 'valid' group by student_id, branch_id
) p on p.student_id = sb.student_id and p.branch_id = sb.branch_id
left join (
  select e.student_id, g.branch_id, sum(ch.amount) as total
  from charges ch join enrollments e on e.id = ch.enrollment_id join groups g on g.id = e.group_id
  where ch.status = 'active' group by e.student_id, g.branch_id
) c on c.student_id = sb.student_id and c.branch_id = sb.branch_id;

-- Pay lines say which branch they came from (a frozen month keeps it).
alter table salary_run_lines add column branch_id bigint not null default 1 references branches(id);
update salary_run_lines l set branch_id = g.branch_id from groups g where g.id = l.group_id;
