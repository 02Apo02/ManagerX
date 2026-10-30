-- ManagerX
-- Migration: 021
-- Name: shop_items
-- Description: Global shop item definitions. Prices are server-owned.
-- Depends on: 001_profiles (set_updated_at)
--
-- Replay protection for purchases is provided by transactions.idempotency_key
-- (017); the purchase itself is a shop_purchase RPC (wallet + ledger + inventory).

create table public.shop_items (
  id          uuid primary key default gen_random_uuid(),
  code        text        not null,
  name        text        not null,
  description text,
  item_type   text        not null,
  price       bigint      not null,
  currency    text        not null default 'coins',
  quantity    integer     not null default 1,
  effect      jsonb       not null default '{}'::jsonb,
  active      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint shop_items_code_key unique (code),
  constraint shop_items_code_format_chk check (code ~ '^[a-z][a-z0-9_]{2,63}$'),
  constraint shop_items_name_length_chk check (char_length(name) between 1 and 80),
  constraint shop_items_description_length_chk
    check (description is null or char_length(description) <= 500),
  constraint shop_items_type_chk
    check (item_type in ('training_boost', 'consumable', 'pack', 'currency_pack', 'other')),
  constraint shop_items_price_chk check (price >= 0),
  constraint shop_items_currency_chk check (currency in ('coins')),
  constraint shop_items_quantity_chk check (quantity > 0),
  constraint shop_items_effect_object_chk check (jsonb_typeof(effect) = 'object')
);

comment on table public.shop_items is
  'Item catalogue. Clients can read active items but never change price/effect.';

create trigger shop_items_set_updated_at
  before update on public.shop_items
  for each row execute function public.set_updated_at();
