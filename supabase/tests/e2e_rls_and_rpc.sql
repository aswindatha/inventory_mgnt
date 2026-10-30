-- =============================================================================
-- End-to-end tests: schema, RPCs, guard triggers and RLS policies.
--
-- Everything runs inside ONE transaction that ROLLBACKs at the end, so this is
-- safe to run against a live project — no rows survive. It exercises the real
-- policies as the real `authenticated` role, by simulating the JWT `sub` claim
-- that auth.uid() reads.
--
-- Usage:
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/e2e_rls_and_rpc.sql
--
-- Exits non-zero on the first failed assertion.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------
create or replace function public._assert(cond boolean, msg text)
returns void
language plpgsql
as $$
begin
  if cond is not true then
    raise exception 'ASSERTION FAILED: %', msg;
  end if;
  raise notice '  ok  %', msg;
end $$;

-- Simulates being signed in as `uid` (auth.uid() reads this claim).
create or replace function public._login(uid uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(uid::text, ''), true);
end $$;

create or replace function public._logout()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- =============================================================================
-- 1. Signup trigger
-- =============================================================================
\echo '--- 1. signup trigger creates a profile row ---'

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '{"display_name":"Alice"}'::jsonb),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com',   '{"display_name":"Bob"}'::jsonb),
  ('33333333-3333-3333-3333-333333333333', 'carol@example.com', '{}'::jsonb);

select public._assert(
  (select count(*) from public.users where id = '11111111-1111-1111-1111-111111111111') = 1,
  'profile row created for a new auth user'
);
select public._assert(
  (select display_name from public.users where id = '11111111-1111-1111-1111-111111111111') = 'Alice',
  'display_name taken from raw_user_meta_data'
);
select public._assert(
  (select display_name from public.users where id = '33333333-3333-3333-3333-333333333333') = 'carol',
  'display_name falls back to the email local-part'
);
select public._assert(
  (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111') is null,
  'company_id starts null until onboarding'
);

-- =============================================================================
-- 2. Onboarding RPCs
-- =============================================================================
\echo '--- 2. create_company / join_company_by_invite ---'

set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

select public.create_company('Acme Electronics');

reset role;

select public._assert(
  (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111') is not null,
  'create_company assigns the caller a company'
);
select public._assert(
  (select role from public.users where id = '11111111-1111-1111-1111-111111111111') = 'owner',
  'the creator becomes owner'
);
select public._assert(
  (select length(invite_code) from public.companies
    where id = (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111')) = 8,
  'invite code is 8 characters'
);
select public._assert(
  (select count(*) from public.inventories
    where company_id = (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111')) = 1,
  'a default inventory is seeded so the home screen is never empty'
);

-- Bob must NOT be able to read the invite code, because companies_select only
-- exposes his own company and he has none yet. This is deliberate: it stops a
-- signed-up stranger from enumerating companies. The RPC is SECURITY DEFINER and
-- resolves the code server-side, and the app has the user type it in by hand.
set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');
select public._assert(
  (select count(*) from public.companies) = 0,
  'a user with no company cannot enumerate companies or read invite codes'
);
reset role;

-- Capture the code as postgres, the way the app receives it from a human.
select invite_code as acme_code
  from public.companies
 where id = (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111');
\gset

-- Bob joins with the invite code.
set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');
select public.join_company_by_invite(:'acme_code');
reset role;

select public._assert(
  (select company_id from public.users where id = '22222222-2222-2222-2222-222222222222')
    = (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111'),
  'join_company_by_invite puts the joiner in the same company'
);
select public._assert(
  (select role from public.users where id = '22222222-2222-2222-2222-222222222222') = 'member',
  'the joiner becomes a member, not an owner'
);

-- Carol starts a separate company, for isolation tests.
set local role authenticated;
select public._login('33333333-3333-3333-3333-333333333333');
select public.create_company('Globex');
reset role;

-- Negative paths.
set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');

do $$
begin
  perform public.create_company('Second Company');
  raise exception 'ASSERTION FAILED: a user already in a company could create another';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  create_company refused for a user already in a company';
end $$;

do $$
begin
  perform public.join_company_by_invite('NOTACODE');
  raise exception 'ASSERTION FAILED: an invalid invite code was accepted';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  invalid invite code rejected';
end $$;

reset role;

-- =============================================================================
-- 3. RLS: tenant isolation
-- =============================================================================
\echo '--- 3. RLS tenant isolation ---'

-- Give Acme some stock, as the owner.
set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

insert into public.components (inventory_id, mpn, name, quantity, low_stock_threshold)
values (
  (select id from public.inventories
    where company_id = (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111')
    limit 1),
  'LM358DR', 'Dual Op-Amp', 100, 5
);

reset role;

-- Carol must see none of it.
set local role authenticated;
select public._login('33333333-3333-3333-3333-333333333333');

select public._assert(
  (select count(*) from public.inventories) = 1,
  'Carol sees only her own inventory, not Acme''s'
);
select public._assert(
  (select count(*) from public.components) = 0,
  'Carol sees zero of Acme''s components'
);
select public._assert(
  (select count(*) from public.users) = 1,
  'Carol sees only herself in the members list'
);
select public._assert(
  (select count(*) from public.companies) = 1,
  'Carol sees only her own company'
);

-- Cross-tenant read by explicit id is still filtered.
select public._assert(
  (select count(*) from public.components
    where mpn = 'LM358DR') = 0,
  'a targeted lookup for another tenant''s part returns nothing'
);

reset role;

-- =============================================================================
-- 4. RLS: role capabilities
-- =============================================================================
\echo '--- 4. RLS role capabilities ---'

-- Bob is a member: he must not be able to delete an inventory.
set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');

do $$
declare affected int;
begin
  delete from public.inventories
   where company_id = (select company_id from public.users where id = '22222222-2222-2222-2222-222222222222');
  get diagnostics affected = row_count;
  perform public._assert(affected = 0, 'a member cannot delete an inventory');
end $$;

select public._assert(
  (select count(*) from public.inventories) = 1,
  'the inventory is still there after the member''s delete attempt'
);

-- A member CAN create a component (spec §2).
insert into public.components (inventory_id, mpn, name, quantity)
values ((select id from public.inventories limit 1), 'NE555P', 'Timer IC', 40);

select public._assert(
  (select count(*) from public.components where mpn = 'NE555P') = 1,
  'a member can create a component'
);

reset role;

-- The owner CAN delete.
set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

insert into public.inventories (company_id, name, created_by)
values (
  (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111'),
  'Scratch', '11111111-1111-1111-1111-111111111111'
);

do $$
declare affected int;
begin
  delete from public.inventories where name = 'Scratch';
  get diagnostics affected = row_count;
  perform public._assert(affected = 1, 'an owner can delete an inventory');
end $$;

reset role;

-- =============================================================================
-- 5. Privilege escalation is blocked
-- =============================================================================
\echo '--- 5. privilege escalation ---'

set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');

do $$
begin
  update public.users set role = 'owner' where id = '22222222-2222-2222-2222-222222222222';
  raise exception 'ASSERTION FAILED: a member promoted themselves to owner';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  self-promotion to owner blocked by guard_user_self_update';
end $$;

do $$
begin
  update public.users set company_id = null where id = '22222222-2222-2222-2222-222222222222';
  raise exception 'ASSERTION FAILED: a member cleared their own company_id';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  self-service company hop blocked';
end $$;

do $$
begin
  perform public.update_member_role('22222222-2222-2222-2222-222222222222', 'owner');
  raise exception 'ASSERTION FAILED: a member changed roles via the RPC';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  update_member_role refused for a member';
end $$;

do $$
begin
  perform public.remove_user_from_company('11111111-1111-1111-1111-111111111111');
  raise exception 'ASSERTION FAILED: a member removed the owner';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  remove_user_from_company refused for a member';
end $$;

reset role;

-- The owner can promote.
set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');
select public.update_member_role('22222222-2222-2222-2222-222222222222', 'admin');
reset role;

select public._assert(
  (select role from public.users where id = '22222222-2222-2222-2222-222222222222') = 'admin',
  'the owner can promote a member to admin'
);

-- =============================================================================
-- 6. Quantity guard + audit trail
-- =============================================================================
\echo '--- 6. quantity guard and audit trail ---'

set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

do $$
begin
  update public.components set quantity = 999 where mpn = 'LM358DR';
  raise exception 'ASSERTION FAILED: quantity was updated directly, bypassing the audit trail';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  direct quantity UPDATE rejected by guard_component_quantity';
end $$;

-- Editing metadata is still allowed.
update public.components set manufacturer = 'Texas Instruments' where mpn = 'LM358DR';
select public._assert(
  (select manufacturer from public.components where mpn = 'LM358DR') = 'Texas Instruments',
  'metadata edits still work while quantity is pinned'
);

-- The legitimate path.
select public.adjust_component_quantity(
  (select id from public.components where mpn = 'LM358DR'),
  25, 'manual_adjust'
);

select public._assert(
  (select quantity from public.components where mpn = 'LM358DR') = 125,
  'adjust_component_quantity applies the change'
);
select public._assert(
  (select count(*) from public.stock_transactions st
     join public.components c on c.id = st.component_id
    where c.mpn = 'LM358DR' and st.change_qty = 25 and st.reason = 'manual_adjust') = 1,
  'the adjustment wrote an audit row'
);
select public._assert(
  (select user_id from public.stock_transactions st
     join public.components c on c.id = st.component_id
    where c.mpn = 'LM358DR' and st.change_qty = 25) = '11111111-1111-1111-1111-111111111111',
  'the audit row attributes the change to the acting user'
);

do $$
begin
  perform public.adjust_component_quantity(
    (select id from public.components where mpn = 'LM358DR'), -10000, 'manual_adjust'
  );
  raise exception 'ASSERTION FAILED: stock was allowed to go negative';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  over-removal rejected (insufficient stock)';
end $$;

select public._assert(
  (select quantity from public.components where mpn = 'LM358DR') = 125,
  'the failed removal left stock untouched'
);

-- =============================================================================
-- 7. proceed_with_project
-- =============================================================================
\echo '--- 7. proceed_with_project ---'

-- A project that is fully satisfiable.
insert into public.projects (company_id, name, created_by)
values (
  (select company_id from public.users where id = '11111111-1111-1111-1111-111111111111'),
  'Line Follower', '11111111-1111-1111-1111-111111111111'
);

insert into public.project_components (project_id, component_id, inventory_id, quantity_required, description)
select
  (select id from public.projects where name = 'Line Follower'),
  c.id, c.inventory_id, 30, 'Motor driver stage'
from public.components c
where c.mpn = 'LM358DR';

reset role;
set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

-- --- all-or-nothing refusal ---
-- Add a second line that is short.
insert into public.components (inventory_id, mpn, name, quantity)
select inventory_id, 'ATMEGA328P', 'MCU', 2
from public.components where mpn = 'LM358DR';

insert into public.project_components (project_id, component_id, inventory_id, quantity_required)
select
  (select id from public.projects where name = 'Line Follower'),
  c.id, c.inventory_id, 50
from public.components c where c.mpn = 'ATMEGA328P';

select public._assert(
  (public.proceed_with_project((select id from public.projects where name = 'Line Follower'))->>'committed')::boolean = false,
  'a short line makes the run refuse to commit'
);
select public._assert(
  jsonb_array_length(public.proceed_with_project((select id from public.projects where name = 'Line Follower'))->'shortfalls') = 1,
  'the shortfall list names exactly the short line'
);
select public._assert(
  (select quantity from public.components where mpn = 'LM358DR') = 125,
  'nothing was deducted from the satisfiable line when the run refused'
);
select public._assert(
  (select status from public.project_components pc join public.components c on c.id = pc.component_id
    where c.mpn = 'LM358DR') = 'planned',
  'the satisfiable line is still planned'
);

-- --- partial commit ---
select public.proceed_with_project(
  (select id from public.projects where name = 'Line Follower'), p_allow_partial => true
);

select public._assert(
  (select quantity from public.components where mpn = 'LM358DR') = 95,
  'partial run deducted the satisfiable line (125 - 30)'
);
select public._assert(
  (select quantity from public.components where mpn = 'ATMEGA328P') = 0,
  'partial run took the short line''s available stock (2)'
);
select public._assert(
  (select status from public.project_components pc join public.components c on c.id = pc.component_id
    where c.mpn = 'LM358DR') = 'used',
  'a fully satisfied line is marked used'
);
select public._assert(
  (select status from public.project_components pc join public.components c on c.id = pc.component_id
    where c.mpn = 'ATMEGA328P') = 'allocated',
  'a partially satisfied line is marked allocated, not used'
);
select public._assert(
  (select count(*) from public.stock_transactions
    where reason = 'project_deduction'
      and project_id = (select id from public.projects where name = 'Line Follower')) = 2,
  'two project_deduction audit rows were written'
);
select public._assert(
  (select quantity_allocated from public.project_components pc join public.components c on c.id = pc.component_id
    where c.mpn = 'ATMEGA328P') = 2,
  'quantity_allocated tracks what was actually taken'
);

-- --- cross-tenant refusal ---
reset role;
set local role authenticated;
select public._login('33333333-3333-3333-3333-333333333333');

do $$
begin
  perform public.proceed_with_project((select id from public.projects where name = 'Line Follower'));
  raise exception 'ASSERTION FAILED: Carol ran proceed on another company''s project';
exception
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  proceed_with_project refused for a different company';
end $$;

reset role;

-- =============================================================================
-- 8. Append-only audit trail + per-user cart
-- =============================================================================
\echo '--- 8. audit trail and cart isolation ---'

set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

do $$
begin
  insert into public.stock_transactions (component_id, change_qty, reason)
  values ((select id from public.components where mpn = 'LM358DR'), 999, 'manual_adjust');
  raise exception 'ASSERTION FAILED: a client forged an audit row';
exception
  when insufficient_privilege then
    raise notice '  ok  direct INSERT into stock_transactions denied';
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  direct INSERT into stock_transactions rejected (%)', sqlerrm;
end $$;

reset role;

-- Cart items are strictly per-user.
set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');
insert into public.cart_items (user_id, vendor, component_id, quantity)
values ('11111111-1111-1111-1111-111111111111', 'robu',
        (select id from public.components where mpn = 'LM358DR'), 3);
reset role;

set local role authenticated;
select public._login('22222222-2222-2222-2222-222222222222');
select public._assert(
  (select count(*) from public.cart_items) = 0,
  'a teammate cannot see another user''s cart queue'
);
reset role;

-- =============================================================================
-- 9. Cart status transitions
-- =============================================================================
\echo '--- 9. cart status transitions ---'

set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

update public.cart_items set status = 'added_to_cart' where vendor = 'robu';
select public._assert(
  (select status from public.cart_items limit 1) = 'added_to_cart',
  'the owning user can advance their own cart row'
);

reset role;

-- =============================================================================
-- 10. updated_at maintenance
-- =============================================================================
\echo '--- 10. updated_at trigger ---'

-- `now()` is fixed for the whole transaction, so the trigger's effect cannot be
-- observed by comparing against created_at here. Pin the value into the past
-- with the trigger disabled, then let a real write move it.
alter table public.components disable trigger touch_updated_at;
update public.components set updated_at = timestamptz '2000-01-01' where mpn = 'LM358DR';
alter table public.components enable trigger touch_updated_at;

select public._assert(
  (select updated_at from public.components where mpn = 'LM358DR') = timestamptz '2000-01-01',
  'setup: updated_at pinned into the past'
);

set local role authenticated;
select public._login('11111111-1111-1111-1111-111111111111');

update public.components set unit = 'pcs' where mpn = 'LM358DR';

-- A client must not be able to forge the conflict-resolution timestamp: it is
-- excluded from the column-level UPDATE grant.
do $$
begin
  update public.components set updated_at = timestamptz '2000-01-01' where mpn = 'LM358DR';
  raise exception 'ASSERTION FAILED: a client wrote updated_at directly';
exception
  when insufficient_privilege then
    raise notice '  ok  clients cannot write updated_at directly';
  when others then
    if sqlerrm like 'ASSERTION FAILED%' then raise; end if;
    raise notice '  ok  clients cannot write updated_at directly (%)', sqlerrm;
end $$;

reset role;

select public._assert(
  (select updated_at from public.components where mpn = 'LM358DR') > timestamptz '2000-01-01',
  'touch_updated_at advanced updated_at on write'
);

-- ---------------------------------------------------------------------------
-- Everything above is discarded.
-- ---------------------------------------------------------------------------
\echo ''
\echo '=== all assertions passed; rolling back ==='

rollback;
