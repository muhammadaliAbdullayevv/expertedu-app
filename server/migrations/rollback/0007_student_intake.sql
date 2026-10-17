-- Undoes migrations/0007_student_intake.sql. Run with:
--   psql "$DATABASE_URL" -1 -v ON_ERROR_STOP=1 -f migrations/rollback/0007_student_intake.sql
-- and deploy the server code from before 0007 at the same time -- the newer
-- code reads these columns.
--
-- Data entered into these columns is lost: discounts (the monthly job then
-- charges those students the full fee again), payment methods, parent
-- phones, lead sources and group capacities. Charges and payments already
-- recorded stay exactly as they are.
drop index if exists uq_students_phone;
alter table transactions drop column if exists method;
alter table enrollments drop constraint if exists enrollments_discount_percent_max;
alter table enrollments drop constraint if exists enrollments_discount_pair;
alter table enrollments drop column if exists discount_value;
alter table enrollments drop column if exists discount_kind;
alter table students drop column if exists heard_from;
alter table students drop column if exists parent_phone;
alter table groups drop column if exists capacity;
