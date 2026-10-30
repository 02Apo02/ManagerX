-- ManagerX
-- Migration: 011
-- Name: competitions
-- Description: Competitions (league / cup / friendly / tournament) inside a
--              season, plus the registry of participating teams.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 009_seasons, 010_leagues

create table public.competitions (
  id               uuid primary key default gen_random_uuid(),
  season_id        uuid        not null references public.seasons (id) on delete restrict,
  league_id        uuid,
  name             text        not null,
  competition_type text        not null,
  status           text        not null default 'scheduled',
  starts_at        timestamptz,
  ends_at          timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Composite FK: a linked league must belong to the SAME season.
  -- (MATCH SIMPLE: skipped while league_id is NULL, e.g. cups.)
  constraint competitions_league_season_fkey
    foreign key (league_id, season_id)
    references public.leagues (id, season_id),
  constraint competitions_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 80),
  constraint competitions_type_chk
    check (competition_type in ('league', 'cup', 'friendly', 'tournament')),
  constraint competitions_status_chk
    check (status in ('scheduled', 'active', 'completed', 'cancelled')),
  constraint competitions_league_requires_league_id_chk
    check (competition_type <> 'league' or league_id is not null),
  constraint competitions_time_order_chk
    check (starts_at is null or ends_at is null or ends_at > starts_at)
);

create unique index competitions_season_name_lower_key
  on public.competitions (season_id, lower(name));

-- A league has exactly one 'league' competition.
create unique index competitions_one_league_competition_key
  on public.competitions (league_id)
  where competition_type = 'league';

create trigger competitions_set_updated_at
  before update on public.competitions
  for each row execute function public.set_updated_at();

create table public.competition_teams (
  competition_id uuid        not null references public.competitions (id) on delete restrict,
  team_id        uuid        not null references public.teams (id)        on delete restrict,
  joined_at      timestamptz not null default now(),
  constraint competition_teams_pkey primary key (competition_id, team_id)
);

comment on table public.competition_teams is
  'Teams registered in a competition. Fixtures may only use registered teams (trigger in 026).';
