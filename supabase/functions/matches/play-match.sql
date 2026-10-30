create or replace function public.play_match(
  p_match_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_home_team_id uuid;
  v_away_team_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select
    home_team_id,
    away_team_id,
    status
  into
    v_home_team_id,
    v_away_team_id,
    v_status
  from public.matches
  where id = p_match_id
  for update;

  if v_home_team_id is null then
    raise exception 'match not found';
  end if;

  if v_status <> 'scheduled' then
    raise exception 'match is not scheduled';
  end if;

  if not exists (
    select 1
    from public.teams
    where id = v_home_team_id
      and owner_id = auth.uid()
  )
  and not exists (
    select 1
    from public.teams
    where id = v_away_team_id
      and owner_id = auth.uid()
  ) then
    raise exception 'you do not own either team';
  end if;

  update public.matches
  set
    status = 'live',
    started_at = coalesce(started_at, now()),
    updated_at = now()
  where id = p_match_id;

  return true;
end;
$$;

revoke all
on function public.play_match(uuid)
from public, anon, authenticated;
