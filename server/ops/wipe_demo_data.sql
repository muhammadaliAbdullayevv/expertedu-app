-- Clears the test data before the center starts using the system for real:
-- students, groups, teachers, subjects, requests, lessons, attendance, money,
-- history. KEEPS: the owner account, branches, branch settings, app settings.
-- Removes every account that is not the owner.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v do_commit=false -f wipe_demo_data.sql   # look only
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -v do_commit=true  -f wipe_demo_data.sql   # do it
--
-- Everything happens in one transaction: any error, or do_commit=false, leaves
-- the database exactly as it was.
\set ON_ERROR_STOP on
begin;

do $$
declare
  t text;
  n bigint;
  keep text[] := array['users', 'user_branches', 'staff_logins', 'branches', 'app_settings'];
  doomed text[];
begin
  if (select count(*) from users where role = 'owner') <> 1 then
    raise exception 'Expected exactly one owner account; refusing to wipe.';
  end if;
  select array_agg(table_name order by table_name) into doomed
  from information_schema.tables
  where table_schema = 'public' and table_type = 'BASE TABLE' and table_name <> all (keep);
  foreach t in array doomed loop
    execute format('select count(*) from %I', t) into n;
    if n > 0 then raise notice 'clearing % (% rows)', t, n; end if;
  end loop;
  execute 'truncate table ' || (select string_agg(format('%I', x), ', ') from unnest(doomed) x)
          || ' restart identity';
end $$;

-- Every account but the owner goes, with its branch link and login record.
delete from user_branches where user_id in (select id from users where role <> 'owner');
delete from staff_logins where user_id in (select id from users where role <> 'owner');
delete from users where role <> 'owner';

\echo
\echo '--- what is left ---'
select 'users' as table_name, count(*) from users
union all select 'branches', count(*) from branches
union all select 'students', count(*) from students
union all select 'groups', count(*) from groups
union all select 'teachers', count(*) from teachers
union all select 'subjects', count(*) from subjects
union all select 'leads', count(*) from leads
union all select 'payments', count(*) from payments;
select id, phone, full_name, role from users;
select id, name, is_headquarters from branches order by id;

\if :do_commit
  commit;
  \echo 'COMMITTED: the test data is gone.'
\else
  rollback;
  \echo 'ROLLED BACK: nothing was changed (run again with do_commit=true to do it).'
\endif
