create or replace function public.change_lineup(
  p_player_id uuid,
  p_lineup_slot smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_current_status text;
  v_current_slot smallint;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_lineup_slot < 1 or p_lineup_slot > 11 then
    raise exception 'lineup slot must be between 1 and 11';
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

  select squad_status, lineup_slot
  into v_current_status, v_current_slot
  from public.team_players
  where team_id = v_team_id
    and player_id = p_player_id
  for update;

  if v_current_status is null then
    raise exception 'player is not owned by this team';
  end if;

  /*
   * If another player already occupies the requested slot,
   * move that player to the bench first.
   */
  update public.team_players
  set
    squad_status = 'bench',
    lineup_slot = null,
    updated_at = now()
  where team_id = v_team_id
    and lineup_slot = p_lineup_slot
    and player_id <> p_player_id;

  update public.team_players
  set
    squad_status = 'starter',
    lineup_slot = p_lineup_slot,
    updated_at = now()
  where team_id = v_team_id
    and player_id = p_player_id;

  return true;
end;
$$;

revoke all
on function public.change_lineup(uuid,smallint)
from public, anon, authenticated;
