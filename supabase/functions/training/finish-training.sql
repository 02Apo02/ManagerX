create or replace function public.finish_training(
  p_training_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_team_id uuid;
  v_status text;
  v_finishes_at timestamptz;
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

  select status, finishes_at
    into v_status, v_finishes_at
  from public.training
  where id = p_training_id
    and team_id = v_team_id
  for update;

  if v_status is null then
    raise exception 'training not found';
  end if;

  if v_status <> 'active' then
    raise exception 'training is not active';
  end if;

  if now() < v_finishes_at then
    raise exception 'training is not finished yet';
  end if;

  update public.training
  set
    status = 'completed',
    completed_at = now(),
    updated_at = now()
  where id = p_training_id;

  return true;
end;
$$;

revoke all on function public.finish_training(uuid)
from public, anon, authenticated;
