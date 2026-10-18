-- The Telegram bot (experteducenteraibot). A student links their chat by
-- sharing their phone number; the server then queues messages for them in
-- telegram_outbox and the bot sends them. The bot never reads the rest of the
-- database: it talks to /bot/* with its own key.

create table telegram_links (
  chat_id bigint primary key,
  student_id bigint not null references students(id),
  phone text not null,
  language text not null default 'uz' check (language in ('uz', 'en')),
  -- The student pressed /stop (or blocked the bot): nothing more is queued.
  stopped boolean not null default false,
  linked_at timestamptz not null default now()
);
create index idx_telegram_links_student on telegram_links (student_id);

create table telegram_outbox (
  id bigserial primary key,
  chat_id bigint not null,
  student_id bigint not null references students(id),
  kind text not null check (kind in ('due_tomorrow', 'due_today', 'overdue', 'paid', 'absent', 'weekly')),
  -- What the message is about, as data; the bot words it in the chat's language.
  payload jsonb not null default '{}',
  -- One message per thing per chat, however often the job runs.
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'blocked')),
  attempts int not null default 0,
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index idx_telegram_outbox_pending on telegram_outbox (id) where status = 'pending';
