-- ============================================================================
-- Delete Specific User from Supabase Auth & Public Tables
-- Target User UUID: f11dc5c2-0483-428c-9bd0-bee8b4af8f07
-- Safe execution: Affects ONLY this user without breaking the rest of the database
-- ============================================================================

BEGIN;

-- 1. Remove auth identity & session records for this specific user
DELETE FROM auth.identities 
WHERE user_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM auth.sessions 
WHERE user_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

-- 2. Clean up any leftover profile, notification, or token records if any exist
DELETE FROM public.notifications 
WHERE recipient_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM public.push_tokens 
WHERE profile_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

-- 3. Detach or clean any driver/passenger records if any were still linked
DO $$
DECLARE
  v_uid uuid := 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';
  v_passenger_id uuid;
  v_driver_id uuid;
  v_booking_ids uuid[];
BEGIN
  SELECT id INTO v_passenger_id FROM public.passengers WHERE profile_id = v_uid;
  SELECT id INTO v_driver_id FROM public.drivers WHERE profile_id = v_uid;

  IF v_passenger_id IS NOT NULL THEN
    SELECT array_agg(id) INTO v_booking_ids FROM public.bookings WHERE passenger_id = v_passenger_id;
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
    DELETE FROM public.passengers WHERE id = v_passenger_id;
  END IF;

  IF v_driver_id IS NOT NULL THEN
    UPDATE public.bookings SET driver_id = NULL WHERE driver_id = v_driver_id;
    UPDATE public.booking_discount_requests SET reviewed_by_driver_id = NULL WHERE reviewed_by_driver_id = v_driver_id;
    DELETE FROM public.driver_locations WHERE driver_id = v_driver_id;
    DELETE FROM public.driver_sessions WHERE driver_id = v_driver_id;
    DELETE FROM public.vehicles WHERE driver_id = v_driver_id;
    DELETE FROM public.ratings WHERE driver_id = v_driver_id;
    DELETE FROM public.driver_profile_change_requests WHERE driver_id = v_driver_id;
    DELETE FROM public.drivers WHERE id = v_driver_id;
  END IF;
END $$;

DELETE FROM public.reports 
WHERE reporter_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07' 
   OR reporter_profile_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM public.profiles 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

-- 4. Permanently delete the user from Supabase Authentication
DELETE FROM auth.users 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

COMMIT;

-- 5. Verification Query: Confirm deletion (should return 0 rows)
SELECT id, email, created_at 
FROM auth.users 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';
