-- Billing is a per-group rule (V2 money rules):
--   fixed_day:           everyone in the group pays on billing_day (1-28);
--                        a student joining mid-cycle first pays a prorated
--                        part (prorate_first_period, on by default) up to the
--                        next billing day.
--   student_anniversary: each enrollment bills on its own start day every
--                        month, no proration (a missing day -> month end).
-- Replaces the old per-group due_day: every existing group keeps its due
-- day as fixed_day's billing day (the 29th-31st become the 28th).
alter table groups add column billing_mode text not null default 'fixed_day'
  check (billing_mode in ('fixed_day', 'student_anniversary'));
alter table groups add column billing_day smallint check (billing_day between 1 and 28);
alter table groups add column prorate_first_period boolean not null default true;
update groups set billing_day = least(due_day, 28);
alter table groups add constraint groups_billing_day_for_mode check (
  (billing_mode = 'fixed_day') = (billing_day is not null)
);
alter table groups drop column due_day;
