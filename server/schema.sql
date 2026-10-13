-- Expert Edu Center backend schema.
-- Single-tenant: one deployment == one education center, no shop/org
-- scoping. Only owner/admin accounts exist -- no teacher/student login.
-- Apply with: psql "$DATABASE_URL" -f schema.sql

create table if not exists users (
  id bigserial primary key,
  phone text not null unique,
  password_hash text not null,
  full_name text not null,
  role text not null check (role in ('owner','admin')),
  token_version int not null default 0,
  is_active boolean not null default true,
  failed_login_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
