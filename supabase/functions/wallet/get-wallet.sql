create or replace function public.get_wallet()
returns table (
  wallet_id uuid,
  team_id uuid,
  balance bigint
)
language sql
security definer
set search_path = ''
as $$
  select w.id, w.team_id, w.balance
  from public.wallets w
  join public.teams t on t.id = w.team_id
  where t.profile_id = auth.uid();
$$;

revoke all on function public.get_wallet()
from public, anon, authenticated;
