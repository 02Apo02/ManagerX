-- ManagerX
-- Migration: 016
-- Name: transfer_listings
-- Description: Transfer market listings.
-- Depends on: 001_profiles (set_updated_at), 002_teams, 003_players, 015_transfers
--
-- Guarantees at DB level:
--  * at most ONE active listing per player (partial unique index);
--  * a sold listing is linked to exactly one transfer of the SAME player
--    (composite FK) and vice versa (UNIQUE transfer_id);
--  * buyer cannot be the seller.
-- Checked by the buy_player RPC in one transaction (row locks):
--  active? not expired? seller still owns the player? buyer has funds?
--  buyer != seller? price valid?
-- "Seller owns the player" at listing time is enforced by a trigger in 026.

create table public.transfer_listings (
  id             uuid primary key default gen_random_uuid(),
  seller_team_id uuid        not null references public.teams (id)   on delete restrict,
  player_id      uuid        not null references public.players (id) on delete restrict,
  price          bigint      not null,
  status         text        not null default 'active',
  listed_at      timestamptz not null default now(),
  expires_at     timestamptz not null,
  buyer_team_id  uuid        references public.teams (id) on delete restrict,
  transfer_id    uuid,
  sold_at        timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint transfer_listings_transfer_id_key unique (transfer_id),
  constraint transfer_listings_transfer_player_fkey
    foreign key (transfer_id, player_id)
    references public.transfers (id, player_id),
  constraint transfer_listings_price_chk check (price > 0),
  constraint transfer_listings_status_chk
    check (status in ('active', 'sold', 'cancelled', 'expired')),
  constraint transfer_listings_expiry_order_chk check (expires_at > listed_at),
  constraint transfer_listings_buyer_not_seller_chk
    check (buyer_team_id is null or buyer_team_id <> seller_team_id),
  constraint transfer_listings_sold_fields_chk
    check (
      (status = 'sold') = (transfer_id is not null and buyer_team_id is not null and sold_at is not null)
    ),
  constraint transfer_listings_unsold_no_buyer_chk
    check (status = 'sold' or (buyer_team_id is null and transfer_id is null and sold_at is null))
);

-- One active listing per player.
create unique index transfer_listings_one_active_per_player_key
  on public.transfer_listings (player_id)
  where status = 'active';

comment on table public.transfer_listings is
  'Market listings. Created/cancelled/bought only via create_listing / cancel_listing / buy_player RPCs.';

create trigger transfer_listings_set_updated_at
  before update on public.transfer_listings
  for each row execute function public.set_updated_at();

create trigger transfer_listings_freeze_finalized
  before update on public.transfer_listings
  for each row execute function public.prevent_update_when_finalized();
