-- ManagerX
-- Migration: 015
-- Name: transfers
-- Description: Immutable history of player movements between teams.
-- Depends on: 001_profiles (prevent_row_mutation), 002_teams, 003_players
--
-- The CURRENT owner is never stored here or in players; it is team_players.
-- A completed transfer is: team_players ownership change + one row here +
-- transactions/economy_ledger rows (buyer and seller) + listing completion,
-- all in ONE PostgreSQL transaction (buy_player RPC). Money rows reference
-- this row through transactions.reference_type = 'transfer'.
--
-- Nullable from/to: from_team_id is NULL for initial assignment / free agents,
-- to_team_id is NULL when a player is released. Loans are covered by the
-- 'loan' / 'loan_return' types.

create table public.transfers (
  id           uuid primary key default gen_random_uuid(),
  player_id    uuid        not null references public.players (id) on delete restrict,
  from_team_id uuid        references public.teams (id) on delete restrict,
  to_team_id   uuid        references public.teams (id) on delete restrict,
  price        bigint      not null default 0,
  transfer_type text       not null default 'transfer',
  created_at   timestamptz not null default now(),
  -- Target for transfer_listings' composite FK (listing.transfer_id + player_id).
  constraint transfers_id_player_id_key unique (id, player_id),
  constraint transfers_price_chk check (price >= 0),
  constraint transfers_type_chk
    check (transfer_type in ('transfer', 'free', 'loan', 'loan_return', 'release', 'initial')),
  constraint transfers_has_team_chk
    check (from_team_id is not null or to_team_id is not null),
  constraint transfers_distinct_teams_chk
    check (from_team_id is distinct from to_team_id)
);

comment on table public.transfers is
  'Immutable transfer history. Ownership validation (from_team_id == current owner) is done inside the transfer RPC transaction.';

create trigger transfers_block_update
  before update on public.transfers
  for each row execute function public.prevent_row_mutation();

create trigger transfers_block_delete
  before delete on public.transfers
  for each row execute function public.prevent_row_mutation();
