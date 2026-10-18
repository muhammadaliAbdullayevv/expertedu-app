delete from telegram_outbox where kind = 'welcome';
alter table telegram_outbox drop constraint telegram_outbox_kind_check;
alter table telegram_outbox add constraint telegram_outbox_kind_check
  check (kind in ('due_tomorrow', 'due_today', 'overdue', 'paid', 'absent', 'weekly'));
drop table telegram_pending;
