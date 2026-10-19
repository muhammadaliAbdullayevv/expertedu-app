-- Printing from Telegram: a teacher sends a file to the bot, the bot makes a ready PDF of the chosen pages
-- and queues it here; the CRM app on the PC beside the printer (the "print station") takes it and prints.
-- The PDF itself is kept only while the job waits or prints, then dropped.

create table print_jobs (
  id bigserial primary key,
  branch_id bigint not null references branches(id),
  requested_by text not null,
  requested_role text not null check (requested_role in ('owner', 'admin', 'teacher')),
  telegram_user_id bigint not null,
  chat_id bigint not null,
  title text not null,
  summary text,
  pages int not null check (pages > 0),
  copies int not null default 1 check (copies between 1 and 999),
  duplex boolean not null default false,
  color boolean not null default false,
  landscape boolean not null default false,
  status text not null default 'queued' check (status in ('queued', 'printing', 'done', 'failed', 'expired', 'cancelled')),
  error text,
  printer text,
  data bytea,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  finished_at timestamptz,
  notified_at timestamptz
);
create index idx_print_jobs_queue on print_jobs (branch_id, id) where status = 'queued';
create index idx_print_jobs_to_tell on print_jobs (id) where notified_at is null and status in ('done', 'failed', 'expired', 'cancelled');

-- The last time each branch's print station asked for work: "is the printer PC on?"
create table print_stations (
  branch_id bigint primary key references branches(id),
  printer text,
  last_seen_at timestamptz not null default now()
);
