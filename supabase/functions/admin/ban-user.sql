create or replace function public.admin_ban_user(
  p_user_id uuid,
  p_reason text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and is_admin = true
  ) then
    raise exception 'admin access required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'cannot ban yourself';
  end if;

  update public.profiles
  set
    is_banned = true,
    updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'user not found';
  end if;

  return true;
end;
$$;

revoke all
on function public.admin_ban_user(uuid,text)
from public, anon, authenticated;
