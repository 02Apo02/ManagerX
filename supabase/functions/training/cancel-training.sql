create or replace function public.cancel_training(
  p_training_id uuid
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

  update public.training
  set
    status = 'cancelled',
    cancelled_at = now(),
    updated_at = now()
  where id = p_training_id
    and team_id = v_team_id
    and status in ('queued','active');

  if not found then
    raise exception 'training not found or already finished';
  end if;

  return true;
end;
$$;

revoke all on function public.cancel_training(uuid)
from public, anon, authenticated;
