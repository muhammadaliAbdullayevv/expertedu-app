-- Rollback for 0011_finance.sql. LOSES all expenses and salary payouts,
-- teachers' salary percentages, and which teacher each payment counted
-- towards. Take a pg_dump first.
drop table expenses;
drop index idx_transactions_payment_teacher;
drop trigger transactions_payment_teacher on transactions;
drop function transactions_payment_teacher();
alter table transactions drop column teacher_id;
alter table teachers drop column salary_percent;
