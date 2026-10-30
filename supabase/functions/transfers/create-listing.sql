create or replace function public.create_listing(
  p_player_id uuid,
  p_price bigint,
  p_expires_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_listing_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_price < 0 then
    raise exception 'price cannot be negative';
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

  if not exists (
    select 1
    from public.team_players
    where team_id = v_team_id
      and player_id = p_player_id
  ) then
    raise exception 'player is not owned by this team';
  end if;

  if exists (
    select 1
    from public.transfer_listings
    where seller_team_id = v_team_id
      and player_id = p_player_id
      and status = 'active'
  ) then
    raise exception 'player already listed';
  end if;

  insert into public.transfer_listings (
    player_id,
    seller_team_id,
    price,
    expires_at,
    status
  )
  values (
    p_player_id,
    v_team_id,
    p_price,
    coalesce(p_expires_at, now() + interval '7 days'),
    'active'
  )
  returning id into v_listing_id;

  return v_listing_id;
end;
$$;

revoke all
on function public.create_listing(uuid,bigint,timestamptz)
from public, anon, authenticated;
