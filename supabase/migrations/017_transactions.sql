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
