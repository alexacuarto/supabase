-- ============================================================================
-- TODA GO: Passenger ID Verification & Companion Discount Sync Migration
-- Date: 2026-09-05
-- Description:
--   1. Relaxes booking_discount_requests.id_image_path constraint to allow physical
--      in-person ID verification (defaults to 'PHYSICAL_VERIFICATION').
--   2. Updates review_passenger_discount_document RPC so that Regular passenger IDs
--      can also be approved/rejected by admins, activating their account upon approval.
--   3. Updates recalculate_booking_discount_summary to ensure estimated_fare, final_fare,
--      and actual_fare are always synchronized when discounts are rejected or approved.
--   4. Adds reject_booking_discount_and_revert_fare RPC for direct driver single-discount rejection.
-- ============================================================================

-- ── 1. Allow Physical In-Person Verification for Companion Discounts ─────────
do $$
begin
  -- Make id_image_path nullable and set default to PHYSICAL_VERIFICATION
  alter table public.booking_discount_requests
    alter column id_image_path drop not null;
  alter table public.booking_discount_requests
    alter column id_image_path set default 'PHYSICAL_VERIFICATION';
exception
  when others then
    null;
end $$;

-- ── 2. Admin Passenger ID Approval & Document Review RPC ──────────────────────
create or replace function public.review_passenger_discount_document(
  p_passenger_id uuid,
  p_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_passenger public.passengers%rowtype;
  v_is_regular boolean;
  v_title text;
  v_body text;
begin
  if not public.is_admin() then
    raise exception 'Only admins can review passenger IDs.';
  end if;

  if p_status not in ('VERIFIED', 'REJECTED') then
    raise exception 'Review status must be VERIFIED or REJECTED.';
  end if;

  select *
  into v_passenger
  from public.passengers
  where id = p_passenger_id
  for update;

  if not found then
    raise exception 'Passenger was not found.';
  end if;

  v_is_regular := (v_passenger.account_passenger_type = 'Regular');

  update public.passengers
  set discount_document_status = p_status,
      discount_document_rejection_reason = case when p_status = 'REJECTED' then nullif(trim(coalesce(p_reason, '')), '') else null end,
      discount_document_reviewed_at = now(),
      discount_document_reviewed_by = auth.uid(),
      discount_eligible = case when v_is_regular then false else (p_status = 'VERIFIED') end,
      updated_at = now()
  where id = p_passenger_id;

  -- Synchronize profile status
  if p_status = 'VERIFIED' then
    update public.profiles
    set is_active = true,
        updated_at = now()
    where id = v_passenger.profile_id;
  elsif p_status = 'REJECTED' and v_is_regular then
    update public.profiles
    set is_active = false,
        updated_at = now()
    where id = v_passenger.profile_id;
  end if;

  v_title := case
    when p_status = 'VERIFIED' and v_is_regular then 'Account ID Approved'
    when p_status = 'VERIFIED' then 'Discount ID Approved'
    when v_is_regular then 'Account ID Rejected'
    else 'Discount ID Rejected'
  end;

  v_body := case
    when p_status = 'VERIFIED' and v_is_regular then 'Your identification has been verified and your account is now fully approved.'
    when p_status = 'VERIFIED' then 'Your discount ID has been approved. Concessionary fares are now available for your account.'
    else coalesce(nullif(trim(p_reason), ''), 'Your submitted ID could not be verified. Please submit a clear and valid identification document.')
  end;

  insert into public.notifications (
    recipient_id,
    type,
    title,
    body,
    data,
    notification_category
  )
  values (
    v_passenger.profile_id,
    'in_app',
    v_title,
    v_body,
    jsonb_build_object('passenger_id', p_passenger_id, 'discount_document_status', p_status),
    'account'
  );

  return jsonb_build_object('success', true, 'status', p_status);
end;
$$;

-- ── 3. Companion Discount Recalculation & Synchronized Fare Reversion ────────
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
  v_student_count integer := 0;
  v_pwd_count integer := 0;
  v_senior_count integer := 0;
  v_regular_count integer := 0;
  v_total_count integer := 0;
  v_account_student integer := 0;
  v_account_pwd integer := 0;
  v_account_senior integer := 0;
  v_approved_student integer := 0;
  v_approved_pwd integer := 0;
  v_approved_senior integer := 0;
  v_request_count integer := 0;
  v_pending_count integer := 0;
  v_rejected_count integer := 0;
  v_additional_km double precision;
  v_charged_additional_km integer;
  v_per_passenger_subtotal numeric(10,2);
  v_regular_fare numeric(10,2);
  v_final_fare numeric(10,2);
  v_status text;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Booking not found.';
  end if;

  select * into v_passenger
  from public.passengers
  where id = v_booking.passenger_id;

  select * into v_fare_config
  from public.fare_configurations
  where is_active is true
    and (
      (v_booking.trip_type = 'One-way' and trip_type = 'one_way')
      or (v_booking.trip_type = 'Round-trip' and trip_type = 'round_trip')
      or trip_type = 'one_way'
    )
  order by case
    when v_booking.trip_type = 'One-way' and trip_type = 'one_way' then 1
    when v_booking.trip_type = 'Round-trip' and trip_type = 'round_trip' then 1
    else 2
  end
  limit 1;

  if not found then
    raise exception 'Active fare configuration not found.';
  end if;

  v_student_count := coalesce((v_booking.passenger_qty->>'Student')::int, 0);
  v_pwd_count := coalesce((v_booking.passenger_qty->>'PWD')::int, 0);
  v_senior_count := coalesce((v_booking.passenger_qty->>'Senior Citizens')::int, (v_booking.passenger_qty->>'Senior Citizen')::int, 0);
  v_regular_count := coalesce((v_booking.passenger_qty->>'Regular')::int, 0);
  v_total_count := v_student_count + v_pwd_count + v_senior_count + v_regular_count;

  if v_total_count <= 0 then
    v_total_count := 1;
    v_regular_count := 1;
  end if;

  if v_passenger.discount_eligible is true and v_passenger.discount_document_status = 'VERIFIED' then
    if v_passenger.account_passenger_type = 'Student' and v_student_count > 0 then
      v_account_student := 1;
    elsif v_passenger.account_passenger_type = 'PWD' and v_pwd_count > 0 then
      v_account_pwd := 1;
    elsif v_passenger.account_passenger_type = 'Senior Citizen' and v_senior_count > 0 then
      v_account_senior := 1;
    end if;
  end if;

  select
    count(*)::int,
    count(*) filter (where status = 'PENDING')::int,
    count(*) filter (where status = 'REJECTED')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'Student')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'PWD')::int,
    count(*) filter (where status = 'APPROVED' and discount_type in ('Senior Citizen', 'Senior Citizens'))::int
  into v_request_count, v_pending_count, v_rejected_count, v_approved_student, v_approved_pwd, v_approved_senior
  from public.booking_discount_requests
  where booking_id = p_booking_id;

  v_approved_student := least(v_student_count, v_account_student + coalesce(v_approved_student, 0));
  v_approved_pwd := least(v_pwd_count, v_account_pwd + coalesce(v_approved_pwd, 0));
  v_approved_senior := least(v_senior_count, v_account_senior + coalesce(v_approved_senior, 0));

  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - v_fare_config.included_km);
  v_charged_additional_km := ceil(v_additional_km)::int;
  v_per_passenger_subtotal := v_fare_config.base_fare + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := coalesce(v_booking.regular_fare, v_per_passenger_subtotal * v_total_count);

  v_final_fare := (v_per_passenger_subtotal * v_total_count)
    - (v_per_passenger_subtotal * (v_fare_config.student_discount / 100) * v_approved_student)
    - (v_per_passenger_subtotal * (v_fare_config.pwd_discount / 100) * v_approved_pwd)
    - (v_per_passenger_subtotal * (v_fare_config.senior_citizen_discount / 100) * v_approved_senior);
  v_final_fare := greatest(0, round(v_final_fare, 2));

  if v_request_count = 0 then
    v_status := 'NOT_REQUIRED';
  elsif v_pending_count > 0 and (v_rejected_count > 0 or (v_approved_student + v_approved_pwd + v_approved_senior) > 0) then
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

  update public.bookings
  set regular_fare = coalesce(regular_fare, v_regular_fare),
      provisional_discounted_fare = coalesce(provisional_discounted_fare, estimated_fare),
      final_fare = v_final_fare,
      estimated_fare = v_final_fare,
      actual_fare = case when status in ('droppedOff', 'paymentSent', 'completed') then v_final_fare else actual_fare end,
      discount_review_status = v_status,
      discount_reviewed_at = now(),
      discount_verified = (v_status = 'APPROVED'),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare,
    'regular_fare', v_regular_fare
  );
end;
$$;

-- ── 4. Driver Direct Rejection & Fare Reversion RPC ─────────────────────────
create or replace function public.reject_booking_discount_and_revert_fare(
  p_booking_id uuid,
  p_reason text default 'ID not verified'
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

  -- Mark all companion requests as rejected
  update public.booking_discount_requests
  set status = 'REJECTED',
      rejection_reason = p_reason,
      reviewed_by_driver_id = v_driver_id,
      reviewed_at = now(),
      updated_at = now()
  where booking_id = p_booking_id
    and status = 'PENDING';

  -- Revert booking fare to full regular fare
  update public.bookings
  set discount_verified = false,
      discount_rejected_reason = p_reason,
      passenger_type_display = 'Regular',
      discount_review_status = 'REJECTED',
      final_fare = v_regular_fare,
      estimated_fare = v_regular_fare,
      actual_fare = case when status in ('droppedOff', 'paymentSent', 'completed') then v_regular_fare else actual_fare end,
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'final_fare', v_regular_fare,
    'discount_review_status', 'REJECTED'
  );
end;
$$;
