create or replace function public.update_team(
  p_team_id uuid,
  p_name text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  p_name := btrim(p_name);

  if char_length(p_name) < 3 or char_length(p_name) > 40 then
    raise exception 'team name must be between 3 and 40 characters';
  end if;

  select owner_id
  into v_owner_id
  from public.teams
  where id = p_team_id
  for update;

  if v_owner_id is null then
    raise exception 'team not found';
  end if;

  if v_owner_id <> auth.uid() then
    raise exception 'not team owner';
  end if;

  update public.teams
  set
    name = p_name,
    updated_at = now()
  where id = p_team_id;

  return true;

exception
  when unique_violation then
    raise exception 'team name already exists';
end;
$$;

revoke all
on function public.update_team(uuid,text)
from public, anon, authenticated;
