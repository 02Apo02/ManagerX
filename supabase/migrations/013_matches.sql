-- ManagerX
-- Migration: 013
-- Name: matches
-- Description: The actual played match, exactly one per fixture.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 012_fixtures
--             (prevent_update_when_finalized)
--
-- Fixture <-> match: matches.fixture_id is UNIQUE and (fixture_id, home, away)
-- is a composite FK to fixtures, so a match can never disagree with its
-- fixture about who plays. The match is the source of truth for the result;
-- finish_match copies the score to the fixture in the same transaction.

create table public.matches (
  id           uuid primary key default gen_random_uuid(),
  fixture_id   uuid        not null,
  home_team_id uuid        not null,
  away_team_id uuid        not null,
  status       text        not null default 'scheduled',
  home_score   smallint,
  away_score   smallint,
  started_at   timestamptz,
  finished_at  timestamptz,
  -- Derived, cannot be written by anyone; always consistent with the scores.
  result       text generated always as (
    case
      when status <> 'completed' or home_score is null or away_score is null then null
      when home_score > away_score then 'home_win'
      when home_score < away_score then 'away_win'
      else 'draw'
    end
  ) stored,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint matches_fixture_id_key unique (fixture_id),
  constraint matches_fixture_teams_fkey
    foreign key (fixture_id, home_team_id, away_team_id)
    references public.fixtures (id, home_team_id, away_team_id),
  constraint matches_home_team_fkey foreign key (home_team_id) references public.teams (id) on delete restrict,
  constraint matches_away_team_fkey foreign key (away_team_id) references public.teams (id) on delete restrict,
  constraint matches_distinct_teams_chk check (home_team_id <> away_team_id),
  constraint matches_status_chk
    check (status in ('scheduled', 'live', 'completed', 'cancelled')),
  constraint matches_scores_non_negative_chk
    check ((home_score is null or home_score >= 0) and (away_score is null or away_score >= 0)),
  constraint matches_scores_pair_chk
    check ((home_score is null) = (away_score is null)),
  constraint matches_live_or_completed_has_scores_chk
    check (status not in ('live', 'completed') or home_score is not null),
  constraint matches_finished_at_chk
    check ((status = 'completed') = (finished_at is not null)),
  constraint matches_time_order_chk
    check (started_at is null or finished_at is null or finished_at >= started_at)
);

comment on table public.matches is
  'Played matches. Result fields are written only by play_match/finish_match RPCs; frozen once completed/cancelled.';

create trigger matches_set_updated_at
  before update on public.matches
  for each row execute function public.set_updated_at();

create trigger matches_freeze_finalized
  before update on public.matches
  for each row execute function public.prevent_update_when_finalized();
