create or replace function public.create_profile(
  p_display_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if p_display_name is null
     or char_length(btrim(p_display_name)) not between 2 and 30 then
    raise exception 'invalid display name';
  end if;

  insert into public.profiles (
    id,
    display_name
  )
  values (
    auth.uid(),
    btrim(p_display_name)
  )
  on conflict (id) do update
    set display_name = excluded.display_name
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_profile(text)
from public, anon, authenticated;
