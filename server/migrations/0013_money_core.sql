-- Money core: charges, payments and the allocations tying them together.
-- Replaces the single `transactions` table (kept, read-only, as history).

create table charges (
  id bigserial primary key,
  enrollment_id bigint not null references enrollments(id),
  -- First day of the month this charge is for.
  period_month date not null check (extract(day from period_month) = 1),
  due_date date not null,
  amount bigint not null check (amount >= 0),
  -- What the amount was made of: the group's fee at the time, less the
  -- enrollment's discount (a first prorated month is smaller than both).
  base_fee bigint not null check (base_fee >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  is_prorated boolean not null default false,
  note text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  cancelled_at timestamptz,
  cancelled_by bigint references users(id),
  cancel_reason text,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  constraint charges_cancel_fields check (
    (status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)
  )
);
-- One live charge per enrollment per month: generating twice is harmless.
create unique index uq_charges_enrollment_month on charges (enrollment_id, period_month) where status = 'active';
create index idx_charges_enrollment on charges (enrollment_id);

-- A payment, or the reversal that cancels one. Cancelling never deletes:
-- the payment is marked cancelled and a 'reversal' row records the money
-- going back out, on the day it happened.
create table payments (
  id bigserial primary key,
  student_id bigint not null references students(id),
  -- Which group it was handed over for (informational; allocation is per student).
  enrollment_id bigint references enrollments(id),
  kind text not null default 'payment' check (kind in ('payment', 'reversal')),
  amount bigint not null check (amount > 0),
  -- Null only for payments recorded before methods existed.
  method text check (method in ('cash', 'card', 'click_payme')),
  received_by bigint references users(id),
  received_at timestamptz not null default now(),
  receipt_no text,
  note text,
  status text not null default 'valid' check (status in ('valid', 'cancelled')),
  -- On a reversal: the payment it cancels, and why.
  reverses_id bigint references payments(id),
  reason text,
  cancelled_at timestamptz,
  cancelled_by bigint references users(id),
  cancel_reason text,
  created_at timestamptz not null default now(),
  constraint payments_receipt_unique unique (receipt_no),
  constraint payments_reverses_once unique (reverses_id),
  constraint payments_reversal_fields check ((kind = 'reversal') = (reverses_id is not null)),
  constraint payments_cancel_fields check (
    (status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)
  ),
  constraint payments_reversal_valid check (kind = 'payment' or (status = 'valid' and reason is not null))
);
create index idx_payments_student on payments (student_id, received_at);
create sequence payment_receipt_seq;

-- Which part of which payment paid which charge. Signed and append-only:
-- cancelling a payment adds negative rows, it never edits old ones. The
-- teacher and group are the charge's at that moment, and counts_in_month
-- is the salary month the money belongs to (see money/service.py).
create table payment_allocations (
  id bigserial primary key,
  payment_id bigint not null references payments(id),
  charge_id bigint not null references charges(id),
  amount bigint not null check (amount <> 0),
  teacher_id bigint references teachers(id),
  group_id bigint references groups(id),
  counts_in_month date not null check (extract(day from counts_in_month) = 1),
  created_at timestamptz not null default now()
);
create index idx_allocations_payment on payment_allocations (payment_id);
create index idx_allocations_charge on payment_allocations (charge_id);
create index idx_allocations_salary on payment_allocations (counts_in_month, teacher_id);

-- Money is never deleted, and an allocation never edited.
create function money_never_deleted() returns trigger language plpgsql as $$
begin
  raise exception '% rows are never deleted', tg_table_name;
end;
$$;
create function allocations_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'payment_allocations is append-only';
end;
$$;
create trigger charges_never_deleted before delete on charges
  for each row execute function money_never_deleted();
create trigger payments_never_deleted before delete on payments
  for each row execute function money_never_deleted();
create trigger payment_allocations_append_only before update or delete on payment_allocations
  for each row execute function allocations_append_only();

-- Backfill from `transactions` -----------------------------------------------

-- Charges. Two legacy charges in one month (a first prorated charge and the
-- group's due day in the same month) become one: amounts added, the first
-- one's dates kept. Every merge is written to the audit log.
insert into audit_log (entity, entity_id, action, reason, after)
select 'charge', enrollment_id, 'migrated_merge',
       'Bir oyda ikkita to''lov talabi bitta qilindi (0013)',
       jsonb_build_object('month', month, 'charges', n, 'amount', total)
from (
  select enrollment_id, date_trunc('month', due_date)::date as month, count(*) as n, sum(amount) as total
  from transactions where kind = 'charge' group by 1, 2 having count(*) > 1
) merged;

insert into charges (enrollment_id, period_month, due_date, amount, base_fee, is_prorated, created_by, created_at)
select enrollment_id,
       date_trunc('month', due_date)::date,
       min(due_date),
       sum(amount),
       sum(amount),
       bool_or(is_prorated),
       min(created_by),
       min(created_at)
from transactions
where kind = 'charge'
group by enrollment_id, date_trunc('month', due_date)::date
order by min(due_date), enrollment_id;

-- Payments, with receipt numbers in their original order.
insert into payments (student_id, enrollment_id, amount, method, received_by, received_at, receipt_no, note, created_at)
select e.student_id, t.enrollment_id, t.amount, t.method, t.created_by, t.occurred_at,
       'R-' || lpad(t.n::text, 6, '0'), t.note, t.created_at
from (
  select *, row_number() over (order by occurred_at, id) as n from transactions where kind = 'payment'
) t
join enrollments e on e.id = t.enrollment_id
order by t.n;
select setval('payment_receipt_seq', coalesce((select count(*) from payments), 0) + 1, false);

-- Allocations: each student's payments laid end to end against their
-- charges, oldest first -- the overlap of the two runs is what was paid.
insert into payment_allocations (payment_id, charge_id, amount, teacher_id, group_id, counts_in_month, created_at)
select p.id, c.id,
       least(c.hi, p.hi) - greatest(c.lo, p.lo),
       g.teacher_id, g.id,
       date_trunc('month', p.received_at at time zone 'Asia/Tashkent')::date,
       p.received_at
from (
  select id, student_id, received_at,
         sum(amount) over w - amount as lo, sum(amount) over w as hi
  from payments where kind = 'payment'
  window w as (partition by student_id order by received_at, id)
) p
join (
  select c.id, e.student_id, e.group_id,
         sum(c.amount) over w - c.amount as lo, sum(c.amount) over w as hi
  from charges c join enrollments e on e.id = c.enrollment_id
  where c.status = 'active' and c.amount > 0
  window w as (partition by e.student_id order by c.period_month, c.id)
) c on c.student_id = p.student_id and least(c.hi, p.hi) > greatest(c.lo, p.lo)
join groups g on g.id = c.group_id;

-- One definition of "how much is owed", used by every screen and report.
-- What each charge has been paid so far, and what's left of it.
create view charge_balances as
select c.id as charge_id, c.enrollment_id, e.student_id, e.group_id, c.period_month, c.due_date,
       c.status, c.amount,
       coalesce(a.paid, 0)::bigint as paid,
       (c.amount - coalesce(a.paid, 0))::bigint as owed
from charges c
join enrollments e on e.id = c.enrollment_id
left join (select charge_id, sum(amount) as paid from payment_allocations group by charge_id) a on a.charge_id = c.id;

-- Per enrollment: active charges, what was allocated to them, what's owed.
create view enrollment_balances as
select e.id as enrollment_id, e.student_id,
       coalesce(sum(cb.amount) filter (where cb.status = 'active'), 0)::bigint as charged,
       coalesce(sum(cb.paid) filter (where cb.status = 'active'), 0)::bigint as paid,
       (coalesce(sum(cb.amount) filter (where cb.status = 'active'), 0)
         - coalesce(sum(cb.paid) filter (where cb.status = 'active'), 0))::bigint as owed
from enrollments e
left join charge_balances cb on cb.enrollment_id = e.id
group by e.id;

-- Per student: valid payments minus active charges. Negative = debt,
-- positive = credit. Computed, never stored.
create view student_balances as
select s.id as student_id,
       coalesce(p.total, 0)::bigint as paid,
       coalesce(c.total, 0)::bigint as charged,
       (coalesce(p.total, 0) - coalesce(c.total, 0))::bigint as balance
from students s
left join (
  select student_id, sum(amount) as total from payments
  where kind = 'payment' and status = 'valid' group by student_id
) p on p.student_id = s.id
left join (
  select e.student_id, sum(ch.amount) as total
  from charges ch join enrollments e on e.id = ch.enrollment_id
  where ch.status = 'active' group by e.student_id
) c on c.student_id = s.id;
