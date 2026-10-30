create or replace function public.create_match(
  p_fixture_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match_id uuid;
  v_home_team_id uuid;
  v_away_team_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select
    f.home_team_id,
    f.away_team_id,
    f.status
  into
    v_home_team_id,
    v_away_team_id,
    v_status
  from public.fixtures f
  where f.id = p_fixture_id
  for update;

  if v_home_team_id is null then
    raise exception 'fixture not found';
  end if;

  if v_status <> 'scheduled' then
    raise exception 'fixture is not scheduled';
  end if;

  if not exists (
    select 1
    from public.teams t
    where t.id = v_home_team_id
      and t.owner_id = auth.uid()
  )
  and not exists (
    select 1
    from public.teams t
    where t.id = v_away_team_id
      and t.owner_id = auth.uid()
  ) then
    raise exception 'you do not own either team';
  end if;

  if exists (
    select 1
    from public.matches
    where fixture_id = p_fixture_id
  ) then
    raise exception 'match already exists';
  end if;

  insert into public.matches (
    fixture_id,
    home_team_id,
    away_team_id,
    status
  )
  values (
    p_fixture_id,
    v_home_team_id,
    v_away_team_id,
    'scheduled'
  )
  returning id into v_match_id;

  return v_match_id;
end;
$$;

revoke all
on function public.create_match(uuid)
from public, anon, authenticated;
