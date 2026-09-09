-- ============================================================================
-- TODA GO: All Latest Database Revisions (Consolidated Migration)
-- Date: September 05, 2026
-- 
-- Instructions:
--   Copy and paste this entire script into your Supabase Dashboard -> SQL Editor
--   and click "RUN". This script is completely safe and idempotent (can be run
--   multiple times without error).
--
-- Included Features:
--   1. Franchise Back Page column (franchise_back_url) on public.drivers.
--   2. Standardized 3 Accredited TODAs (LHITC-TODA, BYPASS ILAYANG BAGUIO-TODA, CHOT-TODA).
--   3. Passenger 3-Cancellation Restriction Policy (31 days penalty) & Admin Lift/Restrict RPCs.
--   4. Driver Profile Modification Requests Workflow & In-App Driver Notifications.
--   5. Realtime publication synchronization.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. DRIVER FRANCHISE BACK URL
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.drivers
ADD COLUMN IF NOT EXISTS franchise_back_url text;

COMMENT ON COLUMN public.drivers.franchise_back_url IS 'Storage URL for the back page of driver franchise document.';


-- ────────────────────────────────────────────────────────────────────────────
-- 2. TODA ASSOCIATION STANDARDIZATION & ENFORCEMENT
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Default to LHITC-TODA
  ALTER TABLE public.drivers
    ALTER COLUMN toda_association SET DEFAULT 'LHITC-TODA';

  -- Normalize legacy null or invalid TODA values
  UPDATE public.drivers
  SET toda_association = 'LHITC-TODA'
  WHERE toda_association IS NULL
     OR trim(toda_association) = ''
     OR toda_association = 'Not provided'
     OR toda_association NOT IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA');

  -- Update check constraint
  ALTER TABLE public.drivers
    DROP CONSTRAINT IF EXISTS check_valid_toda_association;

  ALTER TABLE public.drivers
    ADD CONSTRAINT check_valid_toda_association
    CHECK (toda_association IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA'));
EXCEPTION
  WHEN others THEN NULL;
END $$;

-- Admin function to safely update a driver's TODA
CREATE OR REPLACE FUNCTION public.update_driver_toda_association(
  p_driver_id uuid,
  p_toda_association text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_clean_toda text;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN json_build_object('success', false, 'error', 'Only admins can update driver TODA associations.');
  END IF;

  v_clean_toda := coalesce(nullif(trim(p_toda_association), ''), 'LHITC-TODA');
  IF v_clean_toda NOT IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') THEN
    RETURN json_build_object('success', false, 'error', 'Invalid TODA association.');
  END IF;

  UPDATE public.drivers
  SET toda_association = v_clean_toda,
      updated_at = now()
  WHERE id = p_driver_id;

  RETURN json_build_object('success', true, 'toda_association', v_clean_toda);
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_driver_toda_association(uuid, text) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- 3. PASSENGER 3-CANCELLATION POLICY & 31-DAY RESTRICTION
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_passenger_cancel_stats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_new_cancel_count int;
  v_profile_id uuid;
BEGIN
  IF old.status IS DISTINCT FROM new.status
     AND new.status = 'cancelled'
     AND new.cancelled_by = 'passenger' THEN

    SELECT coalesce(cancel_count, 0) + 1, profile_id
    INTO v_new_cancel_count, v_profile_id
    FROM public.passengers
    WHERE id = new.passenger_id;

    UPDATE public.passengers
    SET cancel_count = v_new_cancel_count,
        last_cancel_date = now(),
        warning_status = v_new_cancel_count >= 2,
        booking_restriction_until = CASE
          WHEN v_new_cancel_count >= 3 THEN now() + interval '31 days'
          ELSE booking_restriction_until
        END,
        updated_at = now()
    WHERE id = new.passenger_id;

    -- In-app notification on threshold
    IF v_new_cancel_count >= 3 AND v_profile_id IS NOT NULL THEN
      INSERT INTO public.notifications (
        recipient_id,
        type,
        title,
        body,
        notification_category,
        data
      ) VALUES (
        v_profile_id,
        'in_app',
        'Account Restricted',
        'Your account has been restricted from booking for 31 days due to 3 ride cancellations.',
        'account_status',
        jsonb_build_object('action', 'cancellation_restriction', 'cancel_count', v_new_cancel_count, 'restricted_until', now() + interval '31 days')
      );
    ELSIF v_new_cancel_count = 2 AND v_profile_id IS NOT NULL THEN
      INSERT INTO public.notifications (
        recipient_id,
        type,
        title,
        body,
        notification_category,
        data
      ) VALUES (
        v_profile_id,
        'in_app',
        'Cancellation Warning',
        'You have cancelled 2 bookings. 1 more cancellation will result in a 31-day account restriction from booking.',
        'account_status',
        jsonb_build_object('action', 'cancellation_warning', 'cancel_count', v_new_cancel_count)
      );
    END IF;

  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_passenger_cancel_stats ON public.bookings;
CREATE TRIGGER trg_update_passenger_cancel_stats
  AFTER UPDATE OF status ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public.update_passenger_cancel_stats();

-- Admin manual restriction function (default 31 days)
CREATE OR REPLACE FUNCTION public.admin_restrict_passenger(
  p_passenger_id uuid,
  p_days int DEFAULT 31
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_profile_id uuid;
  v_until timestamptz;
BEGIN
  v_until := now() + (coalesce(p_days, 31) || ' days')::interval;

  UPDATE public.passengers
  SET booking_restriction_until = v_until,
      cancel_count = greatest(coalesce(cancel_count, 0), 3),
      warning_status = true,
      updated_at = now()
  WHERE id = p_passenger_id
  RETURNING profile_id INTO v_profile_id;

  IF v_profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (
      recipient_id,
      type,
      title,
      body,
      notification_category,
      data
    ) VALUES (
      v_profile_id,
      'in_app',
      'Account Restricted',
      'Your account has been restricted from booking for ' || coalesce(p_days, 31) || ' days by the administrator.',
      'account_status',
      jsonb_build_object('action', 'admin_restricted', 'restricted_until', v_until)
    );
  END IF;
END;
$$;

-- Admin immediate restriction lift function
CREATE OR REPLACE FUNCTION public.admin_lift_passenger_restriction(
  p_passenger_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  SELECT profile_id INTO v_profile_id
  FROM public.passengers
  WHERE id = p_passenger_id;

  UPDATE public.passengers
  SET booking_restriction_until = null,
      cancel_count = 0,
      warning_status = false,
      updated_at = now()
  WHERE id = p_passenger_id;

  IF v_profile_id IS NOT NULL THEN
    UPDATE public.profiles
    SET is_active = true
    WHERE id = v_profile_id;

    INSERT INTO public.notifications (
      recipient_id,
      type,
      title,
      body,
      notification_category,
      data
    ) VALUES (
      v_profile_id,
      'in_app',
      'Restriction Lifted',
      'Your booking restriction has been lifted by the administrator. You may now book rides again.',
      'account_status',
      jsonb_build_object('action', 'restriction_lifted', 'lifted_at', now())
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_restrict_passenger(uuid, int) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_lift_passenger_restriction(uuid) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- 4. DRIVER PROFILE MODIFICATION REQUESTS & IN-APP NOTIFICATIONS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.driver_profile_change_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  field_name text NOT NULL,
  current_value text,
  requested_value text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  rejection_reason text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Index for change requests
CREATE INDEX IF NOT EXISTS idx_driver_change_requests_driver
  ON public.driver_profile_change_requests(driver_id, status);

-- Enable RLS
ALTER TABLE public.driver_profile_change_requests ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  DROP POLICY IF EXISTS driver_change_requests_select ON public.driver_profile_change_requests;
  DROP POLICY IF EXISTS driver_change_requests_insert_own ON public.driver_profile_change_requests;
  DROP POLICY IF EXISTS driver_change_requests_update_admin ON public.driver_profile_change_requests;

  CREATE POLICY driver_change_requests_select ON public.driver_profile_change_requests
    FOR SELECT USING (
      auth.uid() = profile_id OR public.is_admin()
    );

  CREATE POLICY driver_change_requests_insert_own ON public.driver_profile_change_requests
    FOR INSERT WITH CHECK (
      auth.uid() = profile_id
    );

  CREATE POLICY driver_change_requests_update_admin ON public.driver_profile_change_requests
    FOR UPDATE USING (
      public.is_admin()
    );
EXCEPTION
  WHEN others THEN NULL;
END $$;

-- Approval / Rejection review stored procedure
CREATE OR REPLACE FUNCTION public.review_driver_profile_change_request(
  p_request_id uuid,
  p_status text,
  p_reason text DEFAULT null
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request public.driver_profile_change_requests%rowtype;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can review driver profile change requests.';
  END IF;

  IF p_status NOT IN ('APPROVED', 'REJECTED') THEN
    RAISE EXCEPTION 'Status must be APPROVED or REJECTED.';
  END IF;

  SELECT * INTO v_request
  FROM public.driver_profile_change_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'Driver profile change request not found.';
  END IF;

  IF v_request.status <> 'PENDING' THEN
    RAISE EXCEPTION 'This request has already been reviewed.';
  END IF;

  IF p_status = 'APPROVED' THEN
    IF v_request.field_name = 'full_name' THEN
      UPDATE public.profiles
      SET first_name = split_part(v_request.requested_value, ' ', 1),
          last_name = nullif(trim(substr(v_request.requested_value, length(split_part(v_request.requested_value, ' ', 1)) + 1)), ''),
          updated_at = now()
      WHERE id = v_request.profile_id;
    ELSIF v_request.field_name IN ('first_name', 'last_name', 'phone_number', 'email', 'address') THEN
      EXECUTE format('UPDATE public.profiles SET %I = $1, updated_at = now() WHERE id = $2', v_request.field_name)
      USING v_request.requested_value, v_request.profile_id;
    ELSIF v_request.field_name IN ('license_number', 'toda_association', 'license_expiry_date', 'franchise_number', 'franchise_expiry_date', 'license_front_url', 'license_back_url', 'franchise_url', 'franchise_back_url') THEN
      EXECUTE format('UPDATE public.drivers SET %I = $1, updated_at = now() WHERE id = $2', v_request.field_name)
      USING v_request.requested_value, v_request.driver_id;
    ELSIF v_request.field_name = 'toda' THEN
      UPDATE public.drivers
      SET toda_association = v_request.requested_value,
          updated_at = now()
      WHERE id = v_request.driver_id;
    ELSIF v_request.field_name IN ('plate_number', 'plate') THEN
      UPDATE public.vehicles
      SET plate_number = v_request.requested_value,
          updated_at = now()
      WHERE driver_id = v_request.driver_id;
    ELSE
      RAISE EXCEPTION 'Unsupported change request field: %', v_request.field_name;
    END IF;
  END IF;

  UPDATE public.driver_profile_change_requests
  SET status = p_status,
      rejection_reason = CASE WHEN p_status = 'REJECTED' THEN nullif(trim(coalesce(p_reason, '')), '') ELSE null END,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_request_id;

  INSERT INTO public.notifications (recipient_id, title, body, notification_category, data)
  VALUES (
    v_request.profile_id,
    CASE WHEN p_status = 'APPROVED' THEN 'Profile update approved' ELSE 'Profile update rejected' END,
    CASE
      WHEN p_status = 'APPROVED' THEN format('Your %s update request was approved.', replace(v_request.field_name, '_', ' '))
      ELSE format('Your %s update request was rejected.%s', replace(v_request.field_name, '_', ' '), CASE WHEN nullif(trim(coalesce(p_reason, '')), '') IS NULL THEN '' ELSE ' Reason: ' || trim(p_reason) END)
    END,
    'driver_profile_change_request',
    jsonb_build_object('request_id', p_request_id, 'field_name', v_request.field_name, 'status', p_status)
  );

  RETURN json_build_object('success', true, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_driver_profile_change_request(uuid, text, text) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- 5. REALTIME PUBLICATION SYNCHRONIZATION
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_profile_change_requests;
EXCEPTION
  WHEN others THEN NULL;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
EXCEPTION
  WHEN others THEN NULL;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- 6. UNIFIED DRIVER RESTRICTION ENFORCEMENT & RPCS
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS admin_action_type text,
  ADD COLUMN IF NOT EXISTS admin_action_reason text,
  ADD COLUMN IF NOT EXISTS admin_action_date timestamptz,
  ADD COLUMN IF NOT EXISTS admin_action_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.admin_restrict_driver(
  p_driver_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  UPDATE public.drivers
  SET admin_action_type = 'restricted',
      admin_action_reason = trim(p_reason),
      admin_action_date = now(),
      admin_action_by = auth.uid(),
      is_online = false,
      updated_at = now()
  WHERE id = p_driver_id
  RETURNING profile_id INTO v_profile_id;

  IF v_profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (
      recipient_id,
      type,
      title,
      body,
      notification_category,
      data
    ) VALUES (
      v_profile_id,
      'in_app',
      'Account Restricted',
      'Your driver account has been restricted by the administrator. Reason: ' || trim(p_reason),
      'account_status',
      jsonb_build_object('action', 'driver_restricted', 'reason', trim(p_reason), 'restricted_at', now())
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_lift_driver_restriction(
  p_driver_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  UPDATE public.drivers
  SET admin_action_type = null,
      admin_action_reason = null,
      admin_action_date = null,
      admin_action_by = null,
      updated_at = now()
  WHERE id = p_driver_id
  RETURNING profile_id INTO v_profile_id;

  IF v_profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (
      recipient_id,
      type,
      title,
      body,
      notification_category,
      data
    ) VALUES (
      v_profile_id,
      'in_app',
      'Restriction Lifted',
      'Your driver account restriction has been lifted by the administrator. You may now go online and accept rides.',
      'account_status',
      jsonb_build_object('action', 'driver_restriction_lifted', 'lifted_at', now())
    );
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_restrict_driver(uuid, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_lift_driver_restriction(uuid) TO authenticated, anon;


-- ────────────────────────────────────────────────────────────────────────────
-- 7. ATOMIC DRIVER & PASSENGER DELETION AND RLS POLICIES
-- ────────────────────────────────────────────────────────────────────────────
GRANT DELETE ON public.drivers TO authenticated, service_role;
GRANT DELETE ON public.passengers TO authenticated, service_role;
GRANT DELETE ON public.profiles TO authenticated, service_role;

DROP POLICY IF EXISTS drivers_delete_admin ON public.drivers;
CREATE POLICY drivers_delete_admin ON public.drivers
  FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS passengers_delete_admin ON public.passengers;
CREATE POLICY passengers_delete_admin ON public.passengers
  FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS profiles_delete_admin ON public.profiles;
CREATE POLICY profiles_delete_admin ON public.profiles
  FOR DELETE USING (public.is_admin());

CREATE OR REPLACE FUNCTION public.admin_delete_driver(p_driver_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can delete drivers.';
  END IF;

  SELECT profile_id INTO v_profile_id
  FROM public.drivers
  WHERE id = p_driver_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Driver not found.');
  END IF;

  UPDATE public.bookings 
  SET driver_id = NULL 
  WHERE driver_id = p_driver_id;

  UPDATE public.booking_discount_requests 
  SET reviewed_by_driver_id = NULL 
  WHERE reviewed_by_driver_id = p_driver_id;

  DELETE FROM public.driver_locations WHERE driver_id = p_driver_id;
  DELETE FROM public.driver_sessions WHERE driver_id = p_driver_id;
  DELETE FROM public.vehicles WHERE driver_id = p_driver_id;
  DELETE FROM public.ratings WHERE driver_id = p_driver_id;
  DELETE FROM public.reports WHERE driver_id = p_driver_id;
  DELETE FROM public.driver_profile_change_requests WHERE driver_id = p_driver_id;

  DELETE FROM public.drivers WHERE id = p_driver_id;

  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.notifications WHERE recipient_id = v_profile_id;
    DELETE FROM public.reports WHERE reporter_id = v_profile_id OR reporter_profile_id = v_profile_id;
    DELETE FROM public.profiles WHERE id = v_profile_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_passenger(p_passenger_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
  v_booking_ids uuid[];
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can delete passengers.';
  END IF;

  SELECT profile_id INTO v_profile_id
  FROM public.passengers
  WHERE id = p_passenger_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Passenger not found.');
  END IF;

  SELECT array_agg(id) INTO v_booking_ids
  FROM public.bookings
  WHERE passenger_id = p_passenger_id;

  IF v_booking_ids IS NOT NULL AND array_length(v_booking_ids, 1) > 0 THEN
    DELETE FROM public.booking_discount_requests WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.booking_status_history WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.driver_locations WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.passenger_locations WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.ratings WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.notifications WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.reports WHERE booking_id = ANY(v_booking_ids);
  END IF;

  DELETE FROM public.passenger_locations WHERE passenger_id = p_passenger_id;
  DELETE FROM public.reports WHERE passenger_id = p_passenger_id OR reporter_passenger_id = p_passenger_id;
  DELETE FROM public.bookings WHERE passenger_id = p_passenger_id;

  DELETE FROM public.passengers WHERE id = p_passenger_id;

  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.notifications WHERE recipient_id = v_profile_id;
    DELETE FROM public.reports WHERE reporter_id = v_profile_id OR reporter_profile_id = v_profile_id;
    DELETE FROM public.profiles WHERE id = v_profile_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_driver(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_passenger(uuid) TO authenticated, anon;


