create or replace function public.finish_match(
  p_match_id uuid,
  p_home_score smallint,
  p_away_score smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fixture_id uuid;
  v_home_team_id uuid;
  v_away_team_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_home_score < 0 or p_away_score < 0 then
    raise exception 'scores cannot be negative';
  end if;

  select
    fixture_id,
    home_team_id,
    away_team_id,
    status
  into
    v_fixture_id,
    v_home_team_id,
    v_away_team_id,
    v_status
  from public.matches
  where id = p_match_id
  for update;

  if v_fixture_id is null then
    raise exception 'match not found';
  end if;

  if v_status <> 'live' then
    raise exception 'match is not live';
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
    status = 'completed',
    home_score = p_home_score,
    away_score = p_away_score,
    finished_at = now(),
    updated_at = now()
  where id = p_match_id;

  update public.fixtures
  set
    status = 'completed',
    home_score = p_home_score,
    away_score = p_away_score,
    updated_at = now()
  where id = v_fixture_id;

  return true;
end;
$$;

revoke all
on function public.finish_match(uuid,smallint,smallint)
from public, anon, authenticated;
