create or replace function public.create_team(
  p_name text
)
returns uuid
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

  if p_name is null
     or char_length(btrim(p_name)) not between 2 and 40 then
    raise exception 'invalid team name';
  end if;

  if exists (
    select 1
    from public.teams
    where profile_id = auth.uid()
  ) then
    raise exception 'team already exists';
  end if;

  insert into public.teams (
    profile_id,
    name
  )
  values (
    auth.uid(),
    btrim(p_name)
  )
  returning id into v_team_id;

  return v_team_id;
end;
$$;

revoke all on function public.create_team(text)
from public, anon, authenticated;
