-- Passenger signup IDs are for account verification only.
-- Booking discounts must come only from booking_discount_requests reviewed by the assigned driver.

update public.passengers
set account_passenger_type = 'Regular',
    discount_document_type = case
      when discount_document_url is not null then 'Account Verification ID'
      else discount_document_type
    end,
    discount_eligible = false,
    updated_at = now();

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
  v_title text;
  v_body text;
begin
  if not public.is_admin() then
    raise exception 'Only admins can review passenger verification IDs.';
  end if;

  if p_status not in ('VERIFIED', 'REJECTED') then
    raise exception 'Verification review status must be VERIFIED or REJECTED.';
  end if;

  select *
  into v_passenger
  from public.passengers
  where id = p_passenger_id
  for update;

  if not found then
    raise exception 'Passenger was not found.';
  end if;

  update public.passengers
  set discount_document_status = p_status,
      discount_document_rejection_reason = case when p_status = 'REJECTED' then nullif(trim(coalesce(p_reason, '')), '') else null end,
      discount_document_reviewed_at = now(),
      discount_document_reviewed_by = auth.uid(),
      discount_eligible = false,
      updated_at = now()
  where id = p_passenger_id;

  update public.profiles
  set is_active = p_status = 'VERIFIED',
      updated_at = now()
  where id = v_passenger.profile_id;

  v_title := case when p_status = 'VERIFIED' then 'ID Verification Approved' else 'ID Verification Rejected' end;
  v_body := case
    when p_status = 'VERIFIED' then 'Your ID has been approved. You can now access TODA Go.'
    else coalesce(nullif(trim(p_reason), ''), 'Your ID was not approved. Please upload a clear valid ID.')
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

create or replace function public.recalculate_booking_discount_summary(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
  v_passenger record;
  v_fare_config record;
  v_regular_count int;
  v_student_count int;
  v_pwd_count int;
  v_senior_count int;
  v_total_count int;
  v_approved_student int := 0;
  v_approved_pwd int := 0;
  v_approved_senior int := 0;
  v_pending_count int := 0;
  v_rejected_count int := 0;
  v_request_count int := 0;
  v_base_per_passenger numeric;
  v_regular_fare numeric;
  v_final_fare numeric;
  v_additional_km numeric;
  v_charged_additional_km int;
  v_per_passenger_subtotal numeric;
  v_status text;
begin
  select * into v_booking
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

  select *
  into v_fare_config
  from public.fare_configurations
  where trip_type = case
    when lower(coalesce(v_booking.trip_type, 'one_way')) like '%round%' then 'round_trip'
    else 'one_way'
  end
    and is_active = true
  limit 1;

  if v_fare_config is null then
    v_final_fare := coalesce(v_booking.final_fare, v_booking.estimated_fare, 0);
    update public.bookings
    set final_fare = v_final_fare,
        discount_reviewed_at = now(),
        updated_at = now()
    where id = p_booking_id;
    return json_build_object('success', true, 'final_fare', v_final_fare);
  end if;

  select
    count(*)::int,
    count(*) filter (where status = 'PENDING')::int,
    count(*) filter (where status = 'REJECTED')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'Student')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'PWD')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'Senior Citizen')::int
  into v_request_count, v_pending_count, v_rejected_count, v_approved_student, v_approved_pwd, v_approved_senior
  from public.booking_discount_requests
  where booking_id = p_booking_id;

  v_approved_student := least(v_student_count, coalesce(v_approved_student, 0));
  v_approved_pwd := least(v_pwd_count, coalesce(v_approved_pwd, 0));
  v_approved_senior := least(v_senior_count, coalesce(v_approved_senior, 0));

  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - v_fare_config.included_km);
  v_charged_additional_km := ceil(v_additional_km)::int;
  v_base_per_passenger := v_fare_config.base_fare;
  v_per_passenger_subtotal := v_base_per_passenger + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := v_per_passenger_subtotal * v_total_count;

  v_final_fare := v_regular_fare
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
      actual_fare = case when status in ('droppedOff', 'paymentSent', 'completed') then v_final_fare else actual_fare end,
      discount_review_status = v_status,
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare
  );
end;
$$;
