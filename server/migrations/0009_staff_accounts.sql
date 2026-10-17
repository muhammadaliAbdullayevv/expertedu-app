-- Staff accounts are managed in the app now (owner only, routes/staff.py).
--
-- When each account last signed in, for the staff list. Its own table
-- rather than a column on users: in production `users` belongs to the
-- postgres superuser (created before the app's role existed), and the
-- app's role can't alter it.
create table staff_logins (
  user_id bigint primary key references users(id),
  last_login_at timestamptz not null
);
