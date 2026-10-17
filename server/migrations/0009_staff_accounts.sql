-- Staff accounts are managed in the app now (owner only, routes/staff.py).
-- When each account last signed in, for the staff list.
alter table users add column last_login_at timestamptz;
