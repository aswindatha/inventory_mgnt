-- =============================================================================
-- Creates a second pre-confirmed account for the multi-user E2E run.
--
-- The built-in mailer is rate-limited to a handful of messages per hour, so a
-- UI sign-up cannot be reliably driven in automation. This inserts the account
-- the same way the app + on_auth_user_created trigger would leave it.
--
-- Idempotent — safe to re-run.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/create_e2e_member.sql
-- =============================================================================

do $$
declare
  v_user_id uuid;
  v_email   text := 'e2e.member.tester@gmail.com';
  v_pass    text := 'E2E-Member-Passw0rd!45';
begin
  select id into v_user_id from auth.users where email = v_email;

  if v_user_id is null then
    v_user_id := gen_random_uuid();

    insert into auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      v_user_id,
      '00000000-0000-0000-0000-000000000000',
      'authenticated',
      'authenticated',
      v_email,
      extensions.crypt(v_pass, extensions.gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"display_name":"E2E Member"}'::jsonb,
      '', '', '', ''
    );

    insert into auth.identities (
      id, provider_id, user_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(),
      v_user_id::text,
      v_user_id,
      jsonb_build_object('sub', v_user_id::text, 'email', v_email, 'email_verified', true),
      'email',
      now(), now(), now()
    );
  end if;

  insert into public.users (id, email, display_name)
  values (v_user_id, v_email, 'E2E Member')
  on conflict (id) do nothing;

  raise notice 'e2e member ready: % (%)', v_email, v_user_id;
end $$;

select id, email, email_confirmed_at is not null as confirmed
  from auth.users
 where email = 'e2e.member.tester@gmail.com';
