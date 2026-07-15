-- =============================================================================
-- SupplyOS — reference database schema (PostgreSQL / Supabase)
-- =============================================================================
-- This file is RECONSTRUCTED from the application's queries and RPC calls to
-- document the backend and to make the published anon key safe (via RLS).
-- Reconcile it with your ACTUAL Supabase project before running — column names,
-- types, and function bodies may differ from your live database.
--
-- Notable assumption: the app computes live stock as Supplied - Sold - Returned.
-- "Supplied" comes from supplier_dispatches and "Returned" from vendor_returns,
-- but the client has no table for units SOLD to end customers. A `vendor_sales`
-- table is included below so get_live_inventory() has a source for "sold";
-- adjust or drop it to match your real design.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- Tables
-- ----------------------------------------------------------------------------

create table if not exists profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  role          text not null check (role in ('supplier','vendor')),
  name          text,
  business_name text,
  location      text,
  supplier_id   text unique,   -- set for suppliers, e.g. 'SUP-101'
  vendor_id     text unique,   -- set for vendors,   e.g. 'VND-101'
  created_at    timestamptz not null default now()
);

create table if not exists product_master (
  supplier_id                 text not null,
  product_code                text not null,
  product_name                text not null,
  category                    text,
  standard_discount_percentage numeric default 0,
  image_url                   text,
  available_qty               integer default 0,
  bulk_price                  numeric,
  available_from              date,
  delivery_days               integer,
  updated_at                  timestamptz not null default now(),
  primary key (supplier_id, product_code)
);

create table if not exists order_requests (
  id                      uuid primary key default gen_random_uuid(),
  vendor_id               text not null,
  product_description     text not null,
  quantity                integer not null,
  target_price            numeric,
  status                  text not null default 'open'
                            check (status in ('open','accepted','cancelled')),
  accepted_supplier_id    text,
  accepted_product_code   text,
  accepted_price          numeric,
  accepted_lead_time_days integer,
  accepted_at             timestamptz,
  created_at              timestamptz not null default now()
);

create table if not exists supplier_dispatches (
  id             uuid primary key default gen_random_uuid(),
  supplier_id    text not null,
  vendor_id      text not null,
  product_code   text not null,
  quantity       integer not null,
  lead_time_days integer,
  dispatched_at  timestamptz not null default now()
);

create table if not exists vendor_returns (
  id                uuid primary key default gen_random_uuid(),
  vendor_id         text not null,
  supplier_id       text not null,
  product_code      text not null,
  quantity_returned integer not null,
  reason_for_return text,
  created_at        timestamptz not null default now()
);

-- Optional: units sold by a vendor to end customers (source for "Sold").
create table if not exists vendor_sales (
  id            uuid primary key default gen_random_uuid(),
  vendor_id     text not null,
  supplier_id   text not null,
  product_code  text not null,
  quantity_sold integer not null,
  sold_at       timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- Helper functions: map the current auth user to their tenant IDs
-- ----------------------------------------------------------------------------

create or replace function current_supplier_id() returns text
  language sql stable security definer set search_path = public as $$
  select supplier_id from profiles where id = auth.uid();
$$;

create or replace function current_vendor_id() returns text
  language sql stable security definer set search_path = public as $$
  select vendor_id from profiles where id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- ID generation
-- ----------------------------------------------------------------------------

create sequence if not exists supplier_id_seq start 101;
create sequence if not exists vendor_id_seq   start 101;

create or replace function generate_supplier_id() returns text
  language sql security definer set search_path = public as $$
  select 'SUP-' || lpad(nextval('supplier_id_seq')::text, 3, '0');
$$;

create or replace function generate_vendor_id() returns text
  language sql security definer set search_path = public as $$
  select 'VND-' || lpad(nextval('vendor_id_seq')::text, 3, '0');
$$;

-- ----------------------------------------------------------------------------
-- Create a profile automatically on sign-up (from auth metadata)
-- ----------------------------------------------------------------------------

create or replace function handle_new_user() returns trigger
  language plpgsql security definer set search_path = public as $$
declare
  r text := coalesce(new.raw_user_meta_data->>'role', 'supplier');
  sid text; vid text;
begin
  if r = 'vendor' then vid := generate_vendor_id();
  else                 sid := generate_supplier_id();
  end if;

  insert into profiles (id, role, name, business_name, location, supplier_id, vendor_id)
  values (
    new.id, r,
    new.raw_user_meta_data->>'name',
    new.raw_user_meta_data->>'business_name',
    new.raw_user_meta_data->>'location',
    sid, vid
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ----------------------------------------------------------------------------
-- Business logic (RPC)
-- ----------------------------------------------------------------------------

-- Log a dispatch and decrement the supplier's catalog stock.
create or replace function log_dispatch(
  p_vendor_id text, p_product_code text, p_qty integer, p_lead_time integer
) returns void
  language plpgsql security definer set search_path = public as $$
declare s_id text := current_supplier_id();
begin
  insert into supplier_dispatches (supplier_id, vendor_id, product_code, quantity, lead_time_days)
  values (s_id, p_vendor_id, p_product_code, p_qty, p_lead_time);

  update product_master
     set available_qty = greatest(0, coalesce(available_qty, 0) - p_qty)
   where supplier_id = s_id and product_code = p_product_code;
end;
$$;

-- Atomic "first to accept wins". Returns TRUE if this caller claimed the order,
-- FALSE if it was already taken. The conditional UPDATE is the race guard.
create or replace function accept_order_request(
  p_order_id uuid, p_fulfilling_product_code text,
  p_final_price numeric, p_lead_time_days integer
) returns boolean
  language plpgsql security definer set search_path = public as $$
declare
  s_id text := current_supplier_id();
  v_id text;
  claimed integer;
  order_qty integer;
begin
  update order_requests
     set status = 'accepted',
         accepted_supplier_id    = s_id,
         accepted_product_code   = p_fulfilling_product_code,
         accepted_price          = p_final_price,
         accepted_lead_time_days = p_lead_time_days,
         accepted_at             = now()
   where id = p_order_id and status = 'open'
   returning vendor_id, quantity into v_id, order_qty;

  get diagnostics claimed = row_count;
  if claimed = 0 then
    return false;   -- someone else got here first
  end if;

  insert into supplier_dispatches (supplier_id, vendor_id, product_code, quantity, lead_time_days)
  values (s_id, v_id, p_fulfilling_product_code, order_qty, p_lead_time_days);

  update product_master
     set available_qty = greatest(0, coalesce(available_qty, 0) - order_qty)
   where supplier_id = s_id and product_code = p_fulfilling_product_code;

  return true;
end;
$$;

-- Live inventory ledger for one vendor/supplier pair: Supplied - Sold - Returned.
create or replace function get_live_inventory(
  p_vendor_id text, p_supplier_id text
) returns table (
  product_name text, product_code text, category text,
  total_supplied bigint, total_sold bigint, total_returned bigint,
  current_stock_on_hand bigint
) language sql stable security definer set search_path = public as $$
  with sup as (
    select product_code, sum(quantity)::bigint qty
    from supplier_dispatches
    where vendor_id = p_vendor_id and supplier_id = p_supplier_id
    group by product_code
  ),
  sold as (
    select product_code, sum(quantity_sold)::bigint qty
    from vendor_sales
    where vendor_id = p_vendor_id and supplier_id = p_supplier_id
    group by product_code
  ),
  ret as (
    select product_code, sum(quantity_returned)::bigint qty
    from vendor_returns
    where vendor_id = p_vendor_id and supplier_id = p_supplier_id
    group by product_code
  )
  select
    pm.product_name, pm.product_code, pm.category,
    coalesce(sup.qty, 0),
    coalesce(sold.qty, 0),
    coalesce(ret.qty, 0),
    coalesce(sup.qty, 0) - coalesce(sold.qty, 0) - coalesce(ret.qty, 0)
  from product_master pm
  join sup       on sup.product_code  = pm.product_code
  left join sold on sold.product_code = pm.product_code
  left join ret  on ret.product_code  = pm.product_code
  where pm.supplier_id = p_supplier_id;
$$;

grant execute on function
  generate_supplier_id(), generate_vendor_id(),
  log_dispatch(text, text, integer, integer),
  accept_order_request(uuid, text, numeric, integer),
  get_live_inventory(text, text)
to authenticated;

-- ----------------------------------------------------------------------------
-- Row Level Security
-- ----------------------------------------------------------------------------
-- This is what makes the publishable (anon) key safe to expose. Without these
-- policies, the anon key allows unrestricted access.

alter table profiles            enable row level security;
alter table product_master      enable row level security;
alter table order_requests      enable row level security;
alter table supplier_dispatches enable row level security;
alter table vendor_returns      enable row level security;
alter table vendor_sales        enable row level security;

-- profiles: any signed-in user can read the directory (needed to show business
-- names next to products/orders); users may only create/edit their own row.
create policy "profiles readable by authenticated"
  on profiles for select to authenticated using (true);
create policy "insert own profile"
  on profiles for insert to authenticated with check (id = auth.uid());
create policy "update own profile"
  on profiles for update to authenticated using (id = auth.uid());

-- product_master: everyone signed in can browse; only the owning supplier writes.
create policy "catalog readable by authenticated"
  on product_master for select to authenticated using (true);
create policy "supplier manages own catalog"
  on product_master for all to authenticated
  using (supplier_id = current_supplier_id())
  with check (supplier_id = current_supplier_id());

-- order_requests: readable by all signed-in users (suppliers browse the board);
-- a vendor may post and cancel their own. Accepting is done via the RPC above.
create policy "requests readable by authenticated"
  on order_requests for select to authenticated using (true);
create policy "vendor posts own request"
  on order_requests for insert to authenticated
  with check (vendor_id = current_vendor_id());
create policy "vendor updates own request"
  on order_requests for update to authenticated
  using (vendor_id = current_vendor_id());

-- supplier_dispatches: readable by the supplier or the vendor involved.
-- Inserts happen through SECURITY DEFINER functions, not direct client writes.
create policy "dispatches readable by involved parties"
  on supplier_dispatches for select to authenticated
  using (supplier_id = current_supplier_id() or vendor_id = current_vendor_id());

-- vendor_returns: a vendor logs and reads their own returns; the supplier can read.
create policy "returns readable by involved parties"
  on vendor_returns for select to authenticated
  using (vendor_id = current_vendor_id() or supplier_id = current_supplier_id());
create policy "vendor logs own return"
  on vendor_returns for insert to authenticated
  with check (vendor_id = current_vendor_id());

-- vendor_sales: a vendor reads/writes their own.
create policy "sales readable by vendor"
  on vendor_sales for select to authenticated
  using (vendor_id = current_vendor_id() or supplier_id = current_supplier_id());
create policy "vendor logs own sale"
  on vendor_sales for insert to authenticated
  with check (vendor_id = current_vendor_id());

-- =============================================================================
-- End of reference schema.
-- =============================================================================
