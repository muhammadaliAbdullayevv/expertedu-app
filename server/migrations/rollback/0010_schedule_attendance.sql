-- Rollback for 0010_schedule_attendance.sql. LOSES every group's weekly
-- schedule and all attendance marks. Take a pg_dump first.
drop table attendance;
drop table lessons;
drop table group_schedules;
