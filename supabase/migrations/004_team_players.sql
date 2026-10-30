-- ManagerX
-- Migration: 004
-- Name: team_players
-- Description: Current ownership of a player by a team plus team-specific
--              player state (level, morale, fitness, lineup slot, etc.).
-- Depends on: 001_profiles (set_updated_at), 002_teams, 003_players
--
-- Design notes
--  * player_id is UNIQUE: a player belongs to exactly one team at a time.
--  * Transfer = the ownership row is moved/replaced by an RPC inside one
--    transaction; players.id is never touched, transfers keeps the history.
--  * Loans (future): add an owner_team_id column here (or a loans table);
--    this table then means "current squad", NOT permanent ownership.
--    Nothing here models a loan as permanent ownership.

create table public.team_players (
  team_id           uuid        not null references public.teams (id)   on delete restrict,
  player_id         uuid        not null references public.players (id) on delete restrict,
  acquired_at       timestamptz not null default now(),
  acquired_price    bigint      not null default 0,
  -- Team-specific state (NOT global player data):
  squad_status      text        not null default 'reserve',
  lineup_slot       smallint,
  level             smallint    not null default 1,
  experience        bigint      not null default 0,
  morale            smallint    not null default 70,
  fitness           smallint    not null default 100,
  form              smallint    not null default 50,
  condition         smallint    not null default 100,
  training_progress integer     not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint team_players_pkey primary key (team_id, player_id),
  constraint team_players_player_id_key unique (player_id),
  -- Deferrable so a lineup RPC can swap two slots inside one transaction.
  constraint team_players_team_lineup_slot_key
    unique (team_id, lineup_slot) deferrable initially immediate,
  constraint team_players_acquired_price_chk check (acquired_price >= 0),
  constraint team_players_squad_status_chk
    check (squad_status in ('starter', 'bench', 'reserve')),
  constraint team_players_lineup_slot_chk check (lineup_slot between 1 and 11),
  constraint team_players_starter_slot_chk
    check ((squad_status = 'starter') = (lineup_slot is not null)),
  constraint team_players_level_chk check (level between 1 and 100),
  constraint team_players_experience_chk check (experience >= 0),
  constraint team_players_morale_chk check (morale between 0 and 100),
  constraint team_players_fitness_chk check (fitness between 0 and 100),
  constraint team_players_form_chk check (form between 0 and 100),
  constraint team_players_condition_chk check (condition between 0 and 100),
  constraint team_players_training_progress_chk check (training_progress between 0 and 100)
);

comment on table public.team_players is
  'Current player ownership + team-specific state. Mutated only by server-side RPCs.';

create trigger team_players_set_updated_at
  before update on public.team_players
  for each row execute function public.set_updated_at();
