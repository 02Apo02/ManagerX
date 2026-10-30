-- ManagerX
-- Migration: 010
-- Name: leagues
-- Description: Leagues (divisions) belonging to a season.
-- Depends on: 001_profiles (set_updated_at), 009_seasons

create table public.leagues (
  id         uuid primary key default gen_random_uuid(),
  season_id  uuid        not null references public.seasons (id) on delete restrict,
  name       text        not null,
  tier       smallint    not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Target for competitions' composite FK (league must be in the same season).
  constraint leagues_id_season_id_key unique (id, season_id),
  constraint leagues_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 60),
  constraint leagues_tier_chk check (tier >= 1)
);

create unique index leagues_season_name_lower_key
  on public.leagues (season_id, lower(name));

create trigger leagues_set_updated_at
  before update on public.leagues
  for each row execute function public.set_updated_at();
