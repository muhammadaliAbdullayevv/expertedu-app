-- A phone/walk-in inquiry -- lighter-weight than a Student, logged the
-- moment an operator takes the call, before anyone has committed to a
-- group. Converting one creates a real Student (see routes/inquiries.py).
create table inquiries (
  id bigserial primary key,
  full_name text not null,
  phone text not null,
  note text,
  subject_id bigint references subjects(id),
  trial_date date,
  status text not null check (status in ('new','contacted','scheduled','converted','lost')) default 'new',
  converted_student_id bigint references students(id),
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create index idx_inquiries_status on inquiries(status);
