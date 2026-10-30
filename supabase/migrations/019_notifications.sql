-- ManagerX
-- Migration: 019
-- Name: notifications
-- Description: Per-profile notifications. Owner may only flip is_read.
-- Depends on: 001_profiles

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid        not null references public.profiles (id) on delete cascade,
  type       text        not null,
  title      text        not null,
  message    text        not null,
  data       jsonb       not null default '{}'::jsonb,
  is_read    boolean     not null default false,
  created_at timestamptz not null default now(),
  read_at    timestamptz,
  constraint notifications_type_format_chk check (type ~ '^[a-z][a-z0-9_.]{1,49}$'),
  constraint notifications_title_length_chk check (char_length(title) between 1 and 120),
  constraint notifications_message_length_chk check (char_length(message) between 1 and 1000),
  constraint notifications_data_object_chk check (jsonb_typeof(data) = 'object'),
  constraint notifications_read_state_chk check (is_read = (read_at is not null))
);

comment on table public.notifications is
  'Notifications are created by the server; the owner can only mark them read.';

-- Server decides read_at; a notification can go unread -> read, never back.
create function public.notifications_enforce_read_state()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.profile_id is distinct from old.profile_id
     or new.type is distinct from old.type
     or new.title is distinct from old.title
     or new.message is distinct from old.message
     or new.data is distinct from old.data
     or new.created_at is distinct from old.created_at then
    raise exception 'only is_read of a notification can be changed'
      using errcode = 'restrict_violation';
  end if;

  if old.is_read and not new.is_read then
    raise exception 'a read notification cannot be marked unread'
      using errcode = 'restrict_violation';
  end if;

  if new.is_read and not old.is_read then
    new.read_at := now();
  else
    new.read_at := old.read_at;
  end if;

  return new;
end;
$$;

revoke all on function public.notifications_enforce_read_state() from public, anon, authenticated;

create trigger notifications_enforce_read_state
  before update on public.notifications
  for each row execute function public.notifications_enforce_read_state();
