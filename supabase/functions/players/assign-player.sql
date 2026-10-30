create or replace function public.assign_player(
  p_player_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select id into v_team_id
  from public.teams
  where profile_id = auth.uid()
  limit 1;

  if v_team_id is null then
    raise exception 'team not found';
  end if;

  if not exists (
    select 1 from public.players
    where id = p_player_id
  ) then
    raise exception 'player not found';
  end if;

  if exists (
    select 1
    from public.team_players
    where player_id = p_player_id
  ) then
    raise exception 'player already belongs to a team';
  end if;

  insert into public.team_players (
    team_id,
    player_id
  )
  values (
    v_team_id,
    p_player_id
  );

  return true;
end;
$$;

revoke all on function public.assign_player(uuid)
from public, anon, authenticated;
