-- ManagerX
-- Migration: 023
-- Name: anti_cheat_events
-- Description: Game-security events (suspicious behaviour, rate-limit hits,
--              transfer anomalies, reward abuse). NOT the same as audit_log (024).
-- Depends on: 001_profiles, 002_teams
--
-- Rows are never deleted. Only the review workflow columns (status,
-- reviewed_by, reviewed_at) may change, by backend/admin code.

create table public.anti_cheat_events (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid        references public.profiles (id) on delete restrict,
  team_id     uuid        references public.teams (id)    on delete restrict,
  event_type  text        not null,
  severity    text        not null default 'low',
  metadata    jsonb       not null default '{}'::jsonb,
  status      text        not null default 'open',
  reviewed_by uuid        references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint anti_cheat_events_type_format_chk
    check (event_type ~ '^[a-z][a-z0-9_.]{1,59}$'),
  constraint anti_cheat_events_severity_chk
    check (severity in ('info', 'low', 'medium', 'high', 'critical')),
  constraint anti_cheat_events_status_chk
    check (status in ('open', 'reviewed', 'dismissed', 'actioned')),
  constraint anti_cheat_events_metadata_object_chk check (jsonb_typeof(metadata) = 'object'),
  constraint anti_cheat_events_review_fields_chk
    check ((status = 'open') = (reviewed_at is null))
);

comment on table public.anti_cheat_events is
  'Security event log. No client access at all (no policies, no grants).';

create trigger anti_cheat_events_block_delete
  before delete on public.anti_cheat_events
  for each row execute function public.prevent_row_mutation();

-- Only review-workflow columns are updatable.
create function public.anti_cheat_events_protect_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.profile_id is distinct from old.profile_id
     or new.team_id is distinct from old.team_id
     or new.event_type is distinct from old.event_type
     or new.severity is distinct from old.severity
     or new.metadata is distinct from old.metadata
     or new.created_at is distinct from old.created_at then
    raise exception 'anti_cheat_events evidence columns are immutable'
      using errcode = 'restrict_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.anti_cheat_events_protect_evidence() from public, anon, authenticated;

create trigger anti_cheat_events_protect_evidence
  before update on public.anti_cheat_events
  for each row execute function public.anti_cheat_events_protect_evidence();
