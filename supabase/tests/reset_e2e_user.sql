-- =============================================================================
-- Resets the E2E account to a clean onboarding state.
--
-- Run before integration_test/full_journey_test.dart. Without this the account
-- keeps the company created by a previous run, so sign-in lands on the home
-- screen instead of onboarding and the journey cannot exercise company creation.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/reset_e2e_user.sql
-- =============================================================================

do $$
declare
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where email = 'e2e-tester@example.com';

  if v_user_id is null then
    raise exception 'e2e user does not exist — run create_e2e_user.sql first';
  end if;

  -- Drop the company and everything hanging off it (cascades to inventories,
  -- components, projects, project_components, stock_transactions, cart_items).
  delete from public.companies
   where id = (select company_id from public.users where id = v_user_id);

  -- Put the account back to "signed up but not onboarded".
  update public.users
     set company_id = null, role = 'member'
   where id = v_user_id;

  raise notice 'e2e user reset to a pre-onboarding state';
end $$;

select u.email,
       u.company_id,
       (select count(*) from public.companies) as companies,
       (select count(*) from public.components) as components
  from public.users u
 where u.email = 'e2e-tester@example.com';
