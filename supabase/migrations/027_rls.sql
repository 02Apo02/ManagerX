-- ManagerX
-- Migration: 027
-- Name: rls
-- Description: Enables RLS on every ManagerX table, resets table privileges and
--              grants clients only what they need (read-mostly, no critical writes).
-- Depends on: 001-026
--
-- Model
--  * anon: no access to any game table.
--  * authenticated: read public multiplayer data; read OWN economy/inventory/
--    training/tactics/rewards/notifications.
--  * Client writes are limited to: own profile (username, display_name), own
--    team name, own tactics, own notification is_read. Everything else
--    (wallet, ledger, transactions, ownership, transfers, listings, matches,
--    events, rewards, anti-cheat, audit) is written ONLY by security-definer
--    RPCs / Edge Functions using the service role.
--  * anti_cheat_events and audit_log: RLS on, no policies, no grants.
--  * Two layers: privileges (GRANT) AND policies (RLS). Both must allow.
--  * Columns telegram_id / role / status of profiles are NOT granted to clients.
--    Client code must therefore select explicit columns from profiles
--    (select=id,username,display_name and the other granted columns); select=* is rejected.

-- ---------------------------------------------------------------------------
-- 1. Enable RLS on all tables
-- ---------------------------------------------------------------------------
alter table public.profiles              enable row level security;
alter table public.teams                 enable row level security;
alter table public.players               enable row level security;
alter table public.team_players          enable row level security;
alter table public.wallets               enable row level security;
alter table public.inventory             enable row level security;
alter table public.training              enable row level security;
alter table public.tactics               enable row level security;
alter table public.seasons               enable row level security;
alter table public.leagues               enable row level security;
alter table public.competitions          enable row level security;
alter table public.competition_teams     enable row level security;
alter table public.fixtures              enable row level security;
alter table public.matches               enable row level security;
alter table public.match_events          enable row level security;
alter table public.transfers             enable row level security;
alter table public.transfer_listings     enable row level security;
alter table public.transactions          enable row level security;
alter table public.economy_ledger        enable row level security;
alter table public.notifications         enable row level security;
alter table public.daily_reward_schedule enable row level security;
alter table public.daily_reward_state    enable row level security;
alter table public.daily_reward_claims   enable row level security;
alter table public.shop_items            enable row level security;
alter table public.player_market         enable row level security;
alter table public.player_market_history enable row level security;
alter table public.anti_cheat_events     enable row level security;
alter table public.audit_log             enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Reset privileges on ManagerX tables only (other objects untouched)
-- ---------------------------------------------------------------------------
revoke all on table
  public.profiles, public.teams, public.players, public.team_players,
  public.wallets, public.inventory, public.training, public.tactics,
  public.seasons, public.leagues, public.competitions, public.competition_teams,
  public.fixtures, public.matches, public.match_events,
  public.transfers, public.transfer_listings,
  public.transactions, public.economy_ledger,
  public.notifications,
  public.daily_reward_schedule, public.daily_reward_state, public.daily_reward_claims,
  public.shop_items, public.player_market, public.player_market_history,
  public.anti_cheat_events, public.audit_log
from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Grants for authenticated
-- ---------------------------------------------------------------------------
-- profiles: column-level SELECT hides telegram_id, role, status.
grant select (id, username, display_name, created_at, updated_at)
  on public.profiles to authenticated;
grant update (username, display_name) on public.profiles to authenticated;

grant select on public.teams to authenticated;
grant update (name) on public.teams to authenticated;

grant select on
  public.players, public.team_players,
  public.wallets, public.inventory, public.training, public.tactics,
  public.seasons, public.leagues, public.competitions, public.competition_teams,
  public.fixtures, public.matches, public.match_events,
  public.transfers, public.transfer_listings,
  public.transactions, public.economy_ledger,
  public.notifications,
  public.daily_reward_schedule, public.daily_reward_state, public.daily_reward_claims,
  public.shop_items, public.player_market, public.player_market_history
to authenticated;

grant update (formation, mentality, style, passing_style, pressing, defensive_line, tempo, width)
  on public.tactics to authenticated;
grant update (is_read) on public.notifications to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies
-- ---------------------------------------------------------------------------
-- profiles (multiplayer-readable; own row updatable; no insert/delete)
create policy profiles_select_authenticated on public.profiles
  for select to authenticated using (true);
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- teams
create policy teams_select_authenticated on public.teams
  for select to authenticated using (true);
create policy teams_update_own on public.teams
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

-- global / multiplayer-readable game data (read only)
create policy players_select_authenticated on public.players
  for select to authenticated using (true);
create policy team_players_select_authenticated on public.team_players
  for select to authenticated using (true);
create policy seasons_select_authenticated on public.seasons
  for select to authenticated using (true);
create policy leagues_select_authenticated on public.leagues
  for select to authenticated using (true);
create policy competitions_select_authenticated on public.competitions
  for select to authenticated using (true);
create policy competition_teams_select_authenticated on public.competition_teams
  for select to authenticated using (true);
create policy fixtures_select_authenticated on public.fixtures
  for select to authenticated using (true);
create policy matches_select_authenticated on public.matches
  for select to authenticated using (true);
create policy match_events_select_authenticated on public.match_events
  for select to authenticated using (true);
create policy transfers_select_authenticated on public.transfers
  for select to authenticated using (true);
create policy transfer_listings_select_authenticated on public.transfer_listings
  for select to authenticated using (true);
create policy daily_reward_schedule_select_authenticated on public.daily_reward_schedule
  for select to authenticated using (true);
create policy shop_items_select_active on public.shop_items
  for select to authenticated using (active);
create policy player_market_select_authenticated on public.player_market
  for select to authenticated using (true);
create policy player_market_history_select_authenticated on public.player_market_history
  for select to authenticated using (true);

-- owner-only data (team owned by the caller)
create policy wallets_select_own on public.wallets
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy inventory_select_own on public.inventory
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy training_select_own on public.training
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy tactics_select_own on public.tactics
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy tactics_update_own on public.tactics
  for update to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())))
  with check (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy transactions_select_own on public.transactions
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy economy_ledger_select_own on public.economy_ledger
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy daily_reward_state_select_own on public.daily_reward_state
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));
create policy daily_reward_claims_select_own on public.daily_reward_claims
  for select to authenticated
  using (team_id in (select t.id from public.teams t where t.owner_id = (select auth.uid())));

-- notifications (own only; only is_read is updatable, enforced by grant + trigger)
create policy notifications_select_own on public.notifications
  for select to authenticated using (profile_id = (select auth.uid()));
create policy notifications_update_own on public.notifications
  for update to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- anti_cheat_events, audit_log: intentionally NO policies and NO grants.
-- Only the service role / security-definer functions can touch them.
