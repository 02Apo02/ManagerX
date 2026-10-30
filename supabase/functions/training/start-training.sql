create or replace function public.start_training(
  p_player_id uuid,
  p_training_type text,
  p_duration_minutes integer
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_training_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_duration_minutes <= 0 or p_duration_minutes > 1440 then
    raise exception 'invalid training duration';
  end if;

  if p_training_type not in (
    'general','fitness','recovery','pace',
    'shooting','passing','dribbling','defending','physical'
  ) then
    raise exception 'invalid training type';
  end if;

  select id into v_team_id
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

  if exists (
    select 1
    from public.training
    where player_id = p_player_id
      and status in ('queued','active')
  ) then
    raise exception 'player already has active training';
  end if;

  insert into public.training (
    team_id,
    player_id,
    training_type,
    status,
    started_at,
    finishes_at
  )
  values (
    v_team_id,
    p_player_id,
    p_training_type,
    'active',
    now(),
    now() + make_interval(mins => p_duration_minutes)
  )
  returning id into v_training_id;

  return v_training_id;
end;
$$;

revoke all on function public.start_training(uuid,text,integer)
from public, anon, authenticated;
