create or replace function public.cancel_listing(
  p_listing_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select seller_team_id, status
  into v_team_id, v_status
  from public.transfer_listings
  where id = p_listing_id
  for update;

  if v_team_id is null then
    raise exception 'listing not found';
  end if;

  if not exists (
    select 1
    from public.teams
    where id = v_team_id
      and owner_id = auth.uid()
  ) then
    raise exception 'not listing owner';
  end if;

  if v_status <> 'active' then
    raise exception 'listing is not active';
  end if;

  update public.transfer_listings
  set
    status = 'cancelled',
    updated_at = now()
  where id = p_listing_id;

  return true;
end;
$$;

revoke all
on function public.cancel_listing(uuid)
from public, anon, authenticated;
