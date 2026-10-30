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
