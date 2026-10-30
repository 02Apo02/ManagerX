-- ManagerX
-- Migration: 024
-- Name: audit_log
-- Description: Immutable system audit trail (admin actions, bans, rollbacks,
--              critical RPCs). Distinct from anti_cheat_events (023).
-- Depends on: 001_profiles (prevent_row_mutation)

create table public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  -- NULL actor = system / cron / Edge Function acting without a user.
  actor_id    uuid        references public.profiles (id) on delete restrict,
  action      text        not null,
  entity_type text        not null,
  entity_id   uuid,
  metadata    jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint audit_log_action_format_chk check (action ~ '^[a-z][a-z0-9_.:-]{1,79}$'),
  constraint audit_log_entity_type_format_chk check (entity_type ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint audit_log_metadata_object_chk check (jsonb_typeof(metadata) = 'object')
);

comment on table public.audit_log is
  'Immutable audit trail. No client access (no policies, no grants).';

create trigger audit_log_block_update
  before update on public.audit_log
  for each row execute function public.prevent_row_mutation();

create trigger audit_log_block_delete
  before delete on public.audit_log
  for each row execute function public.prevent_row_mutation();
