-- =============================================================================
-- Electronics Inventory Management — Schema
-- Migration 0001: extensions, enums, tables, indexes, triggers
--
-- Run this in the Supabase SQL Editor (Dashboard -> SQL Editor -> New query).
-- Run 0002_rls.sql immediately afterwards.
-- =============================================================================

-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------
-- Deliberately none. `gen_random_uuid()` is core since Postgres 13, and invite
-- codes are derived from it below, so pgcrypto is not required. Supabase installs
-- pgcrypto and pg_trgm into the `extensions` schema, and creating them again in
-- `public` is a common source of "operator class does not exist" failures.

-- ----------------------------------------------------------------------------
-- Enums
-- ----------------------------------------------------------------------------
do $$ begin
  create type user_role as enum ('owner', 'admin', 'member');
exception when duplicate_object then null; end $$;

do $$ begin
  create type project_status as enum ('planning', 'active', 'completed', 'archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type project_component_status as enum ('planned', 'allocated', 'purchased', 'used');
exception when duplicate_object then null; end $$;

do $$ begin
  create type transaction_reason as enum (
    'manual_adjust', 'project_allocation', 'purchase_received', 'project_deduction'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type vendor_name as enum ('robu', 'robocraze', 'other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type cart_item_status as enum ('pending', 'added_to_cart', 'failed');
exception when duplicate_object then null; end $$;

-- ----------------------------------------------------------------------------
-- companies
-- ----------------------------------------------------------------------------
create table if not exists public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 120),
  -- 8 hex chars derived from a v4 UUID: no extension dependency, and the
  -- randomness comes from a CSPRNG rather than random().
  invite_code text not null unique
    default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  created_at  timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- users  (profile rows mirroring auth.users; company_id is null until onboarding)
-- ----------------------------------------------------------------------------
create table if not exists public.users (
  id           uuid primary key references auth.users (id) on delete cascade,
  company_id   uuid references public.companies (id) on delete set null,
  email        text not null,
  display_name text,
  role         user_role not null default 'member',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists users_company_id_idx on public.users (company_id);

-- ----------------------------------------------------------------------------
-- inventories  (a company may have unlimited, independently managed inventories)
-- ----------------------------------------------------------------------------
create table if not exists public.inventories (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies (id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 120),
  location_note text,
  created_by    uuid references public.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (company_id, name)
);

create index if not exists inventories_company_id_idx on public.inventories (company_id);

-- ----------------------------------------------------------------------------
-- components  (stock rows; mpn unique per inventory, not globally)
-- ----------------------------------------------------------------------------
create table if not exists public.components (
  id                  uuid primary key default gen_random_uuid(),
  inventory_id        uuid not null references public.inventories (id) on delete cascade,
  mpn                 text not null,
  name                text not null,
  manufacturer        text,
  footprint           text,
  dimensions          text,
  image_url           text,
  quantity            numeric not null default 0 check (quantity >= 0),
  unit                text not null default 'pcs',
  low_stock_threshold numeric not null default 0 check (low_stock_threshold >= 0),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (inventory_id, mpn)
);

create index if not exists components_inventory_id_idx on public.components (inventory_id);
create index if not exists components_mpn_idx on public.components (mpn);
-- No trigram index on name/mpn: the client mirrors every component into its local
-- SQLite cache and searches there, so the server never runs a text search. A
-- pg_trgm index here would only add a setup dependency for no benefit.

-- NOTE: `local_image_path` is intentionally absent here. It is a per-device
-- on-disk cache path and lives only in the local drift cache (see lib/data/local).
-- The canonical, shareable `image_url` above points at Supabase Storage.

-- ----------------------------------------------------------------------------
-- projects  (belong to a company, not to a single inventory)
-- ----------------------------------------------------------------------------
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 160),
  description text,
  status      project_status not null default 'planning',
  created_by  uuid references public.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists projects_company_id_idx on public.projects (company_id);

-- ----------------------------------------------------------------------------
-- project_components
-- ----------------------------------------------------------------------------
create table if not exists public.project_components (
  id                 uuid primary key default gen_random_uuid(),
  project_id         uuid not null references public.projects (id) on delete cascade,
  component_id       uuid not null references public.components (id) on delete restrict,
  inventory_id       uuid not null references public.inventories (id) on delete cascade,
  quantity_required  numeric not null default 0 check (quantity_required >= 0),
  quantity_allocated numeric not null default 0 check (quantity_allocated >= 0),
  description        text,
  status             project_component_status not null default 'planned',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (project_id, component_id)
);

create index if not exists project_components_project_id_idx   on public.project_components (project_id);
create index if not exists project_components_component_id_idx on public.project_components (component_id);
create index if not exists project_components_inventory_id_idx on public.project_components (inventory_id);

-- ----------------------------------------------------------------------------
-- stock_transactions  (append-only audit trail)
-- ----------------------------------------------------------------------------
create table if not exists public.stock_transactions (
  id           uuid primary key default gen_random_uuid(),
  component_id uuid not null references public.components (id) on delete cascade,
  project_id   uuid references public.projects (id) on delete set null,
  user_id      uuid references public.users (id) on delete set null,
  change_qty   numeric not null,
  reason       transaction_reason not null,
  created_at   timestamptz not null default now()
);

create index if not exists stock_transactions_component_id_idx on public.stock_transactions (component_id);
create index if not exists stock_transactions_project_id_idx   on public.stock_transactions (project_id);
create index if not exists stock_transactions_created_at_idx   on public.stock_transactions (created_at desc);

-- ----------------------------------------------------------------------------
-- vendor_price_cache  (cached scrape results; refreshed on demand)
-- ----------------------------------------------------------------------------
create table if not exists public.vendor_price_cache (
  id           uuid primary key default gen_random_uuid(),
  component_id uuid not null references public.components (id) on delete cascade,
  vendor       vendor_name not null,
  price        numeric,
  currency     text not null default 'INR',
  in_stock     boolean,                    -- null => unknown / bot-protected
  product_url  text,
  fetched_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (component_id, vendor)
);

create index if not exists vendor_price_cache_component_id_idx on public.vendor_price_cache (component_id);

-- ----------------------------------------------------------------------------
-- cart_items  (vendor cart automation queue; scoped to one user)
-- ----------------------------------------------------------------------------
create table if not exists public.cart_items (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.users (id) on delete cascade,
  vendor       vendor_name not null,
  component_id uuid not null references public.components (id) on delete cascade,
  quantity     numeric not null default 1 check (quantity > 0),
  status       cart_item_status not null default 'pending',
  error        text,                       -- populated when status = 'failed'
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists cart_items_user_id_idx on public.cart_items (user_id, status);

-- =============================================================================
-- updated_at maintenance
-- =============================================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'users', 'inventories', 'components', 'projects',
    'project_components', 'vendor_price_cache', 'cart_items'
  ] loop
    execute format('drop trigger if exists touch_updated_at on public.%I', t);
    execute format(
      'create trigger touch_updated_at before update on public.%I
         for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- =============================================================================
-- New auth user -> public.users profile row
-- =============================================================================
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- =============================================================================
-- Inventory stock adjustment (keeps the audit trail honest)
-- =============================================================================
-- All quantity mutations funnel through here so a stock_transactions row is
-- always written. The app never UPDATEs components.quantity directly.
create or replace function public.adjust_component_quantity(
  p_component_id uuid,
  p_change_qty   numeric,
  p_reason       transaction_reason,
  p_project_id   uuid default null
)
returns public.components
language plpgsql
security definer
set search_path = public
as $$
declare
  v_component public.components;
  v_new_qty   numeric;
begin
  if p_change_qty = 0 then
    raise exception 'change_qty must be non-zero' using errcode = '22023';
  end if;

  select * into v_component from public.components where id = p_component_id for update;
  if not found then
    raise exception 'component % not found', p_component_id using errcode = 'P0002';
  end if;

  -- Authorisation: caller must belong to the company owning this inventory.
  if v_component.inventory_id not in (
    select i.id from public.inventories i where i.company_id = public.current_company_id()
  ) then
    raise exception 'not authorised for component %', p_component_id using errcode = '42501';
  end if;

  v_new_qty := v_component.quantity + p_change_qty;
  if v_new_qty < 0 then
    raise exception 'insufficient stock: have %, need %', v_component.quantity, abs(p_change_qty)
      using errcode = '23514';
  end if;

  -- guard_component_quantity rejects every UPDATE to quantity, including this
  -- one, so the flag has to be flipped around our own write. Forgetting this
  -- makes every stock adjustment fail at runtime with a misleading
  -- "quantity is read-only" error.
  perform set_config('app.internal', 'on', true);
  update public.components
     set quantity = v_new_qty
   where id = p_component_id
  returning * into v_component;
  perform set_config('app.internal', 'off', true);

  insert into public.stock_transactions (component_id, project_id, user_id, change_qty, reason)
  values (p_component_id, p_project_id, auth.uid(), p_change_qty, p_reason);

  return v_component;
end;
$$;

-- =============================================================================
-- "Proceed with project" — atomic multi-component stock deduction
-- =============================================================================
-- Returns a JSON report:
--   { "project_id": ..., "deducted": [ {component_id, mpn, name, quantity, remaining} ],
--     "shortfalls": [ {component_id, mpn, name, required, available, missing} ] }
-- When p_allow_partial is false (default) NOTHING is deducted if any line is short.
create or replace function public.proceed_with_project(
  p_project_id    uuid,
  p_allow_partial boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_project   public.projects;
  v_line      record;
  v_available numeric;
  v_deducted  jsonb := '[]'::jsonb;
  v_short     jsonb := '[]'::jsonb;
begin
  select * into v_project from public.projects where id = p_project_id;
  if not found then
    raise exception 'project % not found', p_project_id using errcode = 'P0002';
  end if;

  if v_project.company_id is distinct from public.current_company_id() then
    raise exception 'not authorised for project %', p_project_id using errcode = '42501';
  end if;

  -- Pass 1: collect shortfalls against currently-held stock.
  for v_line in
    select pc.id, pc.component_id, pc.quantity_required, pc.status,
           c.mpn, c.name, c.quantity as on_hand
      from public.project_components pc
      join public.components c on c.id = pc.component_id
     where pc.project_id = p_project_id
       and pc.status in ('planned', 'allocated')
     order by c.name
       for update of c
  loop
    if v_line.on_hand < v_line.quantity_required then
      v_short := v_short || jsonb_build_object(
        'component_id', v_line.component_id,
        'mpn',          v_line.mpn,
        'name',         v_line.name,
        'required',     v_line.quantity_required,
        'available',    v_line.on_hand,
        'missing',      v_line.quantity_required - v_line.on_hand
      );
    end if;
  end loop;

  if jsonb_array_length(v_short) > 0 and not p_allow_partial then
    return jsonb_build_object(
      'project_id', p_project_id,
      'committed',  false,
      'deducted',   '[]'::jsonb,
      'shortfalls', v_short
    );
  end if;

  -- Pass 2: deduct the lines we can satisfy.
  --
  -- The whole pass runs with the quantity guard flipped off: guard_component_quantity
  -- rejects every UPDATE to components.quantity, this routine's included.
  perform set_config('app.internal', 'on', true);

  for v_line in
    select pc.id as pc_id, pc.component_id, pc.quantity_required,
           c.mpn, c.name, c.quantity as on_hand
      from public.project_components pc
      join public.components c on c.id = pc.component_id
     where pc.project_id = p_project_id
       and pc.status in ('planned', 'allocated')
     order by c.name
       for update of c
  loop
    v_available := least(v_line.on_hand, v_line.quantity_required);
    continue when v_available <= 0;

    update public.components
       set quantity = quantity - v_available
     where id = v_line.component_id;

    insert into public.stock_transactions (component_id, project_id, user_id, change_qty, reason)
    values (v_line.component_id, p_project_id, auth.uid(), -v_available, 'project_deduction');

    update public.project_components
       set quantity_allocated = quantity_allocated + v_available,
           status = case when v_available >= quantity_required then 'used'::project_component_status
                         else 'allocated'::project_component_status end
     where id = v_line.pc_id;

    v_deducted := v_deducted || jsonb_build_object(
      'component_id', v_line.component_id,
      'mpn',          v_line.mpn,
      'name',         v_line.name,
      'quantity',     v_available,
      'remaining',    v_line.on_hand - v_available
    );
  end loop;

  perform set_config('app.internal', 'off', true);

  -- A project with nothing left outstanding moves to active.
  if not exists (
    select 1 from public.project_components
     where project_id = p_project_id and status in ('planned', 'allocated')
  ) and v_project.status = 'planning' then
    update public.projects set status = 'active' where id = p_project_id;
  end if;

  return jsonb_build_object(
    'project_id', p_project_id,
    'committed',  true,
    'deducted',   v_deducted,
    'shortfalls', v_short
  );
end;
$$;
