-- ManagerX
-- Migration: 014
-- Name: match_events
-- Description: Append-only timeline of match events.
-- Depends on: 001_profiles (prevent_row_mutation), 002_teams, 003_players, 013_matches
--
-- "Event team must be the home or away team of the match" cannot be a plain
-- CHECK/FK (needs a cross-table lookup); it is enforced by a trigger in 026.

create table public.match_events (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid        not null references public.matches (id) on delete restrict,
  team_id      uuid        not null references public.teams (id)   on delete restrict,
  player_id    uuid        not null references public.players (id) on delete restrict,
  event_type   text        not null,
  minute       smallint    not null,
  added_minute smallint    not null default 0,
  metadata     jsonb       not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  constraint match_events_type_chk
    check (event_type in (
      'goal', 'own_goal', 'assist', 'yellow_card', 'red_card', 'second_yellow',
      'substitution', 'injury', 'penalty_scored', 'penalty_missed', 'penalty_saved'
    )),
  constraint match_events_minute_chk check (minute between 0 and 150),
  constraint match_events_added_minute_chk check (added_minute between 0 and 30),
  constraint match_events_metadata_object_chk check (jsonb_typeof(metadata) = 'object')
);

comment on table public.match_events is
  'Immutable match timeline. Written only by match simulation RPCs.';

create trigger match_events_block_update
  before update on public.match_events
  for each row execute function public.prevent_row_mutation();

create trigger match_events_block_delete
  before delete on public.match_events
  for each row execute function public.prevent_row_mutation();
