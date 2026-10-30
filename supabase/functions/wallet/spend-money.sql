-- ManagerX
-- Wallet: spend_money
-- Server-side wallet debit operation.

create or replace function public.spend_money(
  p_amount bigint,
  p_transaction_type text default 'shop_purchase',
  p_description text default null,
  p_idempotency_key text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_wallet_id uuid;
  v_balance bigint;
  v_new_balance bigint;
  v_tx_id uuid;
begin
  -- Amount must be positive.
  if p_amount <= 0 then
    raise exception 'amount must be positive'
      using errcode = 'check_violation';
  end if;

  -- Allowed debit transaction types.
  if p_transaction_type not in (
    'transfer',
    'shop_purchase',
    'training',
    'admin',
    'adjustment'
  ) then
    raise exception 'invalid debit transaction type: %',
      p_transaction_type
      using errcode = 'check_violation';
  end if;

  -- Idempotency key validation.
  if p_idempotency_key is not null
     and char_length(p_idempotency_key) not between 8 and 200 then
    raise exception 'invalid idempotency key'
      using errcode = 'check_violation';
  end if;

  -- Find authenticated user's team.
  select t.id
    into v_team_id
  from public.teams t
  where t.profile_id = auth.uid()
  limit 1
  for update;

  if v_team_id is null then
    raise exception 'team not found'
      using errcode = 'no_data_found';
  end if;

  -- Lock wallet so concurrent spending cannot race.
  select w.id, w.balance
    into v_wallet_id, v_balance
  from public.wallets w
  where w.team_id = v_team_id
  for update;

  if v_wallet_id is null then
    raise exception 'wallet not found'
      using errcode = 'no_data_found';
  end if;

  -- Replay protection.
  if p_idempotency_key is not null then
    select tx.id
      into v_tx_id
    from public.transactions tx
    where tx.idempotency_key = p_idempotency_key
    limit 1;

    if v_tx_id is not null then
      return v_balance;
    end if;
  end if;

  -- Never allow the wallet to go below zero.
  if v_balance < p_amount then
    raise exception 'insufficient funds'
      using errcode = 'check_violation';
  end if;

  v_new_balance := v_balance - p_amount;

  -- Record the debit.
  insert into public.transactions (
    team_id,
    amount,
    transaction_type,
    description,
    idempotency_key
  )
  values (
    v_team_id,
    -p_amount,
    p_transaction_type,
    p_description,
    p_idempotency_key
  )
  returning id into v_tx_id;

  -- Update current balance.
  update public.wallets
  set
    balance = v_new_balance,
    updated_at = now()
  where id = v_wallet_id;

  -- Write immutable ledger entry.
  insert into public.economy_ledger (
    team_id,
    wallet_id,
    transaction_id,
    amount,
    balance_before,
    balance_after,
    entry_type
  )
  values (
    v_team_id,
    v_wallet_id,
    v_tx_id,
    -p_amount,
    v_balance,
    v_new_balance,
    'debit'
  );

  return v_new_balance;
end;
$$;

-- Trusted server-side execution only.
revoke all
on function public.spend_money(bigint, text, text, text)
from public, anon, authenticated;

