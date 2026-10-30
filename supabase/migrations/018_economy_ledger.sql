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
