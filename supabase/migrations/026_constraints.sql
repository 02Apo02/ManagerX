-- ManagerX
-- Migration: 026
-- Name: constraints
-- Description: Forward foreign keys that could not be declared earlier, and
--              cross-table integrity rules (triggers).
-- Depends on: 001-025 (shop_items 021, competitions 011, fixtures 012,
--             matches 013, match_events 014, transfer_listings 016,
--             wallets 005, economy_ledger 018, team_players 004)
--
-- Forward FK resolution (the only forward references in the schema):
--   inventory.item_id              -> shop_items (inventory 006 < shop_items 021)
--   daily_reward_schedule.item_id  -> shop_items (020 < 021)
--   daily_reward_claims.item_id    -> shop_items (020 < 021)
-- Every other FK points to an earlier migration. There are no circular FKs.

-- ---------------------------------------------------------------------------
-- Forward foreign keys
-- ---------------------------------------------------------------------------
alter table public.inventory
  add constraint inventory_item_id_fkey
  foreign key (item_id) references public.shop_items (id) on delete restrict;

alter table public.daily_reward_schedule
  add constraint daily_reward_schedule_item_id_fkey
  foreign key (item_id) references public.shop_items (id) on delete restrict;

alter table public.daily_reward_claims
  add constraint daily_reward_claims_item_id_fkey
  foreign key (item_id) references public.shop_items (id) on delete restrict;

-- ---------------------------------------------------------------------------
-- match_events.team_id must be the home or away team of the match
-- ---------------------------------------------------------------------------
create function public.match_events_validate_team()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_home uuid;
  v_away uuid;
begin
  select m.home_team_id, m.away_team_id
    into v_home, v_away
    from public.matches m
   where m.id = new.match_id;

  if not found then
    raise exception 'match % does not exist', new.match_id
      using errcode = 'foreign_key_violation';
  end if;

  if new.team_id is distinct from v_home and new.team_id is distinct from v_away then
    raise exception 'team % does not play in match %', new.team_id, new.match_id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

revoke all on function public.match_events_validate_team() from public, anon, authenticated;

create trigger match_events_validate_team
  before insert on public.match_events
  for each row execute function public.match_events_validate_team();

-- ---------------------------------------------------------------------------
-- Fixtures may only use teams registered in the competition
-- ---------------------------------------------------------------------------
create function public.fixtures_validate_participants()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.competition_teams ct
     where ct.competition_id = new.competition_id and ct.team_id = new.home_team_id
  ) then
    raise exception 'home team % is not registered in competition %',
      new.home_team_id, new.competition_id
      using errcode = 'check_violation';
  end if;

  if not exists (
    select 1 from public.competition_teams ct
     where ct.competition_id = new.competition_id and ct.team_id = new.away_team_id
  ) then
    raise exception 'away team % is not registered in competition %',
      new.away_team_id, new.competition_id
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

revoke all on function public.fixtures_validate_participants() from public, anon, authenticated;

create trigger fixtures_validate_participants
  before insert or update of competition_id, home_team_id, away_team_id on public.fixtures
  for each row execute function public.fixtures_validate_participants();

-- ---------------------------------------------------------------------------
-- A team can only list a player it currently owns
-- ---------------------------------------------------------------------------
create function public.transfer_listings_validate_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'active' and not exists (
    select 1 from public.team_players tp
     where tp.team_id = new.seller_team_id and tp.player_id = new.player_id
  ) then
    raise exception 'team % does not own player %', new.seller_team_id, new.player_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.transfer_listings_validate_owner() from public, anon, authenticated;

create trigger transfer_listings_validate_owner
  before insert on public.transfer_listings
  for each row execute function public.transfer_listings_validate_owner();

-- ---------------------------------------------------------------------------
-- Wallet <-> ledger integrity, checked at COMMIT (deferred)
-- wallets.balance must equal the balance_after of the wallet's latest ledger
-- entry (0 when it has none). This makes "money moved without a ledger row"
-- and "ledger row without a wallet update" impossible to commit, so partial
-- economic states cannot persist. RPCs lock the wallet row (SELECT FOR
-- UPDATE) before writing, which keeps seq order consistent per wallet.
-- ---------------------------------------------------------------------------
create function public.assert_wallet_matches_ledger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_balance   bigint;
  v_last      bigint;
begin
  if tg_table_name = 'wallets' then
    v_wallet_id := new.id;
    v_balance   := new.balance;
  else
    v_wallet_id := new.wallet_id;
    select w.balance into v_balance from public.wallets w where w.id = v_wallet_id;
  end if;

  select l.balance_after
    into v_last
    from public.economy_ledger l
   where l.wallet_id = v_wallet_id
   order by l.seq desc
   limit 1;

  if v_last is null then
    v_last := 0;
  end if;

  if v_balance is distinct from v_last then
    raise exception 'wallet % balance % does not match ledger balance %',
      v_wallet_id, v_balance, v_last
      using errcode = 'integrity_constraint_violation';
  end if;

  return null;
end;
$$;

revoke all on function public.assert_wallet_matches_ledger() from public, anon, authenticated;

create constraint trigger wallets_match_ledger
  after insert or update of balance on public.wallets
  deferrable initially deferred
  for each row execute function public.assert_wallet_matches_ledger();

create constraint trigger economy_ledger_match_wallet
  after insert on public.economy_ledger
  deferrable initially deferred
  for each row execute function public.assert_wallet_matches_ledger();
