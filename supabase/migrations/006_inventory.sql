-- ManagerX
-- Migration: 006
-- Name: inventory
-- Description: Items owned by a team (one row per team + item).
-- Depends on: 001_profiles (set_updated_at), 002_teams
--
-- Circular/forward dependency: item_id references shop_items, which is only
-- created in 021. The foreign key is therefore added in 026_constraints.

create table public.inventory (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid        not null references public.teams (id) on delete restrict,
  item_id    uuid        not null,
  quantity   integer     not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint inventory_team_item_key unique (team_id, item_id),
  constraint inventory_quantity_chk check (quantity >= 0)
);

comment on table public.inventory is
  'Team item stock. Mutated only by server-side RPCs (shop purchase, item use, rewards).';

create trigger inventory_set_updated_at
  before update on public.inventory
  for each row execute function public.set_updated_at();
