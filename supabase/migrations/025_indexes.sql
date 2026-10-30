-- ManagerX
-- Migration: 025
-- Name: indexes
-- Description: Additional performance indexes (FK columns, status, created_at,
--              market and notification lookups).
-- Depends on: 001-024
--
-- Already provided by PK / UNIQUE constraints in earlier migrations and
-- therefore NOT repeated here: profiles(telegram_id), teams(owner_id),
-- teams(lower(name)), team_players(team_id) via PK prefix,
-- team_players(player_id), wallets(team_id), inventory(team_id,item_id),
-- training(player_id) open-only, seasons(season_number, name), leagues(season_id, name),
-- competitions(season_id, name), fixtures(competition_id, round),
-- matches(fixture_id), transfer_listings(player_id) active-only and
-- (transfer_id), transactions(idempotency_key), economy_ledger(seq) and
-- (transaction_id,wallet_id), daily_reward_claims(team_id,claim_date),
-- shop_items(code).

-- profiles
create index profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;

-- players
create index players_position_overall_idx
  on public.players ("position", overall desc);

-- team_players
create index team_players_team_squad_status_idx
  on public.team_players (team_id, squad_status);

-- inventory
create index inventory_item_id_idx on public.inventory (item_id);

-- training
create index training_team_status_idx on public.training (team_id, status);
create index training_player_created_idx on public.training (player_id, created_at desc);
create index training_open_finishes_at_idx
  on public.training (finishes_at)
  where status in ('queued', 'active');

-- seasons / competitions
create index seasons_starts_at_idx on public.seasons (starts_at);
create index competitions_league_id_idx
  on public.competitions (league_id)
  where league_id is not null;
create index competitions_season_status_idx on public.competitions (season_id, status);
create index competition_teams_team_id_idx on public.competition_teams (team_id);

-- fixtures
create index fixtures_home_team_idx on public.fixtures (home_team_id);
create index fixtures_away_team_idx on public.fixtures (away_team_id);
create index fixtures_competition_scheduled_idx
  on public.fixtures (competition_id, scheduled_at);
create index fixtures_status_scheduled_idx on public.fixtures (status, scheduled_at);

-- matches
create index matches_home_team_idx on public.matches (home_team_id);
create index matches_away_team_idx on public.matches (away_team_id);
create index matches_status_idx on public.matches (status);

-- match_events
create index match_events_match_minute_idx
  on public.match_events (match_id, minute, added_minute);
create index match_events_team_idx on public.match_events (team_id);
create index match_events_player_idx on public.match_events (player_id);

-- transfers
create index transfers_player_created_idx on public.transfers (player_id, created_at desc);
create index transfers_from_team_idx on public.transfers (from_team_id) where from_team_id is not null;
create index transfers_to_team_idx on public.transfers (to_team_id) where to_team_id is not null;
create index transfers_created_at_idx on public.transfers (created_at desc);

-- transfer_listings
create index transfer_listings_seller_idx on public.transfer_listings (seller_team_id);
create index transfer_listings_buyer_idx
  on public.transfer_listings (buyer_team_id)
  where buyer_team_id is not null;
create index transfer_listings_player_idx on public.transfer_listings (player_id);
create index transfer_listings_active_expires_idx
  on public.transfer_listings (expires_at)
  where status = 'active';
create index transfer_listings_active_price_idx
  on public.transfer_listings (price)
  where status = 'active';

-- transactions
create index transactions_team_created_idx on public.transactions (team_id, created_at desc);
create index transactions_reference_idx
  on public.transactions (reference_type, reference_id)
  where reference_id is not null;
create index transactions_type_created_idx
  on public.transactions (transaction_type, created_at desc);

-- economy_ledger
create index economy_ledger_wallet_seq_idx on public.economy_ledger (wallet_id, seq desc);
create index economy_ledger_team_created_idx on public.economy_ledger (team_id, created_at desc);
create index economy_ledger_reference_idx
  on public.economy_ledger (reference_type, reference_id)
  where reference_id is not null;

-- notifications
create index notifications_profile_created_idx
  on public.notifications (profile_id, created_at desc);
create index notifications_profile_unread_idx
  on public.notifications (profile_id, created_at desc)
  where is_read = false;

-- daily rewards / shop / market
create index daily_reward_claims_transaction_idx
  on public.daily_reward_claims (transaction_id)
  where transaction_id is not null;
create index shop_items_active_type_idx on public.shop_items (item_type) where active;
create index player_market_value_idx on public.player_market (market_value);
create index player_market_history_player_created_idx
  on public.player_market_history (player_id, created_at desc);

-- anti_cheat_events
create index anti_cheat_events_profile_created_idx
  on public.anti_cheat_events (profile_id, created_at desc)
  where profile_id is not null;
create index anti_cheat_events_team_created_idx
  on public.anti_cheat_events (team_id, created_at desc)
  where team_id is not null;
create index anti_cheat_events_type_created_idx
  on public.anti_cheat_events (event_type, created_at desc);
create index anti_cheat_events_open_severity_idx
  on public.anti_cheat_events (severity, created_at desc)
  where status = 'open';

-- audit_log
create index audit_log_actor_created_idx
  on public.audit_log (actor_id, created_at desc)
  where actor_id is not null;
create index audit_log_entity_idx on public.audit_log (entity_type, entity_id);
create index audit_log_action_created_idx on public.audit_log (action, created_at desc);
create index audit_log_created_at_idx on public.audit_log (created_at desc);
