create or replace function public.save_tactics(
  p_formation text,
  p_mentality text,
  p_style text,
  p_passing_style text,
  p_pressing smallint,
  p_defensive_line smallint,
  p_tempo smallint,
  p_width smallint
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

  if p_formation !~ '^[1-9](-[1-9]){2,4}$' then
    raise exception 'invalid formation';
  end if;

  if p_mentality not in (
    'ultra_defensive','defensive','balanced',
    'attacking','ultra_attacking'
  ) then
    raise exception 'invalid mentality';
  end if;

  if p_style not in (
    'balanced','possession','counter','direct','wing_play'
  ) then
    raise exception 'invalid style';
  end if;

  if p_passing_style not in ('short','mixed','long') then
    raise exception 'invalid passing style';
  end if;

  if p_pressing not between 0 and 100
     or p_defensive_line not between 0 and 100
     or p_tempo not between 0 and 100
     or p_width not between 0 and 100 then
    raise exception 'tactical values must be between 0 and 100';
  end if;

  update public.tactics
  set
    formation = p_formation,
    mentality = p_mentality,
    style = p_style,
    passing_style = p_passing_style,
    pressing = p_pressing,
    defensive_line = p_defensive_line,
    tempo = p_tempo,
    width = p_width,
    updated_at = now()
  where team_id = v_team_id;

  if not found then
    raise exception 'tactics not found';
  end if;

  return true;
end;
$$;

revoke all on function public.save_tactics(
  text,text,text,text,smallint,smallint,smallint,smallint
)
from public, anon, authenticated;
