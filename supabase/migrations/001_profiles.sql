-- ManagerX
-- Migration: 001
-- Name: profiles
-- Description: Shared helper functions (set_updated_at, prevent_row_mutation),
--              profiles table, auth.users -> profiles provisioning trigger,
--              admin role helper.
-- Depends on: auth.users (Supabase system table)
--
-- UUID note: gen_random_uuid() is part of PostgreSQL core since v13, so no
-- extension (pgcrypto / uuid-ossp) is required on Supabase.

-- ---------------------------------------------------------------------------
-- Shared helper functions (defined ONCE here, reused by later migrations)
-- ---------------------------------------------------------------------------

-- Server-side updated_at. Client-supplied values are always overwritten.
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Used by append-only / history tables to block UPDATE and DELETE.
create function public.prevent_row_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% on %.% is not allowed: rows are immutable',
    tg_op, tg_table_schema, tg_table_name
    using errcode = 'restrict_violation';
  return null;
end;
$$;

revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.prevent_row_mutation() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  telegram_id  bigint      not null,
  username     text,
  display_name text        not null,
  -- Authorization role. NEVER writable by clients (column privileges in 027).
  role         text        not null default 'player',
  -- Soft account state (ban / suspend) instead of deleting rows.
  status       text        not null default 'active',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint profiles_telegram_id_key unique (telegram_id),
  constraint profiles_telegram_id_positive_chk check (telegram_id > 0),
  constraint profiles_username_format_chk
    check (username is null or username ~ '^[A-Za-z0-9_]{3,32}$'),
  constraint profiles_display_name_length_chk
    check (char_length(display_name) between 2 and 32 and display_name = btrim(display_name)),
  constraint profiles_role_chk check (role in ('player', 'moderator', 'admin')),
  constraint profiles_status_chk check (status in ('active', 'suspended', 'banned'))
);

comment on table public.profiles is
  'Game profile per auth user. telegram_id/role/status are server-managed and hidden from clients via column privileges.';

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- telegram_id and id are permanent identity: never changeable, not even by RPCs.
create function public.profiles_protect_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'profiles.id is immutable' using errcode = 'restrict_violation';
  end if;
  if new.telegram_id is distinct from old.telegram_id then
    raise exception 'profiles.telegram_id is immutable' using errcode = 'restrict_violation';
  end if;
  new.created_at := old.created_at;
  return new;
end;
$$;

revoke all on function public.profiles_protect_identity() from public, anon, authenticated;

create trigger profiles_protect_identity
  before update on public.profiles
  for each row execute function public.profiles_protect_identity();

-- ---------------------------------------------------------------------------
-- auth.users -> profiles provisioning
-- ---------------------------------------------------------------------------
-- SECURITY: telegram_id is read ONLY from raw_app_meta_data, which can be set
-- solely by the service role / admin API (the verified-initData Edge Function).
-- raw_user_meta_data is client-writable on self sign-up and is deliberately
-- NOT trusted. Users created without a valid telegram_id get no profile.
-- If the telegram_id already has a profile, the unique violation aborts the
-- auth user creation on purpose (fail closed, never silently link accounts).
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tg_text  text := new.raw_app_meta_data ->> 'telegram_id';
  v_username text := nullif(btrim(new.raw_app_meta_data ->> 'username'), '');
  v_display  text := btrim(coalesce(new.raw_app_meta_data ->> 'display_name', ''));
begin
  if v_tg_text is null or v_tg_text !~ '^[1-9][0-9]{0,14}$' then
    return new;
  end if;

  if v_username is not null and v_username !~ '^[A-Za-z0-9_]{3,32}$' then
    v_username := null;
  end if;

  v_display := btrim(left(v_display, 32));
  if char_length(v_display) < 2 then
    v_display := 'Manager' || right(v_tg_text, 6);
  end if;

  insert into public.profiles (id, telegram_id, username, display_name)
  values (new.id, v_tg_text::bigint, v_username, v_display);

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger managerx_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Admin helper (role lives in profiles.role, not client-editable)
-- ---------------------------------------------------------------------------
create function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = (select auth.uid())
      and p.role = 'admin'
      and p.status = 'active'
  );
$$;

revoke all on function public.is_admin() from public, anon, authenticated;
grant execute on function public.is_admin() to authenticated;
