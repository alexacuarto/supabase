-- Apply once to an existing project before deploying the revised apps.
-- Does not delete booking history or reset operational records.
begin;

create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and is_active = true
  );
$$;

create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      if new.role = 'admin' then raise exception 'Only administrators can assign administrator access.'; end if;
    elsif old.role is distinct from new.role then
      raise exception 'Only administrators can change account roles.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_guard_role_trg on public.profiles;
create trigger profiles_guard_role_trg before insert or update on public.profiles
for each row execute function public.guard_profile_role();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role_txt text;
  v_role public.user_role;
  v_first_name text;
  v_last_name text;
  v_full_name text;
begin
  v_role_txt := coalesce(new.raw_user_meta_data->>'role', 'passenger');
  if v_role_txt not in ('passenger', 'driver') then
    v_role_txt := 'passenger';
  end if;
  v_role := v_role_txt::public.user_role;

  v_first_name := coalesce(new.raw_user_meta_data->>'first_name', '');
  v_last_name := coalesce(new.raw_user_meta_data->>'last_name', '');
  v_full_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', concat_ws(' ', v_first_name, v_last_name))), '');

  insert into public.profiles (id, role, first_name, last_name, full_name, phone_number, email)
  values (
    new.id,
    v_role,
    v_first_name,
    v_last_name,
    v_full_name,
    coalesce(new.raw_user_meta_data->>'phone_number', new.phone),
    new.email
  )
  on conflict (id) do update set
    role = excluded.role,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    updated_at = now();

  if v_role = 'passenger' then
    insert into public.passengers (id, profile_id)
    values (new.id, new.id)
    on conflict (profile_id) do nothing;
  end if;

  return new;
end;
$$;

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
  if not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only admins can create driver accounts.');
  end if;

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

  return json_build_object('success', true, 'driver_id', v_driver_id, 'user_id', v_user_id, 'toda_association', v_clean_toda);
end;
$$;

create or replace function public.admin_restrict_passenger(p_passenger_id uuid, p_days int default 31)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Invalid restriction duration.'; end if;
  update public.passengers
  set booking_restriction_until = now() + make_interval(days => p_days), updated_at = now()
  where id = p_passenger_id;
  if not found then raise exception 'Passenger not found.'; end if;
end;
$$;

create or replace function public.admin_lift_passenger_restriction(p_passenger_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;
  update public.passengers
  set booking_restriction_until = null, updated_at = now()
  where id = p_passenger_id;
  if not found then raise exception 'Passenger not found.'; end if;
end;
$$;

-- A cancellation by another party must not recreate a restriction lifted by an admin.
create or replace function public.recalculate_passenger_cancellation_stats(
  p_passenger_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_cancelled integer := 0;
  v_policy_cancelled integer := 0;
  v_driver_cancelled integer := 0;
  v_last_passenger_cancel timestamptz;
  v_restriction_until timestamptz;
  v_previous_count integer;
begin
  if auth.uid() is not null and not public.is_admin()
     and p_passenger_id is distinct from public.current_passenger_id()
     and pg_trigger_depth() = 0 then
    raise exception 'Not authorized to recalculate this passenger.';
  end if;
  select cancel_count, booking_restriction_until into v_previous_count, v_restriction_until
  from public.passengers where id = p_passenger_id for update;

  select
    count(*) filter (where status = 'cancelled')::integer,
    count(*) filter (
      where status = 'cancelled'
        and (cancelled_by = 'passenger' or cancelled_by is null)
        and coalesce(cancelled_at, created_at) >= now() - interval '31 days'
    )::integer,
    count(*) filter (where status = 'cancelled' and cancelled_by = 'driver')::integer,
    max(cancelled_at) filter (
      where status = 'cancelled'
        and (cancelled_by = 'passenger' or cancelled_by is null)
    )
  into v_total_cancelled, v_policy_cancelled, v_driver_cancelled, v_last_passenger_cancel
  from public.bookings
  where passenger_id = p_passenger_id;

  if v_policy_cancelled >= 3 and v_policy_cancelled > coalesce(v_previous_count, 0) then
    v_restriction_until := greatest(v_restriction_until, now() + interval '31 days');
  elsif v_restriction_until <= now() then
    v_restriction_until := null;
  end if;

  update public.passengers
  set cancel_count = coalesce(v_policy_cancelled, 0),
      last_cancel_date = v_last_passenger_cancel,
      warning_status = coalesce(v_policy_cancelled, 0) = 2,
      booking_restriction_until = v_restriction_until,
      updated_at = now()
  where id = p_passenger_id;

  return jsonb_build_object(
    'success', true,
    'passenger_id', p_passenger_id,
    'total_cancelled', coalesce(v_total_cancelled, 0),
    'policy_cancelled', coalesce(v_policy_cancelled, 0),
    'driver_cancelled', coalesce(v_driver_cancelled, 0),
    'restricted_until', v_restriction_until
  );
end;
$$;

-- Validate passenger eligibility at the database boundary as well as in the app.
create or replace function public.guard_passenger_booking_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_passenger public.passengers%rowtype;
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  select * into v_passenger from public.passengers where id = new.passenger_id;
  if v_passenger.profile_id is distinct from auth.uid() then raise exception 'Passenger account mismatch.'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and is_active) then raise exception 'Account is inactive.'; end if;
  if v_passenger.discount_document_status in ('PENDING', 'REJECTED') then raise exception 'Account verification is required.'; end if;
  if v_passenger.booking_restriction_until > now() then raise exception 'Account is restricted from booking.'; end if;
  return new;
end;
$$;
drop trigger if exists bookings_guard_passenger_insert_trg on public.bookings;
create trigger bookings_guard_passenger_insert_trg before insert on public.bookings
for each row execute function public.guard_passenger_booking_insert();

create or replace function public.guard_booking_cancellation()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then return new; end if;
  if old.status = 'completed' then raise exception 'Cannot cancel a completed booking.'; end if;
  if auth.uid() is not null and not public.is_admin() then
    if old.passenger_id = public.current_passenger_id() then
      if old.status not in ('pending', 'searching') or old.driver_id is not null then
        raise exception 'Ask your driver to cancel an ongoing trip.';
      end if;
      new.cancelled_by := 'passenger';
    elsif old.driver_id = public.current_driver_id() then
      if old.status not in ('accepted', 'driver_arriving', 'pickedUp') then
        raise exception 'This trip can no longer be cancelled by the driver.';
      end if;
      new.cancelled_by := 'driver';
    else
      raise exception 'Only the booking participants or an administrator can cancel this trip.';
    end if;
  end if;
  new.cancelled_at := now();
  return new;
end;
$$;
drop trigger if exists bookings_guard_cancellation_trg on public.bookings;
create trigger bookings_guard_cancellation_trg before update on public.bookings
for each row execute function public.guard_booking_cancellation();

create or replace function public.notify_booking_event()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_title text;
  v_body text;
  v_category text;
begin
  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status
       and old.trip_phase is not distinct from new.trip_phase then return new; end if;
  end if;
  case new.status
    when 'pending', 'searching' then
      v_title := 'Ride Request Sent'; v_body := 'Searching for an available driver.'; v_category := 'search';
    when 'accepted' then
      v_title := 'Driver Accepted'; v_body := 'A driver has accepted your booking.'; v_category := 'accept';
    when 'driver_arriving' then
      v_title := 'Driver Arriving'; v_body := 'Your driver is at or approaching the pickup location.'; v_category := 'arriving';
    when 'pickedUp' then
      v_title := case when new.trip_phase = 'to_return' then 'Return Trip Started' else 'Trip Started' end;
      v_body := case when new.trip_phase = 'to_return' then 'Your trip is heading to the return location.' else 'Your trip is underway.' end;
      v_category := 'pickup';
    when 'droppedOff' then
      v_title := 'Destination Reached'; v_body := 'The trip has reached its destination. Payment is pending.'; v_category := 'complete';
    when 'paymentSent' then
      v_title := 'Payment Confirmation Pending'; v_body := 'The passenger marked cash as paid. Driver confirmation is pending.'; v_category := 'payment';
    when 'completed' then
      v_title := 'Trip Completed'; v_body := 'The driver confirmed payment and completed this booking.'; v_category := 'complete';
    when 'cancelled' then
      v_title := 'Booking Cancelled';
      v_body := case when new.cancelled_by = 'driver' then 'The driver cancelled this booking.'
                     when new.cancelled_by = 'passenger' then 'The passenger cancelled this booking.'
                     else 'This booking was cancelled.' end;
      if nullif(trim(new.cancel_reason), '') is not null then v_body := v_body || ' Reason: ' || new.cancel_reason; end if;
      v_category := 'cancel';
    else return new;
  end case;

  insert into public.notifications(recipient_id, title, body, notification_category, data)
  select profile_id, v_title, v_body, v_category,
    jsonb_build_object('booking_id', new.id, 'status', new.status, 'trip_phase', new.trip_phase, 'cancelled_by', new.cancelled_by)
  from (
    select profile_id from public.passengers where id = new.passenger_id
    union
    select profile_id from public.drivers where id = new.driver_id
  ) recipients where profile_id is not null;
  return new;
end;
$$;
drop trigger if exists bookings_notify_event_trg on public.bookings;
create trigger bookings_notify_event_trg after insert or update of status, trip_phase on public.bookings
for each row execute function public.notify_booking_event();

drop policy if exists notifications_delete_own on public.notifications;
create policy notifications_delete_own on public.notifications for delete to authenticated
using (recipient_id = auth.uid());

create or replace function public.get_passenger_public_stats(p_passenger_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() and p_passenger_id is distinct from public.current_passenger_id()
    and not exists (
      select 1 from public.bookings where passenger_id = p_passenger_id
      and (driver_id = public.current_driver_id() or
        (driver_id is null and status in ('pending', 'searching') and public.current_driver_can_view_bookings()))
    ) then raise exception 'Passenger is not visible to this account.'; end if;
  return jsonb_build_object('completed_trips',
    (select count(*) from public.bookings where passenger_id = p_passenger_id and status = 'completed'));
end;
$$;
revoke all on function public.get_passenger_public_stats(uuid) from public;
grant execute on function public.get_passenger_public_stats(uuid) to authenticated;

do $$
declare v_table text;
begin
  foreach v_table in array array['bookings', 'profiles', 'passengers', 'drivers', 'vehicles', 'notifications', 'booking_discount_requests', 'driver_profile_change_requests', 'reports'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end;
$$;
commit;
