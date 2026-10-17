-- Qabul (V2, fast form): the group a saved person was offered. Null = "guruhsiz".
-- A person saved here is still only a lead: no seat, no charge, no debt.
alter table leads add column group_id bigint references groups(id);
create index idx_leads_group on leads (group_id) where group_id is not null;
