-- ====================================================================
-- Migration: Add Admin Account Management RPCs
-- Date: September 13, 2026
-- Description:
--   Enables active administrators to create, update, and delete
--   other administrator accounts directly through secure RPCs.
-- ====================================================================

-- 1. Create Admin Account RPC
create or replace function public.create_admin_account(
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text,
  p_phone text default null
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
  v_clean_email text;
  v_clean_first text;
  v_clean_last text;
  v_clean_phone text;
  v_full_name text;
begin
  -- Enforce admin privileges
  if not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only administrators can create admin accounts.');
  end if;

  -- Validate inputs
  v_clean_email := lower(trim(coalesce(p_email, '')));
  v_clean_first := trim(coalesce(p_first_name, ''));
  v_clean_last := trim(coalesce(p_last_name, ''));
  v_clean_phone := nullif(trim(coalesce(p_phone, '')), '');
  v_full_name := nullif(trim(concat_ws(' ', v_clean_first, v_clean_last)), '');

  if v_clean_email = '' or position('@' in v_clean_email) = 0 then
    return json_build_object('success', false, 'error', 'A valid email address is required.');
  end if;

  if p_password is null or length(trim(p_password)) < 8 then
    return json_build_object('success', false, 'error', 'Password must be at least 8 characters.');
  end if;

  if v_clean_first = '' then
    return json_build_object('success', false, 'error', 'First name is required.');
  end if;

  -- Check if user already exists
  select id into v_user_id from auth.users where email = v_clean_email;
  if v_user_id is not null then
    return json_build_object('success', false, 'error', 'An account with this email address already exists.');
  end if;

  -- Check phone uniqueness in profiles if provided
  if v_clean_phone is not null and exists (
    select 1 from public.profiles where phone_number = v_clean_phone
  ) then
    return json_build_object('success', false, 'error', 'An account with this phone number already exists.');
  end if;

  -- Generate new user ID
  v_user_id := gen_random_uuid();

  -- Insert into auth.users with encrypted password
  insert into auth.users (
    id,
    instance_id,
    email,
    encrypted_password,
    email_confirmed_at,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at,
    aud,
    role,
    phone,
    phone_confirmed_at,
    confirmation_token,
    recovery_token,
    email_change,
    email_change_token_new,
    email_change_token_current,
    phone_change_token,
    reauthentication_token
  ) values (
    v_user_id,
    '00000000-0000-0000-0000-000000000000'::uuid,
    v_clean_email,
    extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    json_build_object(
      'first_name', v_clean_first,
      'last_name', v_clean_last,
      'phone_number', v_clean_phone,
      'role', 'admin'
    )::jsonb,
    now(),
    now(),
    'authenticated',
    'authenticated',
    v_clean_phone,
    now(),
    '', '', '', '', '', '', ''
  );

  -- Insert identity into auth.identities
  insert into auth.identities (
    id,
    user_id,
    provider_id,
    provider,
    identity_data,
    last_sign_in_at,
    created_at,
    updated_at
  ) values (
    v_user_id,
    v_user_id,
    v_clean_email,
    'email',
    json_build_object('sub', v_user_id::text, 'email', v_clean_email)::jsonb,
    now(),
    now(),
    now()
  )
  on conflict do nothing;

  -- Insert profile into public.profiles
  insert into public.profiles (
    id,
    first_name,
    last_name,
    full_name,
    phone_number,
    role,
    email,
    created_at,
    updated_at
  ) values (
    v_user_id,
    v_clean_first,
    v_clean_last,
    v_full_name,
    v_clean_phone,
    'admin',
    v_clean_email,
    now(),
    now()
  )
  on conflict (id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    role = 'admin',
    updated_at = now();

  return json_build_object(
    'success', true,
    'user_id', v_user_id,
    'email', v_clean_email,
    'full_name', v_full_name
  );
exception when others then
  return json_build_object('success', false, 'error', SQLERRM);
end;
$$;


-- 2. Delete Admin Account RPC
create or replace function public.delete_admin_account(p_admin_id uuid)
returns json
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_admin_count int;
  v_target_role public.user_role;
begin
  -- Enforce admin privileges
  if not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only administrators can delete admin accounts.');
  end if;

  -- Prevent deleting oneself
  if p_admin_id = auth.uid() then
    return json_build_object('success', false, 'error', 'You cannot delete your own admin account while logged in.');
  end if;

  -- Verify the target account is an admin
  select role into v_target_role from public.profiles where id = p_admin_id;
  if v_target_role is null or v_target_role <> 'admin' then
    return json_build_object('success', false, 'error', 'Target account is not an administrator.');
  end if;

  -- Ensure at least one admin remains
  select count(*)::int into v_admin_count from public.profiles where role = 'admin';
  if v_admin_count <= 1 then
    return json_build_object('success', false, 'error', 'Cannot delete the only remaining administrator account.');
  end if;

  -- Delete from public tables and auth.users
  delete from public.profiles where id = p_admin_id;
  delete from auth.identities where user_id = p_admin_id;
  delete from auth.users where id = p_admin_id;

  return json_build_object('success', true, 'admin_id', p_admin_id);
exception when others then
  return json_build_object('success', false, 'error', SQLERRM);
end;
$$;


-- 3. Reset Admin Password RPC
create or replace function public.reset_admin_password(
  p_admin_id uuid,
  p_new_password text
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
begin
  -- Enforce admin privileges
  if not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only administrators can reset admin passwords.');
  end if;

  if p_new_password is null or length(trim(p_new_password)) < 8 then
    return json_build_object('success', false, 'error', 'Password must be at least 8 characters.');
  end if;

  -- Update encrypted password in auth.users
  update auth.users
  set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf', 10)),
      updated_at = now()
  where id = p_admin_id;

  if not found then
    return json_build_object('success', false, 'error', 'Admin user not found in auth system.');
  end if;

  return json_build_object('success', true, 'admin_id', p_admin_id);
exception when others then
  return json_build_object('success', false, 'error', SQLERRM);
end;
$$;

-- Grant execute permissions to authenticated users (functions internally enforce public.is_admin())
grant execute on function public.create_admin_account(text, text, text, text, text) to authenticated;
grant execute on function public.delete_admin_account(uuid) to authenticated;
grant execute on function public.reset_admin_password(uuid, text) to authenticated;
