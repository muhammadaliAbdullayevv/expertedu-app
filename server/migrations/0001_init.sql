create table users (
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
