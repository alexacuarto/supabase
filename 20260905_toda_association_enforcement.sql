-- ============================================================================
-- TODA GO: Driver TODA Association Enforcement & Earnings Sync Migration
-- Date: 2026-09-05
-- Description:
--   1. Ensures public.drivers.toda_association defaults to 'LHITC-TODA'.
--   2. Backfills any NULL, empty, or 'Not provided' driver toda_association values.
--   3. Updates create_driver_account RPC to guarantee p_toda_association is
--      persisted on driver creation and profile reuse.
--   4. Adds an admin RPC update_driver_toda_association to allow reassigning TODA.
--   5. Reconciles any legacy bookings where driver_id was stored as auth profile_id.
-- ============================================================================

-- ── 1. Backfill legacy driver records and set column default ─────────────────
do $$
begin
  -- Set column default
  alter table public.drivers
    alter column toda_association set default 'LHITC-TODA';

  -- Backfill any null or empty toda_association
  update public.drivers
  set toda_association = 'LHITC-TODA'
  where toda_association is null
     or trim(toda_association) = ''
     or toda_association = 'Not provided';
exception
  when others then
    null;
end $$;

-- ── 2. Add validation check constraint on drivers.toda_association ───────────
do $$
begin
  alter table public.drivers
    drop constraint if exists check_valid_toda_association;

  alter table public.drivers
    add constraint check_valid_toda_association
    check (toda_association in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA'));
exception
  when others then
    null;
end $$;

-- ── 3. Update create_driver_account RPC ──────────────────────────────────────
create or replace function public.create_driver_account(
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text,
  p_phone text,
  p_plate_number text,
  p_toda_association text default 'LHITC-TODA'
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
  v_driver_id uuid;
  v_type_id uuid;
  v_existing_profile_role public.user_role;
  v_clean_toda text;
begin
  -- Admin check
  if (auth.jwt() -> 'user_metadata' ->> 'role') is distinct from 'admin'
     and not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only admins can create driver accounts.');
  end if;

  -- Clean & validate TODA association
  v_clean_toda := coalesce(nullif(trim(p_toda_association), ''), 'LHITC-TODA');
  if v_clean_toda not in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') then
    v_clean_toda := 'LHITC-TODA';
  end if;

  select id into v_user_id from auth.users where email = p_email;
  if v_user_id is not null then
    select role into v_existing_profile_role from public.profiles where id = v_user_id;
    if exists (select 1 from public.drivers where profile_id = v_user_id and document_status = 'VERIFIED') then
      return json_build_object('success', false, 'error', 'Driver account already exists.');
    elsif v_existing_profile_role = 'passenger' then
      return json_build_object('success', false, 'error', 'This email is already registered as a passenger account.');
    end if;
  end if;

  if p_phone is not null and p_phone <> '' and exists (
    select 1
    from public.profiles
    where phone_number = p_phone
      and (v_user_id is null or id <> v_user_id)
      and role = 'passenger'
  ) then
    return json_build_object('success', false, 'error', 'This phone number is already registered as a passenger account.');
  end if;

  if exists (
    select 1
    from public.vehicles v
    join public.drivers d on d.id = v.driver_id
    where v.plate_number = p_plate_number
      and (v_user_id is null or d.profile_id <> v_user_id)
  ) then
    return json_build_object('success', false, 'error', 'Plate number already registered to another driver.');
  end if;

  if v_user_id is null then
    v_user_id := gen_random_uuid();

    insert into auth.users (
      id, instance_id, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      aud, role, phone, phone_confirmed_at,
      confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current,
      phone_change_token, reauthentication_token
    ) values (
      v_user_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      p_email,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      json_build_object('first_name', p_first_name, 'last_name', p_last_name, 'phone_number', p_phone, 'role', 'driver')::jsonb,
      now(), now(),
      'authenticated', 'authenticated', p_phone, now(),
      '', '', '', '', '', '', ''
    );

    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (
      v_user_id,
      v_user_id,
      p_email,
      'email',
      json_build_object('sub', v_user_id::text, 'email', p_email)::jsonb,
      now(), now(), now()
    )
    on conflict do nothing;
  end if;

  insert into public.profiles (id, first_name, last_name, full_name, phone_number, role, email)
  values (v_user_id, p_first_name, p_last_name, nullif(trim(concat_ws(' ', p_first_name, p_last_name)), ''), p_phone, 'driver', p_email)
  on conflict (id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    role = 'driver',
    updated_at = now();

  insert into public.drivers (profile_id, license_number, status, approved_at, toda_association)
  values (v_user_id, 'PENDING', 'approved', now(), v_clean_toda)
  on conflict (profile_id) do update set
    approved_at = coalesce(public.drivers.approved_at, now()),
    toda_association = coalesce(nullif(trim(excluded.toda_association), ''), public.drivers.toda_association, v_clean_toda),
    updated_at = now()
  returning id into v_driver_id;

  select id into v_type_id from public.vehicle_types where is_active = true order by created_at limit 1;

  if v_type_id is not null and v_driver_id is not null then
    insert into public.vehicles (driver_id, vehicle_type_id, plate_number)
    values (v_driver_id, v_type_id, p_plate_number)
    on conflict (driver_id) do update set
      vehicle_type_id = excluded.vehicle_type_id,
      plate_number = excluded.plate_number,
      updated_at = now();
  end if;

  return json_build_object(
    'success', true,
    'driver_id', v_driver_id,
    'user_id', v_user_id,
    'toda_association', v_clean_toda
  );
end;
$$;

-- ── 4. Admin RPC to update a driver's TODA Association ────────────────────────
create or replace function public.update_driver_toda_association(
  p_driver_id uuid,
  p_toda_association text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clean_toda text;
  v_driver public.drivers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can update driver TODA associations.';
  end if;

  v_clean_toda := trim(coalesce(p_toda_association, ''));
  if v_clean_toda not in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') then
    raise exception 'Invalid TODA association. Must be LHITC-TODA, BYPASS ILAYANG BAGUIO-TODA, or CHOT-TODA.';
  end if;

  update public.drivers
  set toda_association = v_clean_toda,
      updated_at = now()
  where id = p_driver_id
  returning * into v_driver;

  if not found then
    raise exception 'Driver with ID % was not found.', p_driver_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'driver_id', p_driver_id,
    'toda_association', v_clean_toda
  );
end;
$$;

-- ── 5. Reconcile legacy bookings with driver profile_id instead of driver_id ──
do $$
begin
  update public.bookings b
  set driver_id = d.id
  from public.drivers d
  where b.driver_id = d.profile_id
    and b.driver_id is not null;
exception
  when others then
    null;
end $$;
