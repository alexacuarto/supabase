-- ============================================================================
-- TODA GO: Hard Delete User from Supabase Auth & Public Tables
-- Directory: messy-supabase/20260919_delete_auth_user.sql
-- 
-- DESCRIPTION:
--   Completely deletes a user from Supabase Authentication (`auth.users`),
--   identities (`auth.identities`), profiles, bookings, driver records, and
--   all associated relational data without violating `ON DELETE RESTRICT`.
--
-- USAGE IN SUPABASE SQL EDITOR:
--   Option A: Run Part 1 to create the reusable function, then call:
--             SELECT public.delete_user_by_email('user@example.com');
--             OR
--             SELECT public.delete_user_by_id('uuid-here');
--
--   Option B: Edit the email in Part 2 and run the DO block directly.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PART 1: REUSABLE STORED FUNCTIONS (Run once in Supabase SQL Editor)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.delete_user_by_id(p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_passenger_id uuid;
  v_driver_id uuid;
  v_booking_ids uuid[];
  v_email text;
BEGIN
  -- 1. Check if user exists in auth.users
  SELECT email INTO v_email
  FROM auth.users
  WHERE id = p_user_id;

  IF v_email IS NULL THEN
    -- Check if user exists in public.profiles even if already removed from auth
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
      RETURN json_build_object('success', false, 'message', 'User not found in auth.users or public.profiles.');
    END IF;
  END IF;

  -- 2. Find passenger or driver IDs
  SELECT id INTO v_passenger_id FROM public.passengers WHERE profile_id = p_user_id;
  SELECT id INTO v_driver_id FROM public.drivers WHERE profile_id = p_user_id;

  -- 3. If user is a PASSENGER: Clean up bookings & child records (bypasses ON DELETE RESTRICT)
  IF v_passenger_id IS NOT NULL THEN
    SELECT array_agg(id) INTO v_booking_ids
    FROM public.bookings
    WHERE passenger_id = v_passenger_id;

    IF v_booking_ids IS NOT NULL AND array_length(v_booking_ids, 1) > 0 THEN
      DELETE FROM public.booking_discount_requests WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.booking_status_history WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.driver_locations WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.passenger_locations WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.ratings WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.notifications WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.reports WHERE booking_id = ANY(v_booking_ids);
      DELETE FROM public.bookings WHERE id = ANY(v_booking_ids);
    END IF;

    DELETE FROM public.passenger_locations WHERE passenger_id = v_passenger_id;
    DELETE FROM public.saved_places WHERE passenger_id = v_passenger_id;
    DELETE FROM public.reports WHERE passenger_id = v_passenger_id OR reporter_passenger_id = v_passenger_id;
    DELETE FROM public.passengers WHERE id = v_passenger_id;
  END IF;

  -- 4. If user is a DRIVER: Detach bookings and clean up logs/vehicle
  IF v_driver_id IS NOT NULL THEN
    UPDATE public.bookings SET driver_id = NULL WHERE driver_id = v_driver_id;
    UPDATE public.booking_discount_requests SET reviewed_by_driver_id = NULL WHERE reviewed_by_driver_id = v_driver_id;
    DELETE FROM public.driver_locations WHERE driver_id = v_driver_id;
    DELETE FROM public.driver_sessions WHERE driver_id = v_driver_id;
    DELETE FROM public.vehicles WHERE driver_id = v_driver_id;
    DELETE FROM public.ratings WHERE driver_id = v_driver_id;
    DELETE FROM public.reports WHERE driver_id = v_driver_id;
    DELETE FROM public.driver_profile_change_requests WHERE driver_id = v_driver_id;
    DELETE FROM public.drivers WHERE id = v_driver_id;
  END IF;

  -- 5. Clean up profile and direct dependencies
  DELETE FROM public.notifications WHERE recipient_id = p_user_id;
  DELETE FROM public.push_tokens WHERE profile_id = p_user_id;
  DELETE FROM public.reports 
  WHERE reporter_id = p_user_id 
     OR reporter_profile_id = p_user_id 
     OR reviewed_by = p_user_id 
     OR generated_by = p_user_id;
  
  DELETE FROM public.profiles WHERE id = p_user_id;

  -- 6. Delete from Supabase Auth tables
  DELETE FROM auth.identities WHERE user_id = p_user_id;
  DELETE FROM auth.users WHERE id = p_user_id;

  RETURN json_build_object(
    'success', true, 
    'message', 'User completely deleted from auth and public tables.',
    'user_id', p_user_id,
    'email', v_email
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_user_by_email(p_email text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  SELECT id INTO v_user_id 
  FROM auth.users 
  WHERE lower(email) = lower(trim(p_email));

  IF v_user_id IS NULL THEN
    -- Check profiles table if auth row was already lost
    SELECT id INTO v_user_id
    FROM public.profiles
    WHERE lower(email) = lower(trim(p_email));
  END IF;

  IF v_user_id IS NULL THEN
    RETURN json_build_object('success', false, 'message', 'User email not found in auth.users or public.profiles.');
  END IF;

  RETURN public.delete_user_by_id(v_user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_user_by_id(uuid) TO authenticated, service_role, postgres;
GRANT EXECUTE ON FUNCTION public.delete_user_by_email(text) TO authenticated, service_role, postgres;


-- ----------------------------------------------------------------------------
-- PART 2: ONE-OFF SCRIPT (Edit email below and run if you only want to delete one user right now)
-- ----------------------------------------------------------------------------
-- SELECT public.delete_user_by_email('your_target_user_email@gmail.com');
