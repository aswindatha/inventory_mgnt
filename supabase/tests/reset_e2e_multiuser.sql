-- =============================================================================
-- Resets the two-account E2E fixture to a clean state.
--
--   1. e2e-tester@example.com goes back to "signed up, not onboarded" and its
--      company is dropped (cascades to inventories, components, projects...).
--   2. e2e-member@example.com is deleted entirely so the run can exercise the
--      real sign-up UI, including the "Confirm email" gate.
--
--   python tool/run_sql.py supabase/tests/reset_e2e_multiuser.sql
-- =============================================================================

do $$
declare
  v_user_id uuid;
begin
  -- Reset the owner account.
  select id into v_user_id from auth.users where email = 'e2e-tester@example.com';
  if v_user_id is null then
    raise exception 'e2e user does not exist — run create_e2e_user.sql first';
  end if;

  delete from public.companies
   where id = (select company_id from public.users where id = v_user_id);

  update public.users
     set company_id = null, role = 'member'
   where id = v_user_id;

  -- Drop the member account completely (cascades to public.users).
  select id into v_user_id from auth.users where email = 'e2e.member.tester@gmail.com';
  if v_user_id is not null then
    -- If the member somehow owns a company, drop that too.
    delete from public.companies
     where id = (select company_id from public.users where id = v_user_id);
    delete from auth.users where id = v_user_id;
  end if;

  raise notice 'owner reset to pre-onboarding; member account dropped';
end $$;

select email from auth.users
 where email in ('e2e-tester@example.com', 'e2e.member.tester@gmail.com');
