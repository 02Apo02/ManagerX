-- ============================================================
-- FILE: supabase/migrations/001_profiles.sql
-- ============================================================
-- ManagerX
-- Migration: 001
-- Name: profiles
-- Description: Shared helper functions (set_updated_at, prevent_row_mutation),
--              profiles table, auth.users -> profiles provisioning trigger,
--              admin role helper.
-- Depends on: auth.users (Supabase system table)
--
-- UUID note: gen_random_uuid() is part of PostgreSQL core since v13, so no
-- extension (pgcrypto / uuid-ossp) is required on Supabase.

-- ---------------------------------------------------------------------------
-- Shared helper functions (defined ONCE here, reused by later migrations)
-- ---------------------------------------------------------------------------

-- Server-side updated_at. Client-supplied values are always overwritten.
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Used by append-only / history tables to block UPDATE and DELETE.
create function public.prevent_row_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% on %.% is not allowed: rows are immutable',
    tg_op, tg_table_schema, tg_table_name
    using errcode = 'restrict_violation';
  return null;
end;
$$;

revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.prevent_row_mutation() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  telegram_id  bigint      not null,
  username     text,
  display_name text        not null,
  -- Authorization role. NEVER writable by clients (column privileges in 027).
  role         text        not null default 'player',
  -- Soft account state (ban / suspend) instead of deleting rows.
  status       text        not null default 'active',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint profiles_telegram_id_key unique (telegram_id),
  constraint profiles_telegram_id_positive_chk check (telegram_id > 0),
  constraint profiles_username_format_chk
    check (username is null or username ~ '^[A-Za-z0-9_]{3,32}$'),
  constraint profiles_display_name_length_chk
    check (char_length(display_name) between 2 and 32 and display_name = btrim(display_name)),
  constraint profiles_role_chk check (role in ('player', 'moderator', 'admin')),
  constraint profiles_status_chk check (status in ('active', 'suspended', 'banned'))
);

comment on table public.profiles is
  'Game profile per auth user. telegram_id/role/status are server-managed and hidden from clients via column privileges.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- telegram_id and id are permanent identity: never changeable, not even by RPCs.
create function public.profiles_protect_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'profiles.id is immutable' using errcode = 'restrict_violation';
  end if;
  if new.telegram_id is distinct from old.telegram_id then
    raise exception 'profiles.telegram_id is immutable' using errcode = 'restrict_violation';
  end if;
  new.created_at := old.created_at;
  return new;
end;
$$;

revoke all on function public.profiles_protect_identity() from public, anon, authenticated;

create trigger profiles_protect_identity
  before update on public.profiles
  for each row execute function public.profiles_protect_identity();

-- ---------------------------------------------------------------------------
-- auth.users -> profiles provisioning
-- ---------------------------------------------------------------------------
-- SECURITY: telegram_id is read ONLY from raw_app_meta_data, which can be set
-- solely by the service role / admin API (the verified-initData Edge Function).
-- raw_user_meta_data is client-writable on self sign-up and is deliberately
-- NOT trusted. Users created without a valid telegram_id get no profile.
-- If the telegram_id already has a profile, the unique violation aborts the
-- auth user creation on purpose (fail closed, never silently link accounts).
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tg_text  text := new.raw_app_meta_data ->> 'telegram_id';
  v_username text := nullif(btrim(new.raw_app_meta_data ->> 'username'), '');
  v_display  text := btrim(coalesce(new.raw_app_meta_data ->> 'display_name', ''));
begin
  if v_tg_text is null or v_tg_text !~ '^[1-9][0-9]{0,14}$' then
    return new;
  end if;

  if v_username is not null and v_username !~ '^[A-Za-z0-9_]{3,32}$' then
    v_username := null;
  end if;

  v_display := btrim(left(v_display, 32));
  if char_length(v_display) < 2 then
    v_display := 'Manager' || right(v_tg_text, 6);
  end if;

  insert into public.profiles (id, telegram_id, username, display_name)
  values (new.id, v_tg_text::bigint, v_username, v_display);

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger managerx_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Admin helper (role lives in profiles.role, not client-editable)
-- ---------------------------------------------------------------------------
create function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
      and p.status = 'active'
  );
$$;

revoke all on function public.is_admin() from public, anon, authenticated;
grant execute on function public.is_admin() to authenticated;


-- ============================================================
-- FILE: supabase/migrations/002_teams.sql
-- ============================================================
-- ManagerX
-- Migration: 002
-- Name: teams
-- Description: Teams owned by profiles (one team per profile for now).
-- Depends on: 001_profiles (profiles, set_updated_at)

create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid        not null references public.profiles (id) on delete restrict,
  name       text        not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- One team per profile today. Dropping this single constraint is all that is
  -- needed to allow multiple teams per profile later.
  constraint teams_owner_id_key unique (owner_id),
  constraint teams_name_length_chk
    check (name = btrim(name) and char_length(name) between 3 and 40)
);

-- Case-insensitive unique team name ("Ankara FC" == "ankara fc").
create unique index teams_name_lower_key on public.teams (lower(name));

comment on table public.teams is
  'Teams. Created only through the create_team RPC (no client INSERT).';

create trigger teams_set_updated_at
  before update on public.teams
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/003_players.sql
-- ============================================================
-- ManagerX
-- Migration: 003
-- Name: players
-- Description: GLOBAL player identities. No team_id here: ownership and
--              team-specific state live in team_players (004).
-- Depends on: 001_profiles (set_updated_at)

create table public.players (
  id          uuid primary key default gen_random_uuid(),
  name        text        not null,
  "position"  text        not null,
  age         smallint    not null,
  nationality text        not null,
  overall     smallint    not null,
  potential   smallint    not null,
  pace        smallint    not null,
  shooting    smallint    not null,
  passing     smallint    not null,
  dribbling   smallint    not null,
  defending   smallint    not null,
  physical    smallint    not null,
  -- Soft lifecycle instead of DELETE (history tables reference players).
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint players_name_length_chk
    check (name = btrim(name) and char_length(name) between 2 and 80),
  constraint players_position_chk
    check ("position" in ('GK','LB','CB','RB','LWB','RWB','DM','CM','AM','LW','RW','CF','ST')),
  constraint players_age_chk check (age between 15 and 45),
  constraint players_nationality_length_chk
    check (nationality = btrim(nationality) and char_length(nationality) between 2 and 56),
  constraint players_overall_chk check (overall between 1 and 100),
  constraint players_potential_chk check (potential between 1 and 100),
  constraint players_potential_gte_overall_chk check (potential >= overall),
  constraint players_pace_chk check (pace between 1 and 100),
  constraint players_shooting_chk check (shooting between 1 and 100),
  constraint players_passing_chk check (passing between 1 and 100),
  constraint players_dribbling_chk check (dribbling between 1 and 100),
  constraint players_defending_chk check (defending between 1 and 100),
  constraint players_physical_chk check (physical between 1 and 100),
  constraint players_status_chk check (status in ('active', 'retired'))
);

comment on table public.players is
  'Global player identity and base ratings. players.id never changes on transfer.';

create trigger players_set_updated_at
  before update on public.players
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/004_team_players.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/005_wallets.sql
-- ============================================================
-- ManagerX
-- Migration: 005
-- Name: wallets
-- Description: One wallet per team holding ONLY the current balance (BIGINT).
--              History lives in transactions (017) / economy_ledger (018).
-- Depends on: 001_profiles (set_updated_at), 002_teams

create table public.wallets (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid        not null references public.teams (id) on delete restrict,
  balance    bigint      not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint wallets_team_id_key unique (team_id),
  -- Lets economy_ledger prove (wallet_id, team_id) agree via a composite FK.
  constraint wallets_id_team_id_key unique (id, team_id),
  constraint wallets_balance_non_negative_chk check (balance >= 0)
);

comment on table public.wallets is
  'Current balance only. Changed exclusively by server-side RPCs together with a transactions + economy_ledger row.';

create trigger wallets_set_updated_at
  before update on public.wallets
  for each row execute function public.set_updated_at();

-- Every team gets its wallet in the same statement/transaction as the team,
-- so a team without a wallet can never exist. Starting money is granted later
-- by the create_team RPC through the normal ledgered path (balance starts at 0).
create function public.create_wallet_for_new_team()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.wallets (team_id) values (new.id);
  return new;
end;
$$;

revoke all on function public.create_wallet_for_new_team() from public, anon, authenticated;

create trigger teams_create_wallet
  after insert on public.teams
  for each row execute function public.create_wallet_for_new_team();


-- ============================================================
-- FILE: supabase/migrations/006_inventory.sql
-- ============================================================
-- ManagerX
-- Migration: 006
-- Name: inventory
-- Description: Items owned by a team (one row per team + item).
-- Depends on: 001_profiles (set_updated_at), 002_teams
--
-- Circular/forward dependency: item_id references shop_items, which is only
-- created in 021. The foreign key is therefore added in 026_constraints.

create table public.inventory (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid        not null references public.teams (id) on delete restrict,
  item_id    uuid        not null,
  quantity   integer     not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_team_item_key unique (team_id, item_id),
  constraint inventory_quantity_chk check (quantity >= 0)
);

comment on table public.inventory is
  'Team item stock. Mutated only by server-side RPCs (shop purchase, item use, rewards).';

create trigger inventory_set_updated_at
  before update on public.inventory
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/007_training.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/008_tactics.sql
-- ============================================================
-- ManagerX
-- Migration: 008
-- Name: tactics
-- Description: One tactics row per team (team_id is the primary key).
-- Depends on: 001_profiles (set_updated_at), 002_teams
--
-- Formation is validated by shape only ("4-4-2", "4-2-3-1"); the exact list of
-- allowed formations lives in shared constants and is enforced by save_tactics.

create table public.tactics (
  team_id        uuid primary key references public.teams (id) on delete restrict,
  formation      text        not null default '4-4-2',
  mentality      text        not null default 'balanced',
  style          text        not null default 'balanced',
  passing_style  text        not null default 'mixed',
  pressing       smallint    not null default 50,
  defensive_line smallint    not null default 50,
  tempo          smallint    not null default 50,
  width          smallint    not null default 50,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint tactics_formation_format_chk
    check (formation ~ '^[1-9](-[1-9]){2,4}$'),
  constraint tactics_mentality_chk
    check (mentality in ('ultra_defensive','defensive','balanced','attacking','ultra_attacking')),
  constraint tactics_style_chk
    check (style in ('balanced','possession','counter','direct','wing_play')),
  constraint tactics_passing_style_chk
    check (passing_style in ('short','mixed','long')),
  constraint tactics_pressing_chk check (pressing between 0 and 100),
  constraint tactics_defensive_line_chk check (defensive_line between 0 and 100),
  constraint tactics_tempo_chk check (tempo between 0 and 100),
  constraint tactics_width_chk check (width between 0 and 100)
);

comment on table public.tactics is
  'Per-team tactics. Owner may update own row (RLS); rows are created by trigger.';

create trigger tactics_set_updated_at
  before update on public.tactics
  for each row execute function public.set_updated_at();

create function public.create_tactics_for_new_team()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.tactics (team_id) values (new.id);
  return new;
end;
$$;

revoke all on function public.create_tactics_for_new_team() from public, anon, authenticated;

create trigger teams_create_tactics
  after insert on public.teams
  for each row execute function public.create_tactics_for_new_team();


-- ============================================================
-- FILE: supabase/migrations/009_seasons.sql
-- ============================================================
-- ManagerX
-- Migration: 009
-- Name: seasons
-- Description: Seasons with a database-level guarantee of a single active season.
-- Depends on: 001_profiles (set_updated_at)

create table public.seasons (
  id            uuid primary key default gen_random_uuid(),
  name          text        not null,
  season_number integer     not null,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  status        text        not null default 'scheduled',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint seasons_season_number_key unique (season_number),
  constraint seasons_season_number_chk check (season_number > 0),
  constraint seasons_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 60),
  constraint seasons_time_order_chk check (ends_at > starts_at),
  constraint seasons_status_chk check (status in ('scheduled', 'active', 'completed'))
);

create unique index seasons_name_lower_key on public.seasons (lower(name));

-- Constant-expression partial unique index: at most ONE row may be 'active'.
create unique index seasons_single_active_key
  on public.seasons ((true))
  where status = 'active';

create trigger seasons_set_updated_at
  before update on public.seasons
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/010_leagues.sql
-- ============================================================
-- ManagerX
-- Migration: 010
-- Name: leagues
-- Description: Leagues (divisions) belonging to a season.
-- Depends on: 001_profiles (set_updated_at), 009_seasons

create table public.leagues (
  id         uuid primary key default gen_random_uuid(),
  season_id  uuid        not null references public.seasons (id) on delete restrict,
  name       text        not null,
  tier       smallint    not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Target for competitions' composite FK (league must be in the same season).
  constraint leagues_id_season_id_key unique (id, season_id),
  constraint leagues_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 60),
  constraint leagues_tier_chk check (tier >= 1)
);

create unique index leagues_season_name_lower_key
  on public.leagues (season_id, lower(name));

create trigger leagues_set_updated_at
  before update on public.leagues
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/011_competitions.sql
-- ============================================================
-- ManagerX
-- Migration: 011
-- Name: competitions
-- Description: Competitions (league / cup / friendly / tournament) inside a
--              season, plus the registry of participating teams.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 009_seasons, 010_leagues

create table public.competitions (
  id               uuid primary key default gen_random_uuid(),
  season_id        uuid        not null references public.seasons (id) on delete restrict,
  league_id        uuid,
  name             text        not null,
  competition_type text        not null,
  status           text        not null default 'scheduled',
  starts_at        timestamptz,
  ends_at          timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Composite FK: a linked league must belong to the SAME season.
  -- (MATCH SIMPLE: skipped while league_id is NULL, e.g. cups.)
  constraint competitions_league_season_fkey
    foreign key (league_id, season_id)
    references public.leagues (id, season_id),
  constraint competitions_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 80),
  constraint competitions_type_chk
    check (competition_type in ('league', 'cup', 'friendly', 'tournament')),
  constraint competitions_status_chk
    check (status in ('scheduled', 'active', 'completed', 'cancelled')),
  constraint competitions_league_requires_league_id_chk
    check (competition_type <> 'league' or league_id is not null),
  constraint competitions_time_order_chk
    check (starts_at is null or ends_at is null or ends_at > starts_at)
);

create unique index competitions_season_name_lower_key
  on public.competitions (season_id, lower(name));

-- A league has exactly one 'league' competition.
create unique index competitions_one_league_competition_key
  on public.competitions (league_id)
  where competition_type = 'league';

create trigger competitions_set_updated_at
  before update on public.competitions
  for each row execute function public.set_updated_at();

create table public.competition_teams (
  competition_id uuid        not null references public.competitions (id) on delete restrict,
  team_id        uuid        not null references public.teams (id)        on delete restrict,
  joined_at      timestamptz not null default now(),
  constraint competition_teams_pkey primary key (competition_id, team_id)
);

comment on table public.competition_teams is
  'Teams registered in a competition. Fixtures may only use registered teams (trigger in 026).';


-- ============================================================
-- FILE: supabase/migrations/012_fixtures.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/013_matches.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/014_match_events.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/015_transfers.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/016_transfer_listings.sql
-- ============================================================
-- ManagerX
-- Migration: 016
-- Name: transfer_listings
-- Description: Transfer market listings.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 003_players, 015_transfers
--
-- Guarantees at DB level:
--  * at most ONE active listing per player (partial unique index);
--  * a sold listing is linked to exactly one transfer of the SAME player
--    (composite FK) and vice versa (UNIQUE transfer_id);
--  * buyer cannot be the seller.
-- Checked by the buy_player RPC in one transaction (row locks):
--  active? not expired? seller still owns the player? buyer has funds?
--  buyer != seller? price valid?
-- "Seller owns the player" at listing time is enforced by a trigger in 026.

create table public.transfer_listings (
  id             uuid primary key default gen_random_uuid(),
  seller_team_id uuid        not null references public.teams (id)   on delete restrict,
  player_id      uuid        not null references public.players (id) on delete restrict,
  price          bigint      not null,
  status         text        not null default 'active',
  listed_at      timestamptz not null default now(),
  expires_at     timestamptz not null,
  buyer_team_id  uuid        references public.teams (id) on delete restrict,
  transfer_id    uuid,
  sold_at        timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint transfer_listings_transfer_id_key unique (transfer_id),
  constraint transfer_listings_transfer_player_fkey
    foreign key (transfer_id, player_id)
    references public.transfers (id, player_id),
  constraint transfer_listings_price_chk check (price > 0),
  constraint transfer_listings_status_chk
    check (status in ('active', 'sold', 'cancelled', 'expired')),
  constraint transfer_listings_expiry_order_chk check (expires_at > listed_at),
  constraint transfer_listings_buyer_not_seller_chk
    check (buyer_team_id is null or buyer_team_id <> seller_team_id),
  constraint transfer_listings_sold_fields_chk
    check (
      (status = 'sold') = (transfer_id is not null and buyer_team_id is not null and sold_at is not null)
    ),
  constraint transfer_listings_unsold_no_buyer_chk
    check (status = 'sold' or (buyer_team_id is null and transfer_id is null and sold_at is null))
);

-- One active listing per player.
create unique index transfer_listings_one_active_per_player_key
  on public.transfer_listings (player_id)
  where status = 'active';

comment on table public.transfer_listings is
  'Market listings. Created/cancelled/bought only via create_listing / cancel_listing / buy_player RPCs.';

create trigger transfer_listings_set_updated_at
  before update on public.transfer_listings
  for each row execute function public.set_updated_at();

create trigger transfer_listings_freeze_finalized
  before update on public.transfer_listings
  for each row execute function public.prevent_update_when_finalized();


-- ============================================================
-- FILE: supabase/migrations/017_transactions.sql
-- ============================================================
-- ManagerX
-- Migration: 017
-- Name: transactions
-- Description: Immutable economic transaction records (one per money movement
--              of a team). Amount is signed: credit > 0, debit < 0.
-- Depends on: 001_profiles (prevent_row_mutation), 002_teams
--
-- Role split (do not mix):
--   wallets         -> current balance
--   transactions    -> WHAT happened (this table)
--   economy_ledger  -> balance_before / balance_after audit trail (018)
--
-- Replay protection: idempotency_key is UNIQUE, so an RPC/Edge Function retry
-- with the same key cannot create a second transaction.
-- Rollback support: a reversal is a NEW row pointing to the original via
-- reverses_transaction_id (each transaction can be reversed at most once).

create table public.transactions (
  id                     uuid primary key default gen_random_uuid(),
  team_id                uuid        not null references public.teams (id) on delete restrict,
  amount                 bigint      not null,
  transaction_type       text        not null,
  reference_type         text,
  reference_id           uuid,
  description            text,
  idempotency_key        text,
  reverses_transaction_id uuid       references public.transactions (id) on delete restrict,
  created_at             timestamptz not null default now(),
  -- Lets economy_ledger prove (transaction_id, team_id) agree via composite FK.
  constraint transactions_id_team_id_key unique (id, team_id),
  constraint transactions_idempotency_key_key unique (idempotency_key),
  constraint transactions_reverses_key unique (reverses_transaction_id),
  constraint transactions_amount_non_zero_chk check (amount <> 0),
  constraint transactions_type_chk
    check (transaction_type in (
      'transfer', 'salary', 'reward', 'daily_reward', 'match_reward',
      'shop_purchase', 'training', 'admin', 'refund', 'adjustment'
    )),
  constraint transactions_reference_pair_chk
    check ((reference_type is null) = (reference_id is null)),
  constraint transactions_reference_type_chk
    check (reference_type is null or reference_type ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint transactions_description_length_chk
    check (description is null or char_length(description) between 1 and 500),
  constraint transactions_idempotency_key_length_chk
    check (idempotency_key is null or char_length(idempotency_key) between 8 and 200)
);

comment on table public.transactions is
  'Immutable money-movement log. Signed BIGINT amount (credit > 0, debit < 0). Written only by RPCs.';

create trigger transactions_block_update
  before update on public.transactions
  for each row execute function public.prevent_row_mutation();

create trigger transactions_block_delete
  before delete on public.transactions
  for each row execute function public.prevent_row_mutation();


-- ============================================================
-- FILE: supabase/migrations/018_economy_ledger.sql
-- ============================================================
-- ManagerX
-- Migration: 018
-- Name: economy_ledger
-- Description: Immutable wallet ledger with balance_before / balance_after.
-- Depends on: 001_profiles (prevent_row_mutation), 002_teams, 005_wallets,
--             017_transactions
--
-- Integrity provided here:
--  * balance_after = balance_before + amount, never negative;
--  * composite FKs force wallet_id/team_id and transaction_id/team_id to agree;
--  * one entry per (transaction, wallet); the UNIQUE key can be widened later
--    for double-entry (extra counter-party rows use another wallet_id);
--  * seq is a server-generated, gap-tolerant, strictly increasing order key so
--    balance history can be replayed without trusting timestamps.
-- The "wallet balance must equal the latest ledger balance_after" invariant is
-- enforced at COMMIT by deferred constraint triggers in 026.

create table public.economy_ledger (
  id             uuid primary key default gen_random_uuid(),
  seq            bigint generated always as identity,
  team_id        uuid        not null,
  wallet_id      uuid        not null,
  transaction_id uuid        not null,
  amount         bigint      not null,
  balance_before bigint      not null,
  balance_after  bigint      not null,
  entry_type     text        not null,
  reference_type text,
  reference_id   uuid,
  created_at     timestamptz not null default now(),
  constraint economy_ledger_seq_key unique (seq),
  constraint economy_ledger_wallet_team_fkey
    foreign key (wallet_id, team_id)
    references public.wallets (id, team_id) on delete restrict,
  constraint economy_ledger_transaction_team_fkey
    foreign key (transaction_id, team_id)
    references public.transactions (id, team_id) on delete restrict,
  constraint economy_ledger_transaction_wallet_key unique (transaction_id, wallet_id),
  constraint economy_ledger_amount_non_zero_chk check (amount <> 0),
  constraint economy_ledger_balances_non_negative_chk
    check (balance_before >= 0 and balance_after >= 0),
  constraint economy_ledger_balance_math_chk
    check (balance_after = balance_before + amount),
  constraint economy_ledger_entry_type_chk
    check (entry_type in ('credit', 'debit', 'adjustment', 'reversal')),
  constraint economy_ledger_entry_sign_chk
    check (
      (entry_type = 'credit' and amount > 0)
      or (entry_type = 'debit' and amount < 0)
      or entry_type in ('adjustment', 'reversal')
    ),
  constraint economy_ledger_reference_pair_chk
    check ((reference_type is null) = (reference_id is null))
);

comment on table public.economy_ledger is
  'Immutable per-wallet balance history. Written only by RPCs together with the wallet update.';

create trigger economy_ledger_block_update
  before update on public.economy_ledger
  for each row execute function public.prevent_row_mutation();

create trigger economy_ledger_block_delete
  before delete on public.economy_ledger
  for each row execute function public.prevent_row_mutation();


-- ============================================================
-- FILE: supabase/migrations/019_notifications.sql
-- ============================================================
-- ManagerX
-- Migration: 019
-- Name: notifications
-- Description: Per-profile notifications. Owner may only flip is_read.
-- Depends on: 001_profiles

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid        not null references public.profiles (id) on delete cascade,
  type       text        not null,
  title      text        not null,
  message    text        not null,
  data       jsonb       not null default '{}'::jsonb,
  is_read    boolean     not null default false,
  created_at timestamptz not null default now(),
  read_at    timestamptz,
  constraint notifications_type_format_chk check (type ~ '^[a-z][a-z0-9_.]{1,49}$'),
  constraint notifications_title_length_chk check (char_length(title) between 1 and 120),
  constraint notifications_message_length_chk check (char_length(message) between 1 and 1000),
  constraint notifications_data_object_chk check (jsonb_typeof(data) = 'object'),
  constraint notifications_read_state_chk check (is_read = (read_at is not null))
);

comment on table public.notifications is
  'Notifications are created by the server; the owner can only mark them read.';

-- Server decides read_at; a notification can go unread -> read, never back.
create function public.notifications_enforce_read_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.profile_id is distinct from old.profile_id
     or new.type is distinct from old.type
     or new.title is distinct from old.title
     or new.message is distinct from old.message
     or new.data is distinct from old.data
     or new.created_at is distinct from old.created_at then
    raise exception 'only is_read of a notification can be changed'
      using errcode = 'restrict_violation';
  end if;

  if old.is_read and not new.is_read then
    raise exception 'a read notification cannot be marked unread'
      using errcode = 'restrict_violation';
  end if;

  if new.is_read and not old.is_read then
    new.read_at := now();
  else
    new.read_at := old.read_at;
  end if;

  return new;
end;
$$;

revoke all on function public.notifications_enforce_read_state() from public, anon, authenticated;

create trigger notifications_enforce_read_state
  before update on public.notifications
  for each row execute function public.notifications_enforce_read_state();


-- ============================================================
-- FILE: supabase/migrations/020_daily_rewards.sql
-- ============================================================
-- ManagerX
-- Migration: 020
-- Name: daily_rewards
-- Description: Daily reward schedule (global), per-team streak state, and an
--              immutable claim log that makes double-claiming impossible.
-- Depends on: 001_profiles (set_updated_at, prevent_row_mutation),
--             002_teams, 017_transactions
--
-- shop_items does not exist yet (021), so item_id foreign keys are added in 026.
-- The claim_daily_reward RPC must, in one transaction: lock the state row,
-- compute claim_date from server time, insert the claim (the UNIQUE key rejects
-- a second claim for the same day), pay via wallet/ledger, update the state.

create table public.daily_reward_schedule (
  day_number    smallint    primary key,
  reward_type   text        not null,
  reward_amount bigint      not null,
  item_id       uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint daily_reward_schedule_day_chk check (day_number between 1 and 60),
  constraint daily_reward_schedule_type_chk check (reward_type in ('money', 'item')),
  constraint daily_reward_schedule_amount_chk check (reward_amount > 0),
  constraint daily_reward_schedule_item_chk
    check ((reward_type = 'item') = (item_id is not null))
);

create trigger daily_reward_schedule_set_updated_at
  before update on public.daily_reward_schedule
  for each row execute function public.set_updated_at();

create table public.daily_reward_state (
  team_id         uuid        primary key references public.teams (id) on delete restrict,
  current_day     smallint    not null default 1,
  streak          integer     not null default 0,
  last_claim_at   timestamptz,
  last_claim_date date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint daily_reward_state_current_day_chk check (current_day between 1 and 60),
  constraint daily_reward_state_streak_chk check (streak >= 0),
  constraint daily_reward_state_last_claim_pair_chk
    check ((last_claim_at is null) = (last_claim_date is null))
);

create trigger daily_reward_state_set_updated_at
  before update on public.daily_reward_state
  for each row execute function public.set_updated_at();

create table public.daily_reward_claims (
  id             uuid primary key default gen_random_uuid(),
  team_id        uuid        not null references public.teams (id) on delete restrict,
  -- UTC calendar day computed by the SERVER; the client never supplies it.
  claim_date     date        not null default ((now() at time zone 'utc')::date),
  day_number     smallint    not null,
  reward_type    text        not null,
  reward_amount  bigint      not null,
  item_id        uuid,
  transaction_id uuid        references public.transactions (id) on delete restrict,
  created_at     timestamptz not null default now(),
  -- The core anti-abuse rule: one claim per team per day.
  constraint daily_reward_claims_team_date_key unique (team_id, claim_date),
  constraint daily_reward_claims_day_chk check (day_number between 1 and 60),
  constraint daily_reward_claims_type_chk check (reward_type in ('money', 'item')),
  constraint daily_reward_claims_amount_chk check (reward_amount > 0),
  constraint daily_reward_claims_item_chk
    check ((reward_type = 'item') = (item_id is not null)),
  constraint daily_reward_claims_money_tx_chk
    check (reward_type <> 'money' or transaction_id is not null)
);

comment on table public.daily_reward_claims is
  'Immutable claim log; UNIQUE (team_id, claim_date) blocks same-day double claims.';

create trigger daily_reward_claims_block_update
  before update on public.daily_reward_claims
  for each row execute function public.prevent_row_mutation();

create trigger daily_reward_claims_block_delete
  before delete on public.daily_reward_claims
  for each row execute function public.prevent_row_mutation();


-- ============================================================
-- FILE: supabase/migrations/021_shop_items.sql
-- ============================================================
-- ManagerX
-- Migration: 021
-- Name: shop_items
-- Description: Global shop item definitions. Prices are server-owned.
-- Depends on: 001_profiles (set_updated_at)
--
-- Replay protection for purchases is provided by transactions.idempotency_key
-- (017); the purchase itself is a shop_purchase RPC (wallet + ledger + inventory).

create table public.shop_items (
  id          uuid primary key default gen_random_uuid(),
  code        text        not null,
  name        text        not null,
  description text,
  item_type   text        not null,
  price       bigint      not null,
  currency    text        not null default 'coins',
  quantity    integer     not null default 1,
  effect      jsonb       not null default '{}'::jsonb,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint shop_items_code_key unique (code),
  constraint shop_items_code_format_chk check (code ~ '^[a-z][a-z0-9_]{2,63}$'),
  constraint shop_items_name_length_chk check (char_length(name) between 1 and 80),
  constraint shop_items_description_length_chk
    check (description is null or char_length(description) <= 500),
  constraint shop_items_type_chk
    check (item_type in ('training_boost', 'consumable', 'pack', 'currency_pack', 'other')),
  constraint shop_items_price_chk check (price >= 0),
  constraint shop_items_currency_chk check (currency in ('coins')),
  constraint shop_items_quantity_chk check (quantity > 0),
  constraint shop_items_effect_object_chk check (jsonb_typeof(effect) = 'object')
);

comment on table public.shop_items is
  'Item catalogue. Clients can read active items but never change price/effect.';

create trigger shop_items_set_updated_at
  before update on public.shop_items
  for each row execute function public.set_updated_at();


-- ============================================================
-- FILE: supabase/migrations/022_player_market.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/023_anti_cheat_events.sql
-- ============================================================
-- ManagerX
-- Migration: 023
-- Name: anti_cheat_events
-- Description: Game-security events (suspicious behaviour, rate-limit hits,
--              transfer anomalies, reward abuse). NOT the same as audit_log (024).
-- Depends on: 001_profiles, 002_teams
--
-- Rows are never deleted. Only the review workflow columns (status,
-- reviewed_by, reviewed_at) may change, by backend/admin code.

create table public.anti_cheat_events (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid        references public.profiles (id) on delete restrict,
  team_id     uuid        references public.teams (id)    on delete restrict,
  event_type  text        not null,
  severity    text        not null default 'low',
  metadata    jsonb       not null default '{}'::jsonb,
  status      text        not null default 'open',
  reviewed_by uuid        references public.profiles (id) on delete restrict,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint anti_cheat_events_type_format_chk
    check (event_type ~ '^[a-z][a-z0-9_.]{1,59}$'),
  constraint anti_cheat_events_severity_chk
    check (severity in ('info', 'low', 'medium', 'high', 'critical')),
  constraint anti_cheat_events_status_chk
    check (status in ('open', 'reviewed', 'dismissed', 'actioned')),
  constraint anti_cheat_events_metadata_object_chk check (jsonb_typeof(metadata) = 'object'),
  constraint anti_cheat_events_review_fields_chk
    check ((status = 'open') = (reviewed_at is null))
);

comment on table public.anti_cheat_events is
  'Security event log. No client access at all (no policies, no grants).';

create trigger anti_cheat_events_block_delete
  before delete on public.anti_cheat_events
  for each row execute function public.prevent_row_mutation();

-- Only review-workflow columns are updatable.
create function public.anti_cheat_events_protect_evidence()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.profile_id is distinct from old.profile_id
     or new.team_id is distinct from old.team_id
     or new.event_type is distinct from old.event_type
     or new.severity is distinct from old.severity
     or new.metadata is distinct from old.metadata
     or new.created_at is distinct from old.created_at then
    raise exception 'anti_cheat_events evidence columns are immutable'
      using errcode = 'restrict_violation';
  end if;
  return new;
end;
$$;

revoke all on function public.anti_cheat_events_protect_evidence() from public, anon, authenticated;

create trigger anti_cheat_events_protect_evidence
  before update on public.anti_cheat_events
  for each row execute function public.anti_cheat_events_protect_evidence();


-- ============================================================
-- FILE: supabase/migrations/024_audit_log.sql
-- ============================================================
-- ManagerX
-- Migration: 024
-- Name: audit_log
-- Description: Immutable system audit trail (admin actions, bans, rollbacks,
--              critical RPCs). Distinct from anti_cheat_events (023).
-- Depends on: 001_profiles (prevent_row_mutation)

create table public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  -- NULL actor = system / cron / Edge Function acting without a user.
  actor_id    uuid        references public.profiles (id) on delete restrict,
  action      text        not null,
  entity_type text        not null,
  entity_id   uuid,
  metadata    jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint audit_log_action_format_chk check (action ~ '^[a-z][a-z0-9_.:-]{1,79}$'),
  constraint audit_log_entity_type_format_chk check (entity_type ~ '^[a-z][a-z0-9_]{1,39}$'),
  constraint audit_log_metadata_object_chk check (jsonb_typeof(metadata) = 'object')
);

comment on table public.audit_log is
  'Immutable audit trail. No client access (no policies, no grants).';

create trigger audit_log_block_update
  before update on public.audit_log
  for each row execute function public.prevent_row_mutation();

create trigger audit_log_block_delete
  before delete on public.audit_log
  for each row execute function public.prevent_row_mutation();


-- ============================================================
-- FILE: supabase/migrations/025_indexes.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/026_constraints.sql
-- ============================================================
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


-- ============================================================
-- FILE: supabase/migrations/027_rls.sql
-- ============================================================
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


