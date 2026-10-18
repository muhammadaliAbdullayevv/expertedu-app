alter table salary_run_lines drop column branch_id;
drop view student_branch_balances;
alter table payments drop column branch_id;
alter table students add column archived_at timestamptz;
update students s set archived_at = (select archived_at from student_branches b where b.student_id = s.id and b.branch_id = 1),
  note = coalesce((select note from student_branches b where b.student_id = s.id and b.branch_id = 1), s.note);
drop table student_branches;
drop table teacher_branches;
drop index uq_leads_open_phone_subject;
create unique index uq_leads_open_phone_subject on leads (phone, coalesce(subject_id, 0))
  where stage not in ('enrolled','not_interested','unreachable');
alter table salary_payouts drop column branch_id;
alter table student_events drop column branch_id;
alter table trial_sessions drop column branch_id;
alter table expenses drop column branch_id;
alter table leads drop column branch_id;
alter table groups drop column branch_id;
drop table user_branches;
drop table branches;
