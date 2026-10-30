create or replace function public.update_profile(
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

  update public.profiles
  set display_name = btrim(p_display_name)
  where id = auth.uid()
  returning id into v_id;

  if v_id is null then
    raise exception 'profile not found';
  end if;

  return v_id;
end;
$$;

revoke all on function public.update_profile(text)
from public, anon, authenticated;
