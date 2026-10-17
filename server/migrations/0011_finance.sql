-- Finance (owner only): teachers paid a percentage of what their groups'
-- students pay, center expenses, and profit.

-- A teacher's share of their students' payments, in percent. Null = not
-- paid by percentage (not counted in salaries).
alter table teachers add column salary_percent numeric(5, 2)
  check (salary_percent is null or salary_percent between 0 and 100);

-- Which teacher a payment counts towards: the group's teacher when the
-- payment was made, kept so a later change of teacher doesn't move past
-- months' salaries. Set by the trigger below for every payment, however
-- it's recorded.
alter table transactions add column teacher_id bigint references teachers(id);

create function transactions_payment_teacher() returns trigger language plpgsql as $$
begin
  if new.kind = 'payment' and new.teacher_id is null then
    select g.teacher_id into new.teacher_id
    from enrollments e join groups g on g.id = e.group_id
    where e.id = new.enrollment_id;
  end if;
  return new;
end;
$$;
create trigger transactions_payment_teacher
  before insert on transactions
  for each row execute function transactions_payment_teacher();

-- Existing payments: their group's teacher now -- the best record there is.
update transactions t
set teacher_id = g.teacher_id
from enrollments e join groups g on g.id = e.group_id
where e.id = t.enrollment_id and t.kind = 'payment' and t.teacher_id is null;

create index idx_transactions_payment_teacher on transactions (teacher_id, occurred_at) where kind = 'payment';

-- Money the center spends. Never deleted: a mistake is voided, with who,
-- when and why, and voided rows count nowhere.
create table expenses (
  id bigserial primary key,
  category text not null
    check (category in ('salary', 'rent', 'utilities', 'marketing', 'supplies', 'tax', 'other')),
  amount bigint not null check (amount > 0),
  spent_on date not null,
  note text,
  method text check (method in ('cash', 'card', 'click_payme')),
  -- Salary payouts: whose, and for which month (its first day).
  teacher_id bigint references teachers(id),
  salary_month date,
  created_by bigint references users(id),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by bigint references users(id),
  void_reason text,
  constraint expenses_salary_fields check (
    (category = 'salary') = (teacher_id is not null and salary_month is not null)
  ),
  constraint expenses_salary_month_first check (salary_month is null or extract(day from salary_month) = 1)
);
create index idx_expenses_spent_on on expenses (spent_on) where voided_at is null;
create index idx_expenses_salary on expenses (teacher_id, salary_month) where category = 'salary' and voided_at is null;
