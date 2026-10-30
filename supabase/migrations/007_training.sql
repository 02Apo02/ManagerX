-- ManagerX
-- Migration: 007
-- Name: training
-- Description: Training queue. Composite FK guarantees a team can only train
--              players it currently owns; at most one open training per player.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 003_players, 004_team_players
--
-- Notes for RPCs (start_training / finish_training / cancel_training):
--  * started_at / finishes_at must be computed server-side from now().
--  * The composite FK uses NO ACTION on update/delete: a transfer/release RPC
--    must cancel open trainings of the player BEFORE moving/removing the
--    team_players row (otherwise the FK blocks it, which prevents orphaned
--    training rows).

create table public.training (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid        not null,
  player_id     uuid        not null,
  training_type text        not null,
  status        text        not null default 'queued',
  started_at    timestamptz not null default now(),
  finishes_at   timestamptz not null,
  completed_at  timestamptz,
  cancelled_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint training_team_player_fkey
    foreign key (team_id, player_id)
    references public.team_players (team_id, player_id),
  constraint training_type_chk
    check (training_type in ('general','fitness','recovery','pace','shooting','passing','dribbling','defending','physical')),
  constraint training_status_chk
    check (status in ('queued', 'active', 'completed', 'cancelled')),
  constraint training_time_order_chk check (finishes_at > started_at),
  constraint training_completed_at_chk
    check ((status = 'completed') = (completed_at is not null)),
  constraint training_cancelled_at_chk
    check ((status = 'cancelled') = (cancelled_at is not null))
);

-- A player can have at most one open (queued/active) training at a time.
create unique index training_one_open_per_player_key
  on public.training (player_id)
  where status in ('queued', 'active');

comment on table public.training is
  'Training queue. Completion/cancellation only via RPC using server time.';

create trigger training_set_updated_at
  before update on public.training
  for each row execute function public.set_updated_at();
