create or replace function public.rollback_transaction(
  p_transaction_id uuid,
  p_idempotency_key text default null,
  p_description text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_original public.transactions%rowtype;
  v_team_id uuid;
  v_new_balance bigint;
  v_reversal_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not public.is_admin() then
    raise exception 'admin access required';
  end if;

  if p_idempotency_key is not null then
    select t.team_id
      into v_team_id
    from public.transactions t
    where t.idempotency_key = p_idempotency_key
    limit 1;

    if v_team_id is not null then
      select w.balance
        into v_new_balance
      from public.wallets w
      where w.team_id = v_team_id;

      return v_new_balance;
    end if;
  end if;

  select *
    into v_original
  from public.transactions
  where id = p_transaction_id
  for update;

  if v_original.id is null then
    raise exception 'transaction not found';
  end if;

  if v_original.reverses_transaction_id is not null then
    raise exception 'cannot reverse a reversal transaction';
  end if;

  if exists (
    select 1
    from public.transactions
    where reverses_transaction_id = v_original.id
  ) then
    raise exception 'transaction already reversed';
  end if;

  select w.balance
    into v_new_balance
  from public.wallets w
  where w.team_id = v_original.team_id
  for update;

  if v_new_balance is null then
    raise exception 'wallet not found';
  end if;

  v_new_balance := v_new_balance - v_original.amount;

  if v_new_balance < 0 then
    raise exception 'rollback would make wallet balance negative';
  end if;

  insert into public.transactions (
    team_id,
    amount,
    transaction_type,
    reference_type,
    reference_id,
    description,
    idempotency_key,
    reverses_transaction_id
  )
  values (
    v_original.team_id,
    -v_original.amount,
    'refund',
    'transaction',
    v_original.id,
    coalesce(p_description, 'Transaction rollback'),
    p_idempotency_key,
    v_original.id
  )
  returning id into v_reversal_id;

  update public.wallets
  set balance = v_new_balance
  where team_id = v_original.team_id;

  insert into public.economy_ledger (
    team_id,
    wallet_id,
    transaction_id,
    amount,
    balance_before,
    balance_after,
    entry_type
  )
  select
    v_original.team_id,
    w.id,
    v_reversal_id,
    -v_original.amount,
    v_new_balance + v_original.amount,
    v_new_balance,
    case
      when v_original.amount > 0 then 'debit'
      else 'credit'
    end
  from public.wallets w
  where w.team_id = v_original.team_id;

  return v_new_balance;
end;
$$;

revoke all
on function public.rollback_transaction(uuid,text,text)
from public, anon, authenticated;

grant execute
on function public.rollback_transaction(uuid,text,text)
to authenticated;
