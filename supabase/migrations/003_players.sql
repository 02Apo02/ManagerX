-- ManagerX
-- Migration: 003
-- Name: players
-- Description: GLOBAL player identities. No team_id here: ownership and
--              team-specific state live in team_players (004).
-- Depends on: 001_profiles (set_updated_at)

create table public.players (
  id          uuid primary key default gen_random_uuid(),
  name        text        not null,
  "position"  text        not null,
  age         smallint    not null,
  nationality text        not null,
  overall     smallint    not null,
  potential   smallint    not null,
  pace        smallint    not null,
  shooting    smallint    not null,
  passing     smallint    not null,
  dribbling   smallint    not null,
  defending   smallint    not null,
  physical    smallint    not null,
  -- Soft lifecycle instead of DELETE (history tables reference players).
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint players_name_length_chk
    check (name = btrim(name) and char_length(name) between 2 and 80),
  constraint players_position_chk
    check ("position" in ('GK','LB','CB','RB','LWB','RWB','DM','CM','AM','LW','RW','CF','ST')),
  constraint players_age_chk check (age between 15 and 45),
  constraint players_nationality_length_chk
    check (nationality = btrim(nationality) and char_length(nationality) between 2 and 56),
  constraint players_overall_chk check (overall between 1 and 100),
  constraint players_potential_chk check (potential between 1 and 100),
  constraint players_potential_gte_overall_chk check (potential >= overall),
  constraint players_pace_chk check (pace between 1 and 100),
  constraint players_shooting_chk check (shooting between 1 and 100),
  constraint players_passing_chk check (passing between 1 and 100),
  constraint players_dribbling_chk check (dribbling between 1 and 100),
  constraint players_defending_chk check (defending between 1 and 100),
  constraint players_physical_chk check (physical between 1 and 100),
  constraint players_status_chk check (status in ('active', 'retired'))
);

comment on table public.players is
  'Global player identity and base ratings. players.id never changes on transfer.';

create trigger players_set_updated_at
  before update on public.players
  for each row execute function public.set_updated_at();
