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
