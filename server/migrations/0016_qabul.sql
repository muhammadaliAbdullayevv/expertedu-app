-- Qabul (V2): what a client wants, so a course can be found for them, and
-- the group fields the course finder searches on.

-- A group's level ("Beginner", "Elementary"...) and the day it started.
alter table groups add column level text;
alter table groups add column start_date date;

-- What the client asked for: the days they can come (ISO weekdays, 1 = Monday),
-- the part of the day, and the level. Saved with the inquiry.
alter table leads add column desired_weekdays smallint[]
  check (desired_weekdays is null or desired_weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]);
alter table leads add column desired_time_of_day text
  check (desired_time_of_day in ('morning', 'afternoon', 'evening'));
alter table leads add column level text;
