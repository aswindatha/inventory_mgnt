-- =============================================================================
-- Marks e2e-member@example.com's email as confirmed.
--
-- Stands in for clicking the confirmation link in the E2E run — there is no
-- mailbox on the test side, so the server-side flag is set directly. The app
-- behaviour being exercised is identical: sign-in was blocked before confirm
-- and succeeds after.
--
--   python tool/run_sql.py supabase/tests/confirm_e2e_member.sql
-- =============================================================================

do $$
declare
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where email = 'e2e.member.tester@gmail.com';
  if v_user_id is null then
    raise exception 'e2e member does not exist — sign up first';
  end if;

  update auth.users
     set email_confirmed_at = coalesce(email_confirmed_at, now()),
         confirmation_token = ''
   where id = v_user_id;

  raise notice 'e2e-member email confirmed';
end $$;

select email, email_confirmed_at is not null as confirmed
  from auth.users where email = 'e2e.member.tester@gmail.com';
