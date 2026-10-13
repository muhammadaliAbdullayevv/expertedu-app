create table subjects (
  id bigserial primary key,
  name text not null unique,
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);

alter table groups add column subject_id bigint references subjects(id);
