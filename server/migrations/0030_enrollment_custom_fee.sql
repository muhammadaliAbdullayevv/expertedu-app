-- Custom monthly fee per student per enrollment (null = follow the group's fee_amount).
alter table enrollments add column if not exists custom_fee bigint check (custom_fee is null or custom_fee >= 0);

