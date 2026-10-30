-- ManagerX
-- Migration: 002
-- Name: teams
-- Description: Teams owned by profiles (one team per profile for now).
-- Depends on: 001_profiles (profiles, set_updated_at)

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid        not null references public.profiles (id) on delete restrict,
  name       text        not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- One team per profile today. Dropping this single constraint is all that is
  -- needed to allow multiple teams per profile later.
  constraint teams_owner_id_key unique (owner_id),
  constraint teams_name_length_chk
    check (name = btrim(name) and char_length(name) between 3 and 40)
);

-- Case-insensitive unique team name ("Ankara FC" == "ankara fc").
create unique index teams_name_lower_key on public.teams (lower(name));

comment on table public.teams is
  'Teams. Created only through the create_team RPC (no client INSERT).';

create trigger teams_set_updated_at
  before update on public.teams
  for each row execute function public.set_updated_at();
