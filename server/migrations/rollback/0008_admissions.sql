-- Rollback for 0008_admissions.sql. Run in one transaction:
--   psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f migrations/rollback/0008_admissions.sql
--
-- LOSES DATA: the interaction timeline, follow-up tasks, trial sessions and
-- bookings, and every lead field 0007 didn't have (source, assignee, parent
-- phone, enrollment link). Leads go back to being inquiries with the
-- nearest old status. Students, enrollments and payments made by a
-- conversion stay -- they're ordinary students now. Take a pg_dump first.

drop table idempotency_keys;
drop trigger lead_interactions_append_only on lead_interactions;
drop table lead_interactions;
drop function lead_interactions_append_only();
drop table follow_up_tasks;
drop table trial_bookings;
drop table trial_sessions;

alter table leads add column status text;
update leads set status = case stage
  when 'new' then 'new'
  when 'contacted' then 'contacted'
  when 'follow_up_later' then 'contacted'
  when 'decision_pending' then 'contacted'
  when 'trial_scheduled' then 'scheduled'
  when 'trial_completed' then 'scheduled'
  when 'enrolled' then 'converted'
  else 'lost'
end;
alter table leads alter column status set not null;
alter table leads alter column status set default 'new';
alter table leads add constraint inquiries_status_check
  check (status in ('new', 'contacted', 'scheduled', 'converted', 'lost'));

drop index uq_leads_open_phone_subject;
drop index idx_leads_stage;
drop index idx_leads_phone;
drop index idx_leads_created_at;
drop index idx_leads_student;
alter table leads drop column stage;
alter table leads drop column client_id;
alter table leads drop column parent_phone;
alter table leads drop column source;
alter table leads drop column lost_reason;
alter table leads drop column assigned_to;
alter table leads drop column enrollment_id;
alter table leads drop column enrolled_at;
alter table leads drop column closed_at;
alter table leads drop column version;
alter table leads drop column updated_at;
alter table leads drop constraint leads_phone_format;

alter table leads rename column preferred_trial_date to trial_date;
alter table leads rename column student_id to converted_student_id;
alter table leads rename constraint leads_subject_id_fkey to inquiries_subject_id_fkey;
alter table leads rename constraint leads_created_by_fkey to inquiries_created_by_fkey;
alter table leads rename constraint leads_student_id_fkey to inquiries_converted_student_id_fkey;
alter index leads_pkey rename to inquiries_pkey;
alter sequence leads_id_seq rename to inquiries_id_seq;
alter table leads rename to inquiries;
create index idx_inquiries_status on inquiries (status);
