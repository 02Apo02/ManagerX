-- ManagerX
-- Migration: 009
-- Name: seasons
-- Description: Seasons with a database-level guarantee of a single active season.
-- Depends on: 001_profiles (set_updated_at)

create table public.seasons (
  id            uuid primary key default gen_random_uuid(),
  name          text        not null,
  season_number integer     not null,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  status        text        not null default 'scheduled',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint seasons_season_number_key unique (season_number),
  constraint seasons_season_number_chk check (season_number > 0),
  constraint seasons_name_length_chk
    check (name = btrim(name) and char_length(name) between 1 and 60),
  constraint seasons_time_order_chk check (ends_at > starts_at),
  constraint seasons_status_chk check (status in ('scheduled', 'active', 'completed'))
);

create unique index seasons_name_lower_key on public.seasons (lower(name));

-- Constant-expression partial unique index: at most ONE row may be 'active'.
create unique index seasons_single_active_key
  on public.seasons ((true))
  where status = 'active';

create trigger seasons_set_updated_at
  before update on public.seasons
  for each row execute function public.set_updated_at();
