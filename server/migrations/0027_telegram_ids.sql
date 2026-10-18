-- Telegram groups, simplified: a CRM group page hands out a one-time code and the bot's
-- /connect CODE in the Telegram group ties the chat to the group. Who may answer the bot's
-- homework questions is decided by Telegram user ids held in the CRM (teachers, admins), not
-- by phone numbers typed into a chat.

alter table teachers add column telegram_user_id bigint unique;

-- Not a users column: in production users belongs to the postgres superuser (like staff_logins).
create table staff_telegram (
  user_id bigint primary key references users(id),
  telegram_user_id bigint not null unique
);

create table telegram_connect_codes (
  code text primary key,
  group_id bigint not null references groups(id) on delete cascade,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index idx_telegram_connect_codes_group on telegram_connect_codes (group_id);

-- Messages for a whole Telegram group (no names, no amounts), for the bot to post.
create table telegram_group_outbox (
  id bigserial primary key,
  chat_id bigint not null,
  kind text not null check (kind in ('payment_soon')),
  payload jsonb not null default '{}',
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed')),
  attempts int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index idx_telegram_group_outbox_pending on telegram_group_outbox (id) where status = 'pending';
