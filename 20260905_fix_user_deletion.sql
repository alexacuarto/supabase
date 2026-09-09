-- ============================================================================
-- TodaGo Revision: Fix Driver and Passenger Deletion (Atomic Stored Procedures & RLS)
-- Date: September 05, 2026
-- 
-- Description:
--   Enables clean, atomic deletion of drivers and passengers by administrators,
--   cascading through all relational dependencies and adding DELETE RLS policies.
--   Run this script in your Supabase Dashboard -> SQL Editor.
-- ============================================================================

-- 1. Grant DELETE permissions to authenticated and service_role
GRANT DELETE ON public.drivers TO authenticated, service_role;
GRANT DELETE ON public.passengers TO authenticated, service_role;
GRANT DELETE ON public.profiles TO authenticated, service_role;

-- 2. Add RLS DELETE policies for administrators
DROP POLICY IF EXISTS drivers_delete_admin ON public.drivers;
CREATE POLICY drivers_delete_admin ON public.drivers
  FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS passengers_delete_admin ON public.passengers;
CREATE POLICY passengers_delete_admin ON public.passengers
  FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS profiles_delete_admin ON public.profiles;
CREATE POLICY profiles_delete_admin ON public.profiles
  FOR DELETE USING (public.is_admin());

-- 3. Stored Procedure: Atomic Driver Deletion
CREATE OR REPLACE FUNCTION public.admin_delete_driver(p_driver_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  -- Validate administrator authorization
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can delete drivers.';
  END IF;

  SELECT profile_id INTO v_profile_id
  FROM public.drivers
  WHERE id = p_driver_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Driver not found.');
  END IF;

  -- Step A: Detach driver from active or completed bookings without deleting booking records
  UPDATE public.bookings 
  SET driver_id = NULL 
  WHERE driver_id = p_driver_id;

  -- Step B: Detach driver from discount reviews if referenced
  UPDATE public.booking_discount_requests 
  SET reviewed_by_driver_id = NULL 
  WHERE reviewed_by_driver_id = p_driver_id;

  -- Step C: Clean up driver child logs and records
  DELETE FROM public.driver_locations WHERE driver_id = p_driver_id;
  DELETE FROM public.driver_sessions WHERE driver_id = p_driver_id;
  DELETE FROM public.vehicles WHERE driver_id = p_driver_id;
  DELETE FROM public.ratings WHERE driver_id = p_driver_id;
  DELETE FROM public.reports WHERE driver_id = p_driver_id;
  DELETE FROM public.driver_profile_change_requests WHERE driver_id = p_driver_id;

  -- Step D: Delete driver record
  DELETE FROM public.drivers WHERE id = p_driver_id;

  -- Step E: Clean up associated profile and its notifications if exists
  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.notifications WHERE recipient_id = v_profile_id;
    DELETE FROM public.reports WHERE reporter_id = v_profile_id OR reporter_profile_id = v_profile_id;
    DELETE FROM public.profiles WHERE id = v_profile_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

-- 4. Stored Procedure: Atomic Passenger Deletion
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
  -- Validate administrator authorization
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can delete passengers.';
  END IF;

  SELECT profile_id INTO v_profile_id
  FROM public.passengers
  WHERE id = p_passenger_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Passenger not found.');
  END IF;

  -- Collect all booking IDs belonging to this passenger
  SELECT array_agg(id) INTO v_booking_ids
  FROM public.bookings
  WHERE passenger_id = p_passenger_id;

  -- Step A: Clean up all child dependencies tied to this passenger's bookings
  IF v_booking_ids IS NOT NULL AND array_length(v_booking_ids, 1) > 0 THEN
    DELETE FROM public.booking_discount_requests WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.booking_status_history WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.driver_locations WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.passenger_locations WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.ratings WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.notifications WHERE booking_id = ANY(v_booking_ids);
    DELETE FROM public.reports WHERE booking_id = ANY(v_booking_ids);
  END IF;

  -- Step B: Clean up passenger-specific records and bookings
  DELETE FROM public.passenger_locations WHERE passenger_id = p_passenger_id;
  DELETE FROM public.reports WHERE passenger_id = p_passenger_id OR reporter_passenger_id = p_passenger_id;
  DELETE FROM public.bookings WHERE passenger_id = p_passenger_id;

  -- Step C: Delete passenger record
  DELETE FROM public.passengers WHERE id = p_passenger_id;

  -- Step D: Clean up associated profile and notifications if exists
  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.notifications WHERE recipient_id = v_profile_id;
    DELETE FROM public.reports WHERE reporter_id = v_profile_id OR reporter_profile_id = v_profile_id;
    DELETE FROM public.profiles WHERE id = v_profile_id;
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

-- 5. Grant execution permissions on deletion procedures
GRANT EXECUTE ON FUNCTION public.admin_delete_driver(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_passenger(uuid) TO authenticated, anon;
