-- Migration: Dynamic Added Kilometer (Succeeding KM Interval) Fare Pricing
-- Date: 2026-09-20
-- Description: Adds dynamic succeeding_km_interval to fare_configurations, updates change logs,
--              enhances update_fare_configuration_with_message RPC, and updates
--              recalculate_booking_discount_summary to support dynamic added KM steps.

-- 1. Add succeeding_km_interval to fare_configurations
ALTER TABLE public.fare_configurations
ADD COLUMN IF NOT EXISTS succeeding_km_interval numeric NOT NULL DEFAULT 1.0
CHECK (succeeding_km_interval > 0);

-- 2. Add audit columns to fare_change_logs
ALTER TABLE public.fare_change_logs
ADD COLUMN IF NOT EXISTS old_succeeding_km_interval numeric,
ADD COLUMN IF NOT EXISTS new_succeeding_km_interval numeric;

-- 3. Update update_fare_configuration_with_message RPC
CREATE OR REPLACE FUNCTION public.update_fare_configuration_with_message(
  p_trip_type text,
  p_display_label text,
  p_base_fare numeric,
  p_included_km numeric,
  p_succeeding_km_fare numeric,
  p_student_discount numeric,
  p_pwd_discount numeric,
  p_senior_citizen_discount numeric,
  p_message text,
  p_succeeding_km_interval numeric DEFAULT 1.0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing public.fare_configurations%rowtype;
  v_log_id uuid;
  v_change_lines text[] := array[]::text[];
  v_notification_body text;
  v_interval numeric;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can change fare settings.';
  END IF;

  IF nullif(trim(coalesce(p_message, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A fare change message is required.';
  END IF;

  v_interval := coalesce(nullif(p_succeeding_km_interval, 0), 1.0);
  IF v_interval <= 0 THEN
    RAISE EXCEPTION 'Added KM interval must be greater than zero.';
  END IF;

  SELECT * INTO v_existing
  FROM public.fare_configurations
  WHERE trip_type = p_trip_type
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fare configuration for trip type % was not found.', p_trip_type;
  END IF;

  IF v_existing.display_label IS DISTINCT FROM p_display_label THEN
    v_change_lines := array_append(v_change_lines, format('Label: %s -> %s', v_existing.display_label, p_display_label));
  END IF;
  IF v_existing.base_fare IS DISTINCT FROM p_base_fare THEN
    v_change_lines := array_append(v_change_lines, format('Base fare: PHP %s -> PHP %s', to_char(v_existing.base_fare, 'FM999999990.00'), to_char(p_base_fare, 'FM999999990.00')));
  END IF;
  IF v_existing.included_km IS DISTINCT FROM p_included_km THEN
    v_change_lines := array_append(v_change_lines, format('Included KM: %s km -> %s km', to_char(v_existing.included_km, 'FM999999990.00'), to_char(p_included_km, 'FM999999990.00')));
  END IF;
  IF v_existing.succeeding_km_interval IS DISTINCT FROM v_interval THEN
    v_change_lines := array_append(v_change_lines, format('Added KM Interval: %s km -> %s km', to_char(v_existing.succeeding_km_interval, 'FM999999990.00'), to_char(v_interval, 'FM999999990.00')));
  END IF;
  IF v_existing.succeeding_km_fare IS DISTINCT FROM p_succeeding_km_fare THEN
    v_change_lines := array_append(v_change_lines, format('Succeeding KM fare: PHP %s -> PHP %s', to_char(v_existing.succeeding_km_fare, 'FM999999990.00'), to_char(p_succeeding_km_fare, 'FM999999990.00')));
  END IF;
  IF v_existing.student_discount IS DISTINCT FROM p_student_discount THEN
    v_change_lines := array_append(v_change_lines, format('Student discount: %s%% -> %s%%', to_char(v_existing.student_discount, 'FM999999990.00'), to_char(p_student_discount, 'FM999999990.00')));
  END IF;
  IF v_existing.pwd_discount IS DISTINCT FROM p_pwd_discount THEN
    v_change_lines := array_append(v_change_lines, format('PWD discount: %s%% -> %s%%', to_char(v_existing.pwd_discount, 'FM999999990.00'), to_char(p_pwd_discount, 'FM999999990.00')));
  END IF;
  IF v_existing.senior_citizen_discount IS DISTINCT FROM p_senior_citizen_discount THEN
    v_change_lines := array_append(v_change_lines, format('Senior Citizen discount: %s%% -> %s%%', to_char(v_existing.senior_citizen_discount, 'FM999999990.00'), to_char(p_senior_citizen_discount, 'FM999999990.00')));
  END IF;

  v_notification_body := trim(p_message) || E'\n\nChanges made:\n' ||
    CASE
      WHEN array_length(v_change_lines, 1) IS NULL THEN 'No fare values changed.'
      ELSE array_to_string(v_change_lines, E'\n')
    END;

  UPDATE public.fare_configurations
  SET display_label = p_display_label,
      base_fare = p_base_fare,
      included_km = p_included_km,
      succeeding_km_interval = v_interval,
      succeeding_km_fare = p_succeeding_km_fare,
      student_discount = p_student_discount,
      pwd_discount = p_pwd_discount,
      senior_citizen_discount = p_senior_citizen_discount,
      updated_at = now()
  WHERE id = v_existing.id;

  INSERT INTO public.fare_change_logs (
    fare_configuration_id,
    trip_type,
    old_base_fare,
    new_base_fare,
    old_included_km,
    new_included_km,
    old_succeeding_km_interval,
    new_succeeding_km_interval,
    old_succeeding_km_fare,
    new_succeeding_km_fare,
    message,
    changed_by
  )
  VALUES (
    v_existing.id,
    p_trip_type,
    v_existing.base_fare,
    p_base_fare,
    v_existing.included_km,
    p_included_km,
    v_existing.succeeding_km_interval,
    v_interval,
    v_existing.succeeding_km_fare,
    p_succeeding_km_fare,
    trim(p_message),
    auth.uid()
  )
  RETURNING id INTO v_log_id;

  INSERT INTO public.notifications (recipient_id, type, title, body, data, notification_category)
  SELECT
    p.id,
    'in_app',
    'Fare Update',
    v_notification_body,
    jsonb_build_object(
      'fare_change_log_id', v_log_id,
      'trip_type', p_trip_type,
      'changes', coalesce(to_jsonb(v_change_lines), '[]'::jsonb)
    ),
    'fare_adjustment'
  FROM public.profiles p
  WHERE p.role IN ('passenger', 'driver');

  RETURN jsonb_build_object(
    'success', true,
    'log_id', v_log_id,
    'changes', v_change_lines,
    'notification_body', v_notification_body
  );
END;
$$;

-- 4. Update recalculate_booking_discount_summary to dynamically divide by succeeding_km_interval
CREATE OR REPLACE FUNCTION public.recalculate_booking_discount_summary(p_booking_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking public.bookings%rowtype;
  v_passenger public.passengers%rowtype;
  v_fare_config public.fare_configurations%rowtype;
  v_regular_count int := 0;
  v_student_count int := 0;
  v_pwd_count int := 0;
  v_senior_count int := 0;
  v_total_count int := 1;
  v_stops_count int := 1;
  v_interval numeric := 1.0;
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
BEGIN
  SELECT *
  INTO v_booking
  FROM public.bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF v_booking IS NULL THEN
    RAISE EXCEPTION 'Booking not found.';
  END IF;

  SELECT p.*
  INTO v_passenger
  FROM public.passengers p
  WHERE p.id = v_booking.passenger_id;

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
      CASE
        WHEN v_booking.stops IS NOT NULL AND jsonb_typeof(to_jsonb(v_booking.stops)) = 'array'
        THEN jsonb_array_length(to_jsonb(v_booking.stops))
        ELSE 1
      END
    )
  );

  -- Select proper fare configuration based on trip_type (Special Trip maps to round_trip)
  SELECT *
  INTO v_fare_config
  FROM public.fare_configurations
  WHERE trip_type = CASE
    WHEN lower(coalesce(v_booking.trip_type, 'one_way')) LIKE '%round%'
      OR lower(coalesce(v_booking.trip_type, 'one_way')) LIKE '%special%' THEN 'round_trip'
    ELSE 'one_way'
  END
    AND is_active = true
  LIMIT 1;

  IF v_fare_config IS NULL THEN
    SELECT *
    INTO v_fare_config
    FROM public.fare_configurations
    WHERE is_active = true
    ORDER BY (CASE WHEN trip_type = 'one_way' THEN 1 ELSE 2 END)
    LIMIT 1;
  END IF;

  IF v_fare_config IS NULL THEN
    v_final_fare := coalesce(v_booking.final_fare, v_booking.estimated_fare, 0);
    UPDATE public.bookings
    SET final_fare = v_final_fare,
        discount_reviewed_at = now(),
        updated_at = now()
    WHERE id = p_booking_id;
    RETURN json_build_object('success', true, 'final_fare', v_final_fare);
  END IF;

  -- Safe interval fallback (default to 1.0 km if null or <= 0)
  v_interval := coalesce(nullif(v_fare_config.succeeding_km_interval, 0), 1.0);
  IF v_interval <= 0 THEN
    v_interval := 1.0;
  END IF;

  -- Count discount requests:
  -- Eligible discounts include APPROVED and PENDING (provisional). REJECTED discounts are NOT eligible.
  SELECT
    count(*)::int,
    count(*) filter (WHERE status = 'PENDING')::int,
    count(*) filter (WHERE status = 'REJECTED')::int,
    count(*) filter (WHERE status = 'APPROVED')::int,
    count(*) filter (WHERE status IN ('APPROVED', 'PENDING') AND lower(discount_type) LIKE '%student%')::int,
    count(*) filter (WHERE status IN ('APPROVED', 'PENDING') AND lower(discount_type) LIKE '%pwd%')::int,
    count(*) filter (WHERE status IN ('APPROVED', 'PENDING') AND (lower(discount_type) LIKE '%senior%' OR lower(discount_type) LIKE '%citizen%'))::int
  INTO v_request_count, v_pending_count, v_rejected_count, v_approved_count, v_eligible_student, v_eligible_pwd, v_eligible_senior
  FROM public.booking_discount_requests
  WHERE booking_id = p_booking_id;

  v_eligible_student := least(v_student_count, coalesce(v_eligible_student, 0));
  v_eligible_pwd := least(v_pwd_count, coalesce(v_eligible_pwd, 0));
  v_eligible_senior := least(v_senior_count, coalesce(v_eligible_senior, 0));

  -- Distance & fare calculation incorporating stops and dynamic succeeding_km_interval
  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - (v_fare_config.included_km * v_stops_count));
  v_charged_additional_km := ceil(v_additional_km / v_interval)::int;
  v_base_per_passenger := v_fare_config.base_fare * v_stops_count;
  v_per_passenger_subtotal := v_base_per_passenger + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := v_per_passenger_subtotal * v_total_count;

  -- Dynamic final fare: subtract only currently eligible discounts
  v_final_fare := v_regular_fare
    - (v_per_passenger_subtotal * (v_fare_config.student_discount / 100) * v_eligible_student)
    - (v_per_passenger_subtotal * (v_fare_config.pwd_discount / 100) * v_eligible_pwd)
    - (v_per_passenger_subtotal * (v_fare_config.senior_citizen_discount / 100) * v_eligible_senior);
  v_final_fare := greatest(0, round(v_final_fare, 2));

  IF v_request_count = 0 THEN
    v_status := 'NOT_REQUIRED';
  ELSIF v_pending_count > 0 AND (v_rejected_count > 0 OR v_approved_count > 0) THEN
    v_status := 'PARTIALLY_APPROVED';
  ELSIF v_pending_count > 0 THEN
    v_status := 'PENDING_DRIVER_REVIEW';
  ELSIF v_rejected_count = v_request_count THEN
    v_status := 'REJECTED';
  ELSIF v_rejected_count > 0 THEN
    v_status := 'PARTIALLY_APPROVED';
  ELSE
    v_status := 'APPROVED';
  END IF;

  UPDATE public.bookings
  SET regular_fare = coalesce(regular_fare, v_regular_fare),
      provisional_discounted_fare = coalesce(provisional_discounted_fare, estimated_fare),
      final_fare = v_final_fare,
      actual_fare = CASE WHEN status IN ('droppedOff', 'paymentSent', 'completed') THEN v_final_fare ELSE actual_fare END,
      discount_review_status = v_status,
      discount_reviewed_at = now(),
      updated_at = now()
  WHERE id = p_booking_id;

  RETURN json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare,
    'regular_fare', v_regular_fare
  );
END;
$$;
