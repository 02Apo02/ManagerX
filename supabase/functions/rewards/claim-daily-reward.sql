create or replace function public.claim_daily_reward()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_reward bigint;
  v_claimed_at timestamptz;
  v_new_balance bigint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select id
  into v_team_id
  from public.teams
  where owner_id = auth.uid()
  limit 1
  for update;

  if v_team_id is null then
    raise exception 'team not found';
  end if;

  select reward_amount, claimed_at
  into v_reward, v_claimed_at
  from public.daily_reward_claims
  where team_id = v_team_id
    and reward_date = current_date
  for update;

  if v_claimed_at is not null then
    raise exception 'daily reward already claimed';
  end if;

  v_reward := coalesce(v_reward, 10000);

  insert into public.daily_reward_claims (
    team_id,
    reward_date,
    reward_amount,
    claimed_at
  )
  values (
    v_team_id,
    current_date,
    v_reward,
    now()
  )
  on conflict (team_id, reward_date)
  do update set
    claimed_at = now(),
    reward_amount = excluded.reward_amount;

  update public.wallets
  set balance = balance + v_reward
  where team_id = v_team_id
  returning balance into v_new_balance;

  if v_new_balance is null then
    raise exception 'wallet not found';
  end if;

  return v_new_balance;
end;
$$;

revoke all
on function public.claim_daily_reward()
from public, anon, authenticated;
