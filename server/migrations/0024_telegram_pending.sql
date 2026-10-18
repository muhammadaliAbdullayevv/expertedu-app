-- Telegram: someone who shared their phone number but is not a student yet.
-- When the center accepts them (a student with this number gets a group), the
-- notifier links their chat and sends a welcome message.

create table telegram_pending (
  chat_id bigint primary key,
  phone text not null,
  language text not null default 'uz' check (language in ('uz', 'en')),
  created_at timestamptz not null default now()
);
create index idx_telegram_pending_phone on telegram_pending (phone);

alter table telegram_outbox drop constraint telegram_outbox_kind_check;
alter table telegram_outbox add constraint telegram_outbox_kind_check
  check (kind in ('due_tomorrow', 'due_today', 'overdue', 'paid', 'absent', 'weekly', 'welcome'));
