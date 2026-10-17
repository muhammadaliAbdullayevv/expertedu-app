-- Rollback for 0009_staff_accounts.sql.
alter table users drop column last_login_at;
