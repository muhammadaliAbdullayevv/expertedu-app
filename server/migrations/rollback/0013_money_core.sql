-- `transactions` is kept untouched by 0013, so this only drops the new
-- tables (losing anything recorded in them after 0013).
drop view student_balances;
drop view enrollment_balances;
drop view charge_balances;
drop table payment_allocations;
drop table payments;
drop table charges;
drop sequence payment_receipt_seq;
drop function allocations_append_only();
drop function money_never_deleted();
