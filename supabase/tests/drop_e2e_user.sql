-- =============================================================================
-- Removes the E2E test account and everything it created.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/drop_e2e_user.sql
-- =============================================================================

do $$
declare
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where email = 'e2e-tester@example.com';

  if v_user_id is null then
    raise notice 'no e2e user to remove';
    return;
  end if;

  -- Deleting the company cascades to inventories, components, projects and
  -- their dependants.
  delete from public.companies
   where id = (select company_id from public.users where id = v_user_id);

  -- Deleting the auth user cascades to public.users.
  delete from auth.users where id = v_user_id;

  raise notice 'e2e user and its company removed';
end $$;

select count(*) as remaining_e2e_users
  from auth.users where email = 'e2e-tester@example.com';
