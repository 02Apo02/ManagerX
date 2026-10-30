-- ManagerX
-- Migration: 008
-- Name: tactics
-- Description: One tactics row per team (team_id is the primary key).
-- Depends on: 001_profiles (set_updated_at), 002_teams
--
-- Formation is validated by shape only ("4-4-2", "4-2-3-1"); the exact list of
-- allowed formations lives in shared constants and is enforced by save_tactics.

create table public.tactics (
  team_id        uuid primary key references public.teams (id) on delete restrict,
  formation      text        not null default '4-4-2',
  mentality      text        not null default 'balanced',
  style          text        not null default 'balanced',
  passing_style  text        not null default 'mixed',
  pressing       smallint    not null default 50,
  defensive_line smallint    not null default 50,
  tempo          smallint    not null default 50,
  width          smallint    not null default 50,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint tactics_formation_format_chk
    check (formation ~ '^[1-9](-[1-9]){2,4}$'),
  constraint tactics_mentality_chk
    check (mentality in ('ultra_defensive','defensive','balanced','attacking','ultra_attacking')),
  constraint tactics_style_chk
    check (style in ('balanced','possession','counter','direct','wing_play')),
  constraint tactics_passing_style_chk
    check (passing_style in ('short','mixed','long')),
  constraint tactics_pressing_chk check (pressing between 0 and 100),
  constraint tactics_defensive_line_chk check (defensive_line between 0 and 100),
  constraint tactics_tempo_chk check (tempo between 0 and 100),
  constraint tactics_width_chk check (width between 0 and 100)
);

comment on table public.tactics is
  'Per-team tactics. Owner may update own row (RLS); rows are created by trigger.';

create trigger tactics_set_updated_at
  before update on public.tactics
  for each row execute function public.set_updated_at();

create function public.create_tactics_for_new_team()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.tactics (team_id) values (new.id);
  return new;
end;
$$;

revoke all on function public.create_tactics_for_new_team() from public, anon, authenticated;

create trigger teams_create_tactics
  after insert on public.teams
  for each row execute function public.create_tactics_for_new_team();
