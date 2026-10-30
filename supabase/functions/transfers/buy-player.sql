create or replace function public.buy_player(
  p_listing_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_listing record;
  v_buyer_team_id uuid;
  v_buyer_balance bigint;
  v_transfer_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select id
  into v_buyer_team_id
  from public.teams
  where owner_id = auth.uid()
  limit 1
  for update;

  if v_buyer_team_id is null then
    raise exception 'buyer team not found';
  end if;

  select *
  into v_listing
  from public.transfer_listings
  where id = p_listing_id
  for update;

  if v_listing.id is null then
    raise exception 'listing not found';
  end if;

  if v_listing.status <> 'active' then
    raise exception 'listing is not active';
  end if;

  if v_listing.expires_at is not null
     and v_listing.expires_at <= now() then
    update public.transfer_listings
    set status = 'expired',
        updated_at = now()
    where id = p_listing_id;

    raise exception 'listing has expired';
  end if;

  if v_listing.seller_team_id = v_buyer_team_id then
    raise exception 'cannot buy your own player';
  end if;

  select balance
  into v_buyer_balance
  from public.wallets
  where team_id = v_buyer_team_id
  for update;

  if v_buyer_balance is null then
    raise exception 'buyer wallet not found';
  end if;

  if v_buyer_balance < v_listing.price then
    raise exception 'insufficient funds';
  end if;

  if not exists (
    select 1
    from public.team_players
    where team_id = v_listing.seller_team_id
      and player_id = v_listing.player_id
  ) then
    raise exception 'seller no longer owns player';
  end if;

  delete from public.team_players
  where team_id = v_listing.seller_team_id
    and player_id = v_listing.player_id;

  insert into public.team_players (
    team_id,
    player_id,
    acquired_price
  )
  values (
    v_buyer_team_id,
    v_listing.player_id,
    v_listing.price
  );

  insert into public.transfers (
    player_id,
    from_team_id,
    to_team_id,
    price,
    transfer_type
  )
  values (
    v_listing.player_id,
    v_listing.seller_team_id,
    v_buyer_team_id,
    v_listing.price,
    'transfer'
  )
  returning id into v_transfer_id;

  update public.wallets
  set balance = balance - v_listing.price
  where team_id = v_buyer_team_id;

  update public.wallets
  set balance = balance + v_listing.price
  where team_id = v_listing.seller_team_id;

  update public.transfer_listings
  set
    status = 'sold',
    transfer_id = v_transfer_id,
    updated_at = now()
  where id = p_listing_id;

  return v_transfer_id;
end;
$$;

revoke all
on function public.buy_player(uuid)
from public, anon, authenticated;
