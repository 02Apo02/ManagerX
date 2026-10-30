create or replace function public.release_player(
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

  select id
    into v_team_id
  from public.teams
  where profile_id = auth.uid()
  limit 1;

  if v_team_id is null then
    raise exception 'team not found';
  end if;

  -- Açık antrenmanı önce iptal et.
  update public.training
  set
    status = 'cancelled',
    cancelled_at = now(),
    updated_at = now()
  where team_id = v_team_id
    and player_id = p_player_id
    and status in ('queued', 'active');

  -- Oyuncunun gerçekten bu takımda olduğunu kontrol ederek çıkar.
  delete from public.team_players
  where team_id = v_team_id
    and player_id = p_player_id;

  if not found then
    raise exception 'player is not owned by this team';
  end if;

  return true;
end;
$$;

revoke all
on function public.release_player(uuid)
from public, anon, authenticated;
