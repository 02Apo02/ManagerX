create or replace function public.admin_give_money(
  p_team_id uuid,
  p_amount bigint,
  p_reason text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_balance bigint;
  v_new_balance bigint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_admin = true
  ) then
    raise exception 'admin access required';
  end if;

  select balance
  into v_balance
  from public.wallets
  where team_id = p_team_id
  for update;

  if v_balance is null then
    raise exception 'wallet not found';
  end if;

  v_new_balance := v_balance + p_amount;

  update public.wallets
  set balance = v_new_balance
  where team_id = p_team_id;

  return v_new_balance;
end;
$$;

revoke all
on function public.admin_give_money(uuid,bigint,text)
from public, anon, authenticated;
