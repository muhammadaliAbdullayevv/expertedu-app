-- Money core: charges, payments and the allocations tying them together.
-- Replaces the single `transactions` table (kept, read-only, as history).

create table charges (
  id bigserial primary key,
  enrollment_id bigint not null references enrollments(id),
  -- The billing period this charge pays for: [period_start, period_end).
  -- Charged on its first day, so due_date is period_start.
  period_start date not null,
  period_end date not null,
  due_date date not null,
  amount bigint not null check (amount >= 0),
  -- What the amount was made of: the group's fee at the time, less the
  -- enrollment's discount (a prorated first period is smaller than both).
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
  constraint charges_period_order check (period_end > period_start),
  constraint charges_due_on_start check (due_date = period_start),
  -- A prorated charge is part of a month, so never more than the full price.
  constraint charges_prorated_within_price check (not is_prorated or amount <= base_fee - discount_amount),
  constraint charges_cancel_fields check (
    (status = 'cancelled') = (cancelled_at is not null and cancel_reason is not null)
  )
);
-- One live charge per enrollment per billing period: generating twice is harmless.
create unique index uq_charges_enrollment_period on charges (enrollment_id, period_start) where status = 'active';
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

-- Charges map one to one: each legacy charge covers the days from its due
-- date to the enrollment's next charge -- or, for the latest one, to the
-- group's next due day (clamped to short months, as the old job did).
insert into charges (enrollment_id, period_start, period_end, due_date, amount, base_fee, is_prorated, created_by, created_at)
select l.enrollment_id, l.due_date,
       coalesce(
         l.next_charge,
         case when l.this_due > l.due_date then l.this_due else l.next_due end
       ),
       l.due_date, l.amount, l.amount, l.is_prorated, l.created_by, l.created_at
from (
  select t.enrollment_id, t.due_date, t.amount, t.is_prorated, t.created_by, t.created_at,
         lead(t.due_date) over (partition by t.enrollment_id order by t.due_date, t.id) as next_charge,
         (date_trunc('month', t.due_date)
            + (least(g.due_day, extract(day from date_trunc('month', t.due_date) + interval '1 month - 1 day')::int) - 1)
              * interval '1 day')::date as this_due,
         (date_trunc('month', t.due_date) + interval '1 month'
            + (least(g.due_day, extract(day from date_trunc('month', t.due_date) + interval '2 month - 1 day')::int) - 1)
              * interval '1 day')::date as next_due
  from transactions t
  join enrollments e on e.id = t.enrollment_id
  join groups g on g.id = e.group_id
  where t.kind = 'charge'
) l
order by l.due_date, l.enrollment_id;

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
  window w as (partition by e.student_id order by c.period_start, c.id)
) c on c.student_id = p.student_id and least(c.hi, p.hi) > greatest(c.lo, p.lo)
join groups g on g.id = c.group_id;

-- One definition of "how much is owed", used by every screen and report.
-- What each charge has been paid so far, and what's left of it.
create view charge_balances as
select c.id as charge_id, c.enrollment_id, e.student_id, e.group_id, c.period_start, c.period_end, c.due_date,
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
