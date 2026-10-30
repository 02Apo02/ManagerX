-- ManagerX
-- Migration: 022
-- Name: player_market
-- Description: Global market valuation per player plus append-only valuation
--              history (auto-recorded by trigger).
-- Depends on: 001_profiles (set_updated_at, prevent_row_mutation), 003_players

create table public.player_market (
  player_id        uuid        primary key references public.players (id) on delete restrict,
  market_value     bigint      not null,
  value_updated_at timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint player_market_value_chk check (market_value > 0)
);

comment on table public.player_market is
  'Current market value per player. Changed only by server jobs/RPCs; history is automatic.';

create trigger player_market_set_updated_at
  before update on public.player_market
  for each row execute function public.set_updated_at();

create table public.player_market_history (
  id             uuid primary key default gen_random_uuid(),
  player_id      uuid        not null references public.players (id) on delete restrict,
  previous_value bigint,
  new_value      bigint      not null,
  reason         text        not null,
  created_at     timestamptz not null default now(),
  constraint player_market_history_previous_chk
    check (previous_value is null or previous_value > 0),
  constraint player_market_history_new_chk check (new_value > 0),
  constraint player_market_history_reason_chk
    check (reason in ('initial', 'revaluation'))
);

create trigger player_market_history_block_update
  before update on public.player_market_history
  for each row execute function public.prevent_row_mutation();

create trigger player_market_history_block_delete
  before delete on public.player_market_history
  for each row execute function public.prevent_row_mutation();

-- Every value change (and the first value) is recorded, so history can never
-- be forgotten by an RPC.
create function public.record_player_market_value()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.player_market_history (player_id, previous_value, new_value, reason)
    values (new.player_id, null, new.market_value, 'initial');
  elsif new.market_value is distinct from old.market_value then
    new.value_updated_at := now();
    insert into public.player_market_history (player_id, previous_value, new_value, reason)
    values (new.player_id, old.market_value, new.market_value, 'revaluation');
  end if;
  return new;
end;
$$;

revoke all on function public.record_player_market_value() from public, anon, authenticated;

-- BEFORE trigger so value_updated_at can be set on the row; the history insert
-- targets another table, so it is safe. player_id is a PK of the same row, the
-- FK to players is validated before the history row is written.
create trigger player_market_record_value
  before insert or update of market_value on public.player_market
  for each row execute function public.record_player_market_value();
