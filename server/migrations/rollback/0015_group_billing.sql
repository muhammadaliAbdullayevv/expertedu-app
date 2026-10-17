alter table groups add column due_day smallint not null default 1 check (due_day between 1 and 31);
update groups set due_day = coalesce(billing_day, 1);
alter table groups drop constraint groups_billing_day_for_mode;
alter table groups drop column prorate_first_period;
alter table groups drop column billing_day;
alter table groups drop column billing_mode;
