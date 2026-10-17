-- Center-wide settings (one row) and the audit log. Phase 1 of the V2 money rework.

-- Missing row = these defaults (see app/money/service.py get_settings).
-- Billing is per group, not here (0015).
create table app_settings (
  id boolean primary key default true check (id),
  -- Free trial lessons one person may have; only the owner can allow more.
  trial_limit_per_person smallint not null default 1 check (trial_limit_per_person >= 1),
  updated_by bigint references users(id),
  updated_at timestamptz not null default now()
);

-- Who did what, and why. Written by the domain layer on every cancel,
-- reversal, archive, month closing and settings or percent change. Never
-- updated or deleted.
create table audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  user_id bigint references users(id),
  entity text not null,
  entity_id bigint,
  action text not null,
  reason text,
  before jsonb,
  after jsonb
);
create index idx_audit_log_entity on audit_log (entity, entity_id, at);

create function audit_log_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end;
$$;
create trigger audit_log_append_only
  before update or delete on audit_log
  for each row execute function audit_log_append_only();
