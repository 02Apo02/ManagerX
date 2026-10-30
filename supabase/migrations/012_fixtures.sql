-- ManagerX
-- Migration: 012
-- Name: fixtures
-- Description: Scheduled pairings inside a competition. A fixture is the plan;
--              the played game is a row in matches (013), 1:1 with the fixture.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 011_competitions

create table public.fixtures (
  id             uuid primary key default gen_random_uuid(),
  competition_id uuid        not null references public.competitions (id) on delete restrict,
  home_team_id   uuid        not null references public.teams (id)        on delete restrict,
  away_team_id   uuid        not null references public.teams (id)        on delete restrict,
  round          smallint    not null default 1,
  scheduled_at   timestamptz not null,
  status         text        not null default 'scheduled',
  home_score     smallint,
  away_score     smallint,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- Target for matches' composite FK (match teams must equal fixture teams).
  constraint fixtures_id_teams_key unique (id, home_team_id, away_team_id),
  -- No duplicate pairing in the same round of a competition.
  constraint fixtures_competition_round_teams_key
    unique (competition_id, round, home_team_id, away_team_id),
  constraint fixtures_distinct_teams_chk check (home_team_id <> away_team_id),
  constraint fixtures_round_chk check (round >= 1),
  constraint fixtures_status_chk
    check (status in ('scheduled', 'live', 'completed', 'cancelled')),
  constraint fixtures_scores_non_negative_chk
    check ((home_score is null or home_score >= 0) and (away_score is null or away_score >= 0)),
  constraint fixtures_scores_pair_chk
    check ((home_score is null) = (away_score is null)),
  constraint fixtures_completed_has_scores_chk
    check (status <> 'completed' or home_score is not null)
);

comment on table public.fixtures is
  'Planned pairings. Scores are copied from the finished match by RPC; never client-writable.';

create trigger fixtures_set_updated_at
  before update on public.fixtures
  for each row execute function public.set_updated_at();

-- Shared by fixtures (here), matches (013) and transfer_listings (016): once a
-- row reaches a final status (completed / cancelled / sold / expired) it is
-- frozen. Defined ONCE here.
create function public.prevent_update_when_finalized()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status in ('completed', 'cancelled', 'sold', 'expired') then
    raise exception '% row % is in final status % and can no longer be modified',
      tg_table_name, old.id, old.status
      using errcode = 'restrict_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_update_when_finalized() from public, anon, authenticated;

create trigger fixtures_freeze_finalized
  before update on public.fixtures
  for each row execute function public.prevent_update_when_finalized();
