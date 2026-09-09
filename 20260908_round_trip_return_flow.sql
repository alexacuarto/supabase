-- Revision: Round-trip return location and synced trip phase support
-- Apply this to existing Supabase projects that were created before
-- these columns were added to todago_final_bootstrap.sql.

alter table public.bookings
  add column if not exists return_address text,
  add column if not exists return_latitude double precision,
  add column if not exists return_longitude double precision,
  add column if not exists trip_phase text not null default 'to_pickup',
  add column if not exists destination_arrived_at timestamptz,
  add column if not exists return_arrived_at timestamptz;

alter table public.bookings
  drop constraint if exists bookings_trip_phase_check;

alter table public.bookings
  add constraint bookings_trip_phase_check
  check (
    trip_phase in (
      'to_pickup',
      'waiting_pickup',
      'to_destination',
      'to_return',
      'payment',
      'completed'
    )
  );

create index if not exists idx_bookings_trip_phase
  on public.bookings(status, trip_phase);

create or replace function public.accept_booking(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_booking_status text;
  v_current_driver_id uuid;
begin
  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
    and status = 'approved'
    and is_online = true
    and coalesce(admin_action_type, '') <> 'restricted'
  limit 1;

  if v_driver_id is null then
    return json_build_object('success', false, 'error', 'You must be an approved online driver to accept rides.');
  end if;

  select status::text, driver_id
  into v_booking_status, v_current_driver_id
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking_status is null then
    return json_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_booking_status not in ('pending', 'searching') or v_current_driver_id is not null then
    return json_build_object('success', false, 'error', 'This ride is no longer available.');
  end if;

  update public.bookings
  set driver_id = v_driver_id,
      status = 'accepted',
      trip_phase = 'to_pickup',
      accepted_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object('success', true, 'driver_id', v_driver_id, 'booking_id', p_booking_id, 'status', 'accepted');
end;
$$;

create or replace function public.complete_booking(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_booking record;
begin
  select id
  into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
    and status = 'approved'
  limit 1;

  if v_driver_id is null then
    return json_build_object('success', false, 'error', 'You are not registered as an approved driver.');
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking is null then
    return json_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_booking.driver_id != v_driver_id then
    return json_build_object('success', false, 'error', 'This booking is not assigned to you.');
  end if;

  if v_booking.status::text not in ('pickedUp', 'droppedOff', 'paymentSent') then
    return json_build_object('success', false, 'error', 'Booking cannot be completed from current status: ' || v_booking.status::text);
  end if;

  if lower(coalesce(v_booking.trip_type, '')) like '%round%'
     and v_booking.trip_phase <> 'payment' then
    return json_build_object('success', false, 'error', 'Round trip cannot be completed before arriving at the return location.');
  end if;

  update public.bookings
  set status = 'completed',
      trip_phase = 'completed',
      actual_fare = coalesce(actual_fare, estimated_fare),
      completed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  update public.drivers
  set last_completed_ride_at = now()
  where id = v_driver_id;

  return json_build_object('success', true, 'booking_id', p_booking_id, 'status', 'completed', 'fare', coalesce(v_booking.actual_fare, v_booking.estimated_fare));
end;
$$;
