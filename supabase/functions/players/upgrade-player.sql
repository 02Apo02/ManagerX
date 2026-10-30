create or replace function public.upgrade_player(
  p_player_id uuid,
  p_attribute text
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_current_value integer;
  v_new_value integer;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select id
    into v_team_id
  from public.teams
  where profile_id = auth.uid()
  limit 1;

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

  if p_attribute not in (
    'pace',
    'shooting',
    'passing',
    'dribbling',
    'defending',
    'physical'
  ) then
    raise exception 'invalid player attribute';
  end if;

  execute format(
    'select %I from public.players where id = $1',
    p_attribute
  )
  into v_current_value
  using p_player_id;

  if v_current_value is null then
    raise exception 'player not found';
  end if;

  if v_current_value >= 100 then
    raise exception 'attribute is already at maximum';
  end if;

  v_new_value := v_current_value + 1;

  execute format(
    'update public.players set %I = $1 where id = $2',
    p_attribute
  )
  using v_new_value, p_player_id;

  return v_new_value;
end;
$$;

revoke all
on function public.upgrade_player(uuid,text)
from public, anon, authenticated;
