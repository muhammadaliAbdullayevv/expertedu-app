-- Student intake: a new student is added straight into a group, with an
-- optional per-enrollment discount, parent phone, lead source, and first
-- payment (with its method). Only new nullable columns -- nothing existing
-- changes meaning, and old app builds keep working.

-- Seats per group, for "11/15" and "To'lgan". Null = no limit.
alter table groups add column capacity int check (capacity > 0);

alter table students add column parent_phone text;
alter table students add column heard_from text
  check (heard_from in ('instagram', 'telegram', 'referral', 'walk_in', 'other'));

-- 'amount' = so'm off each month; 'percent' = whole percent off, so it
-- follows the group's fee if that changes later. Both set or both null.
alter table enrollments add column discount_kind text check (discount_kind in ('amount', 'percent'));
alter table enrollments add column discount_value bigint check (discount_value >= 0);
alter table enrollments add constraint enrollments_discount_pair
  check ((discount_kind is null) = (discount_value is null));
alter table enrollments add constraint enrollments_discount_percent_max
  check (discount_kind is distinct from 'percent' or discount_value <= 100);

-- Existing payments keep method = null (shown as "-").
alter table transactions add column method text check (method in ('cash', 'card', 'click_payme'));

-- One student per phone number. Phones are compared and stored digits-only
-- (998 + 9 digits) -- the same rule as app/phone.py normalize(). The app
-- already saves them that way; normalize anything that slipped through,
-- then enforce it. Fails (and rolls the whole file back) if two students
-- share a number -- check for that before running.
update students
set phone = case
  when length(regexp_replace(phone, '\D', '', 'g')) = 9 then '998' || regexp_replace(phone, '\D', '', 'g')
  else regexp_replace(phone, '\D', '', 'g')
end
where phone ~ '\D' or length(phone) = 9;

create unique index uq_students_phone on students (phone);
