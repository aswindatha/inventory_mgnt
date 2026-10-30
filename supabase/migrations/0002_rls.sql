-- =============================================================================
-- Electronics Inventory Management — Row Level Security + RPCs
-- Migration 0002: helper functions, guards, policies, onboarding RPCs, storage
--
-- Run AFTER 0001_schema.sql.
-- =============================================================================

-- =============================================================================
-- Permission helpers
--
-- These are SECURITY DEFINER so they can read public.users without re-entering
-- its own RLS policies (the classic "infinite recursion detected in policy"
-- trap). search_path is pinned to avoid hijacking.
-- =============================================================================

create or replace function public.current_company_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select company_id from public.users where id = auth.uid()
$$;

create or replace function public.current_user_role()
returns user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.users where id = auth.uid()
$$;

create or replace function public.is_owner_or_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select role in ('owner', 'admin') from public.users where id = auth.uid()),
    false
  )
$$;

create or replace function public.can_access_company(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_company_id is not null
     and p_company_id = public.current_company_id()
$$;

create or replace function public.can_access_inventory(p_inventory_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.inventories i
     where i.id = p_inventory_id
       and i.company_id = public.current_company_id()
  )
$$;

create or replace function public.can_access_project(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.projects p
     where p.id = p_project_id
       and p.company_id = public.current_company_id()
  )
$$;

create or replace function public.can_access_component(p_component_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.components c
      join public.inventories i on i.id = c.inventory_id
     where c.id = p_component_id
       and i.company_id = public.current_company_id()
  )
$$;

grant execute on function
  public.current_company_id(),
  public.current_user_role(),
  public.is_owner_or_admin(),
  public.can_access_company(uuid),
  public.can_access_inventory(uuid),
  public.can_access_project(uuid),
  public.can_access_component(uuid)
to authenticated;

-- =============================================================================
-- Integrity guards
--
-- `app.internal` is a transaction-local GUC flipped on by the SECURITY DEFINER
-- RPCs below, which are the only code allowed to move a user between companies
-- or mutate stock quantities directly.
-- =============================================================================

create or replace function public.internal_op_active()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('app.internal', true), 'off') = 'on'
$$;

-- Blocks self-service privilege escalation / company hopping.
create or replace function public.guard_user_self_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.internal_op_active() then
    return new;
  end if;

  if auth.uid() = old.id and not public.is_owner_or_admin() then
    if new.company_id is distinct from old.company_id then
      raise exception 'company_id can only be changed via create_company/join_company_by_invite'
        using errcode = '42501';
    end if;
    if new.role is distinct from old.role then
      raise exception 'role can only be changed by an owner or admin'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_user_self_update on public.users;
create trigger guard_user_self_update
  before update on public.users
  for each row execute function public.guard_user_self_update();

-- Forces every quantity change through adjust_component_quantity so the
-- stock_transactions audit trail can never be bypassed.
create or replace function public.guard_component_quantity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.internal_op_active() then
    return new;
  end if;

  if new.quantity is distinct from old.quantity then
    raise exception
      'components.quantity is read-only; call adjust_component_quantity() instead'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_component_quantity on public.components;
create trigger guard_component_quantity
  before update on public.components
  for each row execute function public.guard_component_quantity();

-- =============================================================================
-- Onboarding / team RPCs
-- =============================================================================

create or replace function public.create_company(p_name text)
returns public.companies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from public.users where id = auth.uid() and company_id is not null) then
    raise exception 'you already belong to a company' using errcode = '23505';
  end if;

  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'company name is required' using errcode = '22023';
  end if;

  insert into public.companies (name) values (trim(p_name)) returning * into v_company;

  perform set_config('app.internal', 'on', true);
  update public.users
     set company_id = v_company.id, role = 'owner'
   where id = auth.uid();
  perform set_config('app.internal', 'off', true);

  -- Every company starts with one inventory so the home screen is never empty.
  insert into public.inventories (company_id, name, created_by)
  values (v_company.id, 'Main Inventory', auth.uid());

  return v_company;
end;
$$;

create or replace function public.join_company_by_invite(p_code text)
returns public.companies
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from public.users where id = auth.uid() and company_id is not null) then
    raise exception 'you already belong to a company' using errcode = '23505';
  end if;

  select * into v_company
    from public.companies
   where invite_code = upper(trim(p_code));

  if not found then
    raise exception 'invalid invite code' using errcode = 'P0002';
  end if;

  perform set_config('app.internal', 'on', true);
  update public.users
     set company_id = v_company.id, role = 'member'
   where id = auth.uid();
  perform set_config('app.internal', 'off', true);

  return v_company;
end;
$$;

create or replace function public.regenerate_invite_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_owner_or_admin() then
    raise exception 'only owners and admins can rotate the invite code' using errcode = '42501';
  end if;

  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  update public.companies set invite_code = v_code where id = public.current_company_id();

  return v_code;
end;
$$;

create or replace function public.update_member_role(p_user_id uuid, p_role user_role)
returns public.users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users;
begin
  if not public.is_owner_or_admin() then
    raise exception 'only owners and admins can change roles' using errcode = '42501';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'you cannot change your own role' using errcode = '42501';
  end if;

  select * into v_user from public.users where id = p_user_id;
  if not found or v_user.company_id is distinct from public.current_company_id() then
    raise exception 'user is not a member of your company' using errcode = 'P0002';
  end if;

  -- Only an owner may mint another owner.
  if p_role = 'owner' and public.current_user_role() <> 'owner' then
    raise exception 'only an owner can promote another owner' using errcode = '42501';
  end if;

  if v_user.role = 'owner' and public.current_user_role() <> 'owner' then
    raise exception 'only an owner can change another owner''s role' using errcode = '42501';
  end if;

  perform set_config('app.internal', 'on', true);
  update public.users set role = p_role where id = p_user_id returning * into v_user;
  perform set_config('app.internal', 'off', true);

  return v_user;
end;
$$;

create or replace function public.remove_user_from_company(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.users;
begin
  if not public.is_owner_or_admin() then
    raise exception 'only owners and admins can remove members' using errcode = '42501';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'use leave_company() to remove yourself' using errcode = '42501';
  end if;

  select * into v_target from public.users where id = p_user_id;
  if not found or v_target.company_id is distinct from public.current_company_id() then
    raise exception 'user is not a member of your company' using errcode = 'P0002';
  end if;

  if v_target.role = 'owner' then
    raise exception 'the company owner cannot be removed' using errcode = '42501';
  end if;

  perform set_config('app.internal', 'on', true);
  update public.users set company_id = null, role = 'member' where id = p_user_id;
  perform set_config('app.internal', 'off', true);
end;
$$;

-- Lets a non-owner walk away; the last owner is blocked from orphaning the company.
create or replace function public.leave_company()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_company_id();
begin
  if v_company is null then
    raise exception 'you do not belong to a company' using errcode = 'P0002';
  end if;

  if public.current_user_role() = 'owner'
     and (select count(*) from public.users where company_id = v_company and role = 'owner') <= 1
     and (select count(*) from public.users where company_id = v_company) > 1
  then
    raise exception 'promote another owner before leaving' using errcode = '42501';
  end if;

  perform set_config('app.internal', 'on', true);
  update public.users set company_id = null, role = 'member' where id = auth.uid();
  perform set_config('app.internal', 'off', true);
end;
$$;

grant execute on function
  public.create_company(text),
  public.join_company_by_invite(text),
  public.regenerate_invite_code(),
  public.update_member_role(uuid, user_role),
  public.remove_user_from_company(uuid),
  public.leave_company(),
  public.adjust_component_quantity(uuid, numeric, transaction_reason, uuid),
  public.proceed_with_project(uuid, boolean)
to authenticated;

-- =============================================================================
-- Row Level Security
-- =============================================================================
alter table public.companies           enable row level security;
alter table public.users               enable row level security;
alter table public.inventories         enable row level security;
alter table public.components          enable row level security;
alter table public.projects            enable row level security;
alter table public.project_components  enable row level security;
alter table public.stock_transactions  enable row level security;
alter table public.vendor_price_cache  enable row level security;
alter table public.cart_items          enable row level security;

-- ---- companies --------------------------------------------------------------
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies
  for select to authenticated
  using (id = public.current_company_id());

drop policy if exists companies_update on public.companies;
create policy companies_update on public.companies
  for update to authenticated
  using (id = public.current_company_id() and public.is_owner_or_admin())
  with check (id = public.current_company_id() and public.is_owner_or_admin());

drop policy if exists companies_delete on public.companies;
create policy companies_delete on public.companies
  for delete to authenticated
  using (id = public.current_company_id() and public.current_user_role() = 'owner');

-- No INSERT policy: companies are created exclusively via create_company().

-- ---- users ------------------------------------------------------------------
drop policy if exists users_select on public.users;
create policy users_select on public.users
  for select to authenticated
  using (id = auth.uid() or company_id = public.current_company_id());

drop policy if exists users_update on public.users;
create policy users_update on public.users
  for update to authenticated
  using (id = auth.uid() or (company_id = public.current_company_id() and public.is_owner_or_admin()))
  with check (id = auth.uid() or (company_id = public.current_company_id() and public.is_owner_or_admin()));

-- No INSERT policy (handled by the on_auth_user_created trigger) and no DELETE
-- policy (use remove_user_from_company / leave_company).

-- ---- inventories ------------------------------------------------------------
drop policy if exists inventories_select on public.inventories;
create policy inventories_select on public.inventories
  for select to authenticated
  using (company_id = public.current_company_id());

drop policy if exists inventories_insert on public.inventories;
create policy inventories_insert on public.inventories
  for insert to authenticated
  with check (company_id = public.current_company_id() and created_by = auth.uid());

-- Members may rename inventories / edit location notes; only owner+admin delete.
drop policy if exists inventories_update on public.inventories;
create policy inventories_update on public.inventories
  for update to authenticated
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

drop policy if exists inventories_delete on public.inventories;
create policy inventories_delete on public.inventories
  for delete to authenticated
  using (company_id = public.current_company_id() and public.is_owner_or_admin());

-- ---- components -------------------------------------------------------------
drop policy if exists components_select on public.components;
create policy components_select on public.components
  for select to authenticated
  using (public.can_access_inventory(inventory_id));

drop policy if exists components_insert on public.components;
create policy components_insert on public.components
  for insert to authenticated
  with check (public.can_access_inventory(inventory_id));

-- quantity is pinned by guard_component_quantity; everything else is editable.
drop policy if exists components_update on public.components;
create policy components_update on public.components
  for update to authenticated
  using (public.can_access_inventory(inventory_id))
  with check (public.can_access_inventory(inventory_id));

drop policy if exists components_delete on public.components;
create policy components_delete on public.components
  for delete to authenticated
  using (public.can_access_inventory(inventory_id));

-- ---- projects ---------------------------------------------------------------
drop policy if exists projects_select on public.projects;
create policy projects_select on public.projects
  for select to authenticated
  using (company_id = public.current_company_id());

drop policy if exists projects_insert on public.projects;
create policy projects_insert on public.projects
  for insert to authenticated
  with check (company_id = public.current_company_id() and created_by = auth.uid());

drop policy if exists projects_update on public.projects;
create policy projects_update on public.projects
  for update to authenticated
  using (company_id = public.current_company_id())
  with check (company_id = public.current_company_id());

drop policy if exists projects_delete on public.projects;
create policy projects_delete on public.projects
  for delete to authenticated
  using (company_id = public.current_company_id() and public.is_owner_or_admin());

-- ---- project_components -----------------------------------------------------
drop policy if exists project_components_select on public.project_components;
create policy project_components_select on public.project_components
  for select to authenticated
  using (public.can_access_project(project_id));

drop policy if exists project_components_insert on public.project_components;
create policy project_components_insert on public.project_components
  for insert to authenticated
  with check (
    public.can_access_project(project_id)
    and public.can_access_inventory(inventory_id)
  );

drop policy if exists project_components_update on public.project_components;
create policy project_components_update on public.project_components
  for update to authenticated
  using (public.can_access_project(project_id))
  with check (
    public.can_access_project(project_id)
    and public.can_access_inventory(inventory_id)
  );

drop policy if exists project_components_delete on public.project_components;
create policy project_components_delete on public.project_components
  for delete to authenticated
  using (public.can_access_project(project_id));

-- ---- stock_transactions (append-only, RPC-written) --------------------------
drop policy if exists stock_transactions_select on public.stock_transactions;
create policy stock_transactions_select on public.stock_transactions
  for select to authenticated
  using (public.can_access_component(component_id));

-- No INSERT/UPDATE/DELETE policies: rows are written only by the
-- SECURITY DEFINER routines adjust_component_quantity / proceed_with_project.

-- ---- vendor_price_cache -----------------------------------------------------
drop policy if exists vendor_price_cache_select on public.vendor_price_cache;
create policy vendor_price_cache_select on public.vendor_price_cache
  for select to authenticated
  using (public.can_access_component(component_id));

drop policy if exists vendor_price_cache_insert on public.vendor_price_cache;
create policy vendor_price_cache_insert on public.vendor_price_cache
  for insert to authenticated
  with check (public.can_access_component(component_id));

drop policy if exists vendor_price_cache_update on public.vendor_price_cache;
create policy vendor_price_cache_update on public.vendor_price_cache
  for update to authenticated
  using (public.can_access_component(component_id))
  with check (public.can_access_component(component_id));

drop policy if exists vendor_price_cache_delete on public.vendor_price_cache;
create policy vendor_price_cache_delete on public.vendor_price_cache
  for delete to authenticated
  using (public.can_access_component(component_id));

-- ---- cart_items (strictly per-user) ----------------------------------------
drop policy if exists cart_items_select on public.cart_items;
create policy cart_items_select on public.cart_items
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists cart_items_insert on public.cart_items;
create policy cart_items_insert on public.cart_items
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists cart_items_update on public.cart_items;
create policy cart_items_update on public.cart_items
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists cart_items_delete on public.cart_items;
create policy cart_items_delete on public.cart_items
  for delete to authenticated
  using (user_id = auth.uid());

-- =============================================================================
-- Column-level hardening: components.quantity is not client-writable
-- =============================================================================
-- guard_component_quantity already rejects direct UPDATEs, but it keys off the
-- `app.internal` custom GUC — and any role can set a custom GUC. Revoking the
-- column makes the restriction unbypassable: privilege checks run before
-- triggers, so a client cannot flip the flag and slip a quantity change past the
-- audit trail.
--
-- Two traps here, both of which make a naive `revoke update (quantity)` a no-op:
--   1. Supabase's default privileges grant *table-level* UPDATE. Privileges are
--      additive, and a column-level REVOKE does not narrow a table-level GRANT.
--      The table-level grant must be dropped first.
--   2. The writable columns then have to be granted back individually, or the
--      app's "edit component" form stops working.
--
-- SECURITY DEFINER routines (adjust_component_quantity, proceed_with_project)
-- execute as the table owner and are unaffected. INSERT is untouched, so a new
-- component can still be created with an opening quantity in one round trip.
revoke update on public.components from anon, authenticated;
grant update (
  mpn,
  name,
  manufacturer,
  footprint,
  dimensions,
  image_url,
  unit,
  low_stock_threshold
) on public.components to authenticated;

-- =============================================================================
-- Storage: component images
--
-- Public-read bucket so Image.network()/cached_network_image can render without
-- signed URLs. Writes are fenced to the caller's own company prefix:
--   component-images/<company_id>/<component_id>.<ext>
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'component-images', 'component-images', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists component_images_read on storage.objects;
create policy component_images_read on storage.objects
  for select to public
  using (bucket_id = 'component-images');

drop policy if exists component_images_insert on storage.objects;
create policy component_images_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'component-images'
    and (storage.foldername(name))[1] = public.current_company_id()::text
  );

drop policy if exists component_images_update on storage.objects;
create policy component_images_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'component-images'
    and (storage.foldername(name))[1] = public.current_company_id()::text
  );

drop policy if exists component_images_delete on storage.objects;
create policy component_images_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'component-images'
    and (storage.foldername(name))[1] = public.current_company_id()::text
  );
