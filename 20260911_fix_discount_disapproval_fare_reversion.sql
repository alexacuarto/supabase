-- Migration: Ensure Discount Disapproval Reverts to Regular Fare Everywhere
-- Date: 2026-09-11

-- 1. Correct recalculate_booking_discount_summary to immediately sync actual_fare, final_fare, and estimated_fare to regular_fare on discount rejection
create or replace function public.recalculate_booking_discount_summary(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_passenger public.passengers%rowtype;
  v_fare_config public.fare_configurations%rowtype;
  v_regular_count int := 0;
  v_student_count int := 0;
  v_pwd_count int := 0;
  v_senior_count int := 0;
  v_total_count int := 1;
  v_stops_count int := 1;
  v_additional_km numeric := 0;
  v_charged_additional_km int := 0;
  v_base_per_passenger numeric := 0;
  v_per_passenger_subtotal numeric := 0;
  v_regular_fare numeric := 0;
  v_final_fare numeric := 0;
  v_request_count int := 0;
  v_pending_count int := 0;
  v_rejected_count int := 0;
  v_approved_count int := 0;
  v_eligible_student int := 0;
  v_eligible_pwd int := 0;
  v_eligible_senior int := 0;
  v_status text := 'NOT_REQUIRED';
begin
  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking is null then
    raise exception 'Booking not found.';
  end if;

  select p.*
  into v_passenger
  from public.passengers p
  where p.id = v_booking.passenger_id;

  v_regular_count := coalesce((v_booking.passenger_qty ->> 'Regular')::int, 0);
  v_student_count := coalesce((v_booking.passenger_qty ->> 'Student')::int, 0);
  v_pwd_count := coalesce((v_booking.passenger_qty ->> 'PWD')::int, 0);
  v_senior_count := coalesce((v_booking.passenger_qty ->> 'Senior Citizens')::int, 0)
                    + coalesce((v_booking.passenger_qty ->> 'Senior Citizen')::int, 0);
  v_total_count := greatest(1, v_regular_count + v_student_count + v_pwd_count + v_senior_count);

  -- Fetch total stops count (minimum 1)
  v_stops_count := greatest(
    1,
    coalesce(
      v_booking.total_stops,
      case
        when v_booking.stops is not null and jsonb_typeof(to_jsonb(v_booking.stops)) = 'array'
        then jsonb_array_length(to_jsonb(v_booking.stops))
        else 1
      end
    )
  );

  -- Select proper fare configuration based on trip_type (Special Trip maps to round_trip)
  select *
  into v_fare_config
  from public.fare_configurations
  where trip_type = case
    when lower(coalesce(v_booking.trip_type, 'one_way')) like '%round%'
      or lower(coalesce(v_booking.trip_type, 'one_way')) like '%special%' then 'round_trip'
    else 'one_way'
  end
    and is_active = true
  limit 1;

  if v_fare_config is null then
    select *
    into v_fare_config
    from public.fare_configurations
    where is_active = true
    order by (case when trip_type = 'one_way' then 1 else 2 end)
    limit 1;
  end if;

  if v_fare_config is null then
    v_final_fare := coalesce(v_booking.final_fare, v_booking.actual_fare, v_booking.estimated_fare, 0);
    update public.bookings
    set final_fare = v_final_fare,
        actual_fare = v_final_fare,
        discount_reviewed_at = now(),
        updated_at = now()
    where id = p_booking_id;
    return json_build_object('success', true, 'final_fare', v_final_fare);
  end if;

  -- Count discount requests:
  -- Eligible discounts include APPROVED and PENDING (provisional). REJECTED discounts are NOT eligible.
  select
    count(*)::int,
    count(*) filter (where status = 'PENDING')::int,
    count(*) filter (where status = 'REJECTED')::int,
    count(*) filter (where status = 'APPROVED')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and lower(discount_type) like '%student%')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and lower(discount_type) like '%pwd%')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and (lower(discount_type) like '%senior%' or lower(discount_type) like '%citizen%'))::int
  into v_request_count, v_pending_count, v_rejected_count, v_approved_count, v_eligible_student, v_eligible_pwd, v_eligible_senior
  from public.booking_discount_requests
  where booking_id = p_booking_id;

  v_eligible_student := least(v_student_count, coalesce(v_eligible_student, 0));
  v_eligible_pwd := least(v_pwd_count, coalesce(v_eligible_pwd, 0));
  v_eligible_senior := least(v_senior_count, coalesce(v_eligible_senior, 0));

  -- Distance & fare calculation incorporating stops
  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - (v_fare_config.included_km * v_stops_count));
  v_charged_additional_km := ceil(v_additional_km)::int;
  v_base_per_passenger := v_fare_config.base_fare * v_stops_count;
  v_per_passenger_subtotal := v_base_per_passenger + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := v_per_passenger_subtotal * v_total_count;

  -- Dynamic final fare: subtract only currently eligible discounts
  v_final_fare := v_regular_fare
    - (v_per_passenger_subtotal * (v_fare_config.student_discount / 100) * v_eligible_student)
    - (v_per_passenger_subtotal * (v_fare_config.pwd_discount / 100) * v_eligible_pwd)
    - (v_per_passenger_subtotal * (v_fare_config.senior_citizen_discount / 100) * v_eligible_senior);
  v_final_fare := greatest(0, round(v_final_fare, 2));

  if v_request_count = 0 then
    v_status := 'NOT_REQUIRED';
  elsif v_pending_count > 0 and (v_rejected_count > 0 or v_approved_count > 0) then
    v_status := 'PARTIALLY_APPROVED';
  elsif v_pending_count > 0 then
    v_status := 'PENDING_DRIVER_REVIEW';
  elsif v_rejected_count = v_request_count then
    v_status := 'REJECTED';
  elsif v_rejected_count > 0 then
    v_status := 'PARTIALLY_APPROVED';
  else
    v_status := 'APPROVED';
  end if;

  -- Ensure that when all discounts are rejected, final_fare equals regular_fare exactly
  if v_status = 'REJECTED' then
    v_final_fare := v_regular_fare;
  end if;

  update public.bookings
  set regular_fare = coalesce(regular_fare, v_regular_fare),
      provisional_discounted_fare = coalesce(provisional_discounted_fare, estimated_fare),
      final_fare = v_final_fare,
      actual_fare = v_final_fare,
      estimated_fare = case when v_status = 'REJECTED' then v_final_fare else estimated_fare end,
      discount_review_status = v_status,
      discount_verified = case
        when v_status = 'APPROVED' then true
        when v_status = 'REJECTED' then false
        else discount_verified
      end,
      passenger_type_display = case
        when v_status = 'REJECTED' then 'Regular'
        else passenger_type_display
      end,
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare,
    'actual_fare', v_final_fare,
    'regular_fare', v_regular_fare
  );
end;
$$;

-- 2. Fix complete_booking to prioritize final_fare over actual_fare and estimated_fare
create or replace function public.complete_booking(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_driver_id uuid;
  v_final_fare numeric;
begin
  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
  limit 1;

  if v_driver_id is null and not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only assigned driver can complete booking.');
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking is null then
    return json_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_driver_id is not null and v_booking.driver_id <> v_driver_id then
    return json_build_object('success', false, 'error', 'Driver mismatch for booking completion.');
  end if;

  if v_booking.status::text = 'completed' then
    return json_build_object('success', true, 'booking_id', p_booking_id, 'status', 'completed', 'already_completed', true);
  end if;

  if v_booking.status::text not in ('pickedUp', 'droppedOff', 'paymentSent') then
    return json_build_object('success', false, 'error', 'Booking cannot be completed from current status: ' || v_booking.status::text);
  end if;

  if lower(coalesce(v_booking.trip_type, '')) like '%round%'
     and v_booking.trip_phase <> 'payment' then
    return json_build_object('success', false, 'error', 'Round trip cannot be completed before arriving at the return location.');
  end if;

  -- Determine final settled fare (final_fare takes highest precedence, then actual_fare, then regular_fare if rejected, then estimated_fare)
  v_final_fare := coalesce(
    v_booking.final_fare,
    v_booking.actual_fare,
    case when v_booking.discount_review_status = 'REJECTED' or v_booking.discount_verified = false then v_booking.regular_fare else null end,
    v_booking.estimated_fare,
    0
  );

  update public.bookings
  set status = 'completed',
      trip_phase = 'completed',
      final_fare = v_final_fare,
      actual_fare = v_final_fare,
      completed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  update public.drivers
  set last_completed_ride_at = now()
  where id = v_booking.driver_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'status', 'completed',
    'fare', v_final_fare
  );
end;
$$;

-- 3. Fix reject_booking_discount_and_revert_fare RPC
create or replace function public.reject_booking_discount_and_revert_fare(
  p_booking_id uuid,
  p_reason text default 'Physical ID not accepted'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_regular_fare numeric(10,2);
  v_driver_id uuid;
  v_passenger_profile_id uuid;
  v_summary json;
begin
  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
  limit 1;

  if v_driver_id is null and not public.is_admin() then
    raise exception 'Only assigned drivers or admins can reject discount.';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Booking not found.';
  end if;

  v_regular_fare := coalesce(v_booking.regular_fare, v_booking.estimated_fare);

  -- Mark all pending companion requests for this booking as REJECTED
  update public.booking_discount_requests
  set status = 'REJECTED',
      rejection_reason = p_reason,
      reviewed_by_driver_id = v_driver_id,
      reviewed_at = now(),
      updated_at = now()
  where booking_id = p_booking_id
    and status = 'PENDING';

  -- Recalculate summary to guarantee math consistency
  v_summary := public.recalculate_booking_discount_summary(p_booking_id);

  -- Ensure direct booking columns are fully updated
  update public.bookings
  set discount_verified = false,
      discount_rejected_reason = p_reason,
      passenger_type_display = 'Regular',
      discount_review_status = 'REJECTED',
      final_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      actual_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      estimated_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  -- Notify passenger of regular fare reversion
  select profile_id into v_passenger_profile_id
  from public.passengers
  where id = v_booking.passenger_id;

  if v_passenger_profile_id is not null then
    insert into public.notifications (
      recipient_id, type, title, body, notification_category, data, is_read, is_sent
    )
    values (
      v_passenger_profile_id,
      'in_app',
      'Discount Not Accepted - Fare Reverted',
      format('Your driver could not accept the discount ID. The fare has reverted to the regular price of ₱%s.', coalesce(v_regular_fare, 0)),
      'discount_rejected',
      jsonb_build_object(
        'booking_id', p_booking_id,
        'status', 'REJECTED',
        'reason', p_reason,
        'fare', v_regular_fare
      ),
      false,
      true
    );
  end if;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'fare', v_regular_fare,
    'regular_fare', v_regular_fare,
    'final_fare', v_regular_fare,
    'actual_fare', v_regular_fare
  );
end;
$$;

-- 4. Retroactive Data Repair: update any past rejected bookings where fare was not reverted
update public.bookings
set final_fare = coalesce(regular_fare, actual_fare, estimated_fare),
    actual_fare = coalesce(regular_fare, actual_fare, estimated_fare),
    estimated_fare = coalesce(regular_fare, estimated_fare)
where (discount_review_status = 'REJECTED' or discount_verified = false)
  and regular_fare is not null
  and regular_fare > 0;
