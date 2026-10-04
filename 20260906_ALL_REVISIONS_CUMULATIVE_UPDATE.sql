-- ============================================================================
-- TODA GO: ALL-IN-ONE CUMULATIVE DATABASE REVISIONS SCRIPT
-- Date: September 06, 2026
-- 
-- INSTRUCTIONS:
--   1. Open your Supabase Dashboard -> SQL Editor
--   2. Paste this ENTIRE script and click "RUN"
--   3. This script is 100% idempotent: it is safe to run on top of any previous
--      migration without causing errors or duplicating data.
--
-- INCLUDED REVISIONS:
--   Section 1: Franchise Back URL column on drivers
--   Section 2: TODA Association Standardization (LHITC-TODA, BYPASS, CHOT)
--   Section 3: Passenger 3-Cancellation 31-Day Restriction Policy & Admin RPCs
--   Section 4: Driver Profile Change Requests Workflow & In-App Notifications
--   Section 5: Safe Atomic Driver & Passenger Deletion (Admin RPCs & Policies)
--   Section 6: Driver Online Time & Session Synchronization (set_driver_online_status)
--   Section 7: Bilingual Localization (preferred_language on public.profiles)
--   Section 8: Realtime Sync Publication Configuration
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
  ALTER TABLE public.drivers
    ALTER COLUMN toda_association SET DEFAULT 'LHITC-TODA';

  UPDATE public.drivers
  SET toda_association = 'LHITC-TODA'
  WHERE toda_association IS NULL
     OR trim(toda_association) = ''
     OR toda_association = 'Not provided'
     OR toda_association NOT IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA');

  ALTER TABLE public.drivers
    DROP CONSTRAINT IF EXISTS check_valid_toda_association;

  ALTER TABLE public.drivers
    ADD CONSTRAINT check_valid_toda_association
    CHECK (toda_association IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA'));
EXCEPTION
  WHEN others THEN NULL;
END $$;

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
  v_updated_driver public.drivers%ROWTYPE;
BEGIN
  IF p_toda_association NOT IN ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') THEN
    RETURN json_build_object(
      'success', false,
      'message', 'Invalid TODA association. Must be LHITC-TODA, BYPASS ILAYANG BAGUIO-TODA, or CHOT-TODA.'
    );
  END IF;

  UPDATE public.drivers
  SET toda_association = p_toda_association,
      updated_at = now()
  WHERE id = p_driver_id
  RETURNING * INTO v_updated_driver;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Driver not found.');
  END IF;

  RETURN json_build_object(
    'success', true,
    'message', 'TODA association updated successfully.',
    'driver', row_to_json(v_updated_driver)
  );
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- 3. PASSENGER CANCELLATION 31-DAY RESTRICTION & ADMIN RPCs
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.passengers
ADD COLUMN IF NOT EXISTS cancel_count integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS last_cancel_date timestamptz,
ADD COLUMN IF NOT EXISTS booking_restriction_until timestamptz,
ADD COLUMN IF NOT EXISTS warning_status boolean DEFAULT false;

CREATE OR REPLACE FUNCTION public.check_and_apply_passenger_restrictions(p_passenger_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_count integer;
  v_last_cancel timestamptz;
  v_restriction_until timestamptz;
  v_is_warning boolean := false;
  v_now timestamptz := now();
BEGIN
  SELECT cancel_count, last_cancel_date, booking_restriction_until
  INTO v_current_count, v_last_cancel, v_restriction_until
  FROM public.passengers
  WHERE id = p_passenger_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Passenger not found');
  END IF;

  IF v_last_cancel IS NOT NULL AND v_last_cancel < (v_now - interval '31 days') THEN
    v_current_count := 0;
  END IF;

  v_current_count := COALESCE(v_current_count, 0) + 1;
  v_last_cancel := v_now;

  IF v_current_count >= 3 THEN
    v_restriction_until := v_now + interval '31 days';
    v_is_warning := false;
  ELSIF v_current_count = 2 THEN
    v_is_warning := true;
  END IF;

  UPDATE public.passengers
  SET cancel_count = v_current_count,
      last_cancel_date = v_last_cancel,
      booking_restriction_until = v_restriction_until,
      warning_status = v_is_warning,
      updated_at = v_now
  WHERE id = p_passenger_id;

  RETURN json_build_object(
    'success', true,
    'cancel_count', v_current_count,
    'warning_status', v_is_warning,
    'restricted_until', v_restriction_until
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_lift_passenger_restriction(p_passenger_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.passengers
  SET cancel_count = 0,
      booking_restriction_until = NULL,
      warning_status = false,
      updated_at = now()
  WHERE id = p_passenger_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Passenger record not found');
  END IF;

  RETURN json_build_object('success', true, 'message', 'Restriction lifted successfully');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_passenger_restriction(
  p_passenger_id uuid,
  p_days integer DEFAULT 31
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_until timestamptz;
BEGIN
  v_until := now() + (p_days || ' days')::interval;

  UPDATE public.passengers
  SET booking_restriction_until = v_until,
      cancel_count = GREATEST(COALESCE(cancel_count, 0), 3),
      warning_status = false,
      updated_at = now()
  WHERE id = p_passenger_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Passenger record not found');
  END IF;

  RETURN json_build_object(
    'success', true,
    'message', 'Passenger restricted successfully',
    'restricted_until', v_until
  );
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- 4. DRIVER PROFILE CHANGE REQUESTS & NOTIFICATIONS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.driver_profile_change_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  field_name text NOT NULL,
  old_value text,
  new_value text NOT NULL,
  reason text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  admin_notes text,
  reviewed_by uuid REFERENCES auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_driver_change_requests_driver ON public.driver_profile_change_requests(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_change_requests_status ON public.driver_profile_change_requests(status);

ALTER TABLE public.driver_profile_change_requests ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  DROP POLICY IF EXISTS driver_change_requests_select ON public.driver_profile_change_requests;
  CREATE POLICY driver_change_requests_select ON public.driver_profile_change_requests
    FOR SELECT USING (true);

  DROP POLICY IF EXISTS driver_change_requests_insert_own ON public.driver_profile_change_requests;
  CREATE POLICY driver_change_requests_insert_own ON public.driver_profile_change_requests
    FOR INSERT WITH CHECK (true);

  DROP POLICY IF EXISTS driver_change_requests_update_admin ON public.driver_profile_change_requests;
  CREATE POLICY driver_change_requests_update_admin ON public.driver_profile_change_requests
    FOR UPDATE USING (true);
EXCEPTION
  WHEN others THEN NULL;
END $$;

-- Notifications table
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  message text NOT NULL,
  type text NOT NULL DEFAULT 'general',
  is_read boolean NOT NULL DEFAULT false,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, is_read);
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
  CREATE POLICY notifications_select_own ON public.notifications
    FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

  DROP POLICY IF EXISTS notifications_update_own ON public.notifications;
  CREATE POLICY notifications_update_own ON public.notifications
    FOR UPDATE USING (auth.uid() = user_id OR public.is_admin());

  DROP POLICY IF EXISTS notifications_insert_system ON public.notifications;
  CREATE POLICY notifications_insert_system ON public.notifications
    FOR INSERT WITH CHECK (true);
EXCEPTION
  WHEN others THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.admin_review_driver_change_request(
  p_request_id uuid,
  p_status text,
  p_admin_notes text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_req public.driver_profile_change_requests%ROWTYPE;
  v_driver public.drivers%ROWTYPE;
  v_notif_title text;
  v_notif_msg text;
BEGIN
  IF p_status NOT IN ('approved', 'rejected') THEN
    RETURN json_build_object('success', false, 'message', 'Invalid status. Must be approved or rejected.');
  END IF;

  SELECT * INTO v_req
  FROM public.driver_profile_change_requests
  WHERE id = p_request_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'message', 'Request not found.');
  END IF;

  IF v_req.status != 'pending' THEN
    RETURN json_build_object('success', false, 'message', 'Request has already been processed.');
  END IF;

  SELECT * INTO v_driver
  FROM public.drivers
  WHERE id = v_req.driver_id;

  UPDATE public.driver_profile_change_requests
  SET status = p_status,
      admin_notes = p_admin_notes,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  WHERE id = p_request_id;

  IF p_status = 'approved' THEN
    IF v_req.field_name IN ('phone', 'phone_number') THEN
      UPDATE public.profiles SET phone_number = v_req.new_value WHERE id = v_driver.profile_id;
    ELSIF v_req.field_name = 'email' THEN
      UPDATE public.profiles SET email = v_req.new_value WHERE id = v_driver.profile_id;
    ELSIF v_req.field_name = 'address' THEN
      UPDATE public.profiles SET address = v_req.new_value WHERE id = v_driver.profile_id;
    ELSIF v_req.field_name = 'toda_association' THEN
      UPDATE public.drivers SET toda_association = v_req.new_value WHERE id = v_driver.id;
    ELSIF v_req.field_name = 'plate_number' THEN
      UPDATE public.vehicles SET plate_number = v_req.new_value WHERE driver_id = v_driver.id;
    END IF;

    v_notif_title := 'Profile Update Approved';
    v_notif_msg := format('Your request to update %s has been approved.', v_req.field_name);
  ELSE
    v_notif_title := 'Profile Update Rejected';
    v_notif_msg := format('Your request to update %s was declined. Reason: %s', v_req.field_name, COALESCE(p_admin_notes, 'No reason provided.'));
  END IF;

  IF v_driver.profile_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, title, message, type, metadata)
    VALUES (
      v_driver.profile_id,
      v_notif_title,
      v_notif_msg,
      'profile_change_' || p_status,
      jsonb_build_object('field', v_req.field_name, 'status', p_status, 'notes', p_admin_notes)
    );
  END IF;

  RETURN json_build_object('success', true, 'status', p_status);
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- 5. SAFE ATOMIC DRIVER & PASSENGER DELETION (ADMIN RPCs & POLICIES)
-- ────────────────────────────────────────────────────────────────────────────
GRANT DELETE ON public.drivers TO authenticated, service_role;
GRANT DELETE ON public.passengers TO authenticated, service_role;
GRANT DELETE ON public.profiles TO authenticated, service_role;

DO $$
BEGIN
  DROP POLICY IF EXISTS drivers_delete_admin ON public.drivers;
  CREATE POLICY drivers_delete_admin ON public.drivers
    FOR DELETE USING (public.is_admin());

  DROP POLICY IF EXISTS passengers_delete_admin ON public.passengers;
  CREATE POLICY passengers_delete_admin ON public.passengers
    FOR DELETE USING (public.is_admin());

  DROP POLICY IF EXISTS profiles_delete_admin ON public.profiles;
  CREATE POLICY profiles_delete_admin ON public.profiles
    FOR DELETE USING (public.is_admin());
EXCEPTION
  WHEN others THEN NULL;
END $$;

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
  DELETE FROM public.driver_documents WHERE driver_id = p_driver_id;
  DELETE FROM public.driver_profile_change_requests WHERE driver_id = p_driver_id;
  DELETE FROM public.vehicles WHERE driver_id = p_driver_id;
  DELETE FROM public.ratings WHERE driver_id = p_driver_id;
  DELETE FROM public.notifications WHERE user_id = v_profile_id;
  DELETE FROM public.drivers WHERE id = p_driver_id;

  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.profiles WHERE id = v_profile_id;
    BEGIN
      DELETE FROM auth.users WHERE id = v_profile_id;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN json_build_object('success', true, 'message', 'Driver deleted completely.');
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

  UPDATE public.bookings 
  SET passenger_id = NULL 
  WHERE passenger_id = p_passenger_id;

  DELETE FROM public.passenger_locations WHERE passenger_id = p_passenger_id;
  DELETE FROM public.ratings WHERE passenger_id = p_passenger_id;
  DELETE FROM public.notifications WHERE user_id = v_profile_id;
  DELETE FROM public.passengers WHERE id = p_passenger_id;

  IF v_profile_id IS NOT NULL THEN
    DELETE FROM public.profiles WHERE id = v_profile_id;
    BEGIN
      DELETE FROM auth.users WHERE id = v_profile_id;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN json_build_object('success', true, 'message', 'Passenger deleted completely.');
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- 6. DRIVER ONLINE TIME & SESSION SYNCHRONIZATION
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.driver_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id uuid NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  went_online timestamptz NOT NULL DEFAULT now(),
  went_offline timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_driver_sessions_driver_offline 
ON public.driver_sessions(driver_id, went_offline);

ALTER TABLE public.driver_sessions ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  DROP POLICY IF EXISTS driver_sessions_all ON public.driver_sessions;
  CREATE POLICY driver_sessions_all ON public.driver_sessions
    FOR ALL USING (true) WITH CHECK (true);
EXCEPTION
  WHEN others THEN NULL;
END $$;

UPDATE public.driver_sessions
SET went_offline = went_online + interval '30 minutes'
WHERE went_offline IS NULL
  AND went_online < now() - interval '24 hours';

CREATE OR REPLACE FUNCTION public.set_driver_online_status(p_is_online boolean)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver public.drivers%ROWTYPE;
  v_open_session public.driver_sessions%ROWTYPE;
  v_now timestamptz := now();
  v_added_minutes integer := 0;
BEGIN
  SELECT * INTO v_driver
  FROM public.drivers
  WHERE profile_id = auth.uid()
  FOR UPDATE;

  IF v_driver.id IS NULL THEN
    RAISE EXCEPTION 'No driver record found for current user.';
  END IF;

  IF p_is_online THEN
    UPDATE public.driver_sessions
    SET went_offline = went_online + interval '30 minutes'
    WHERE driver_id = v_driver.id
      AND went_offline IS NULL
      AND went_online < v_now - interval '24 hours';

    SELECT * INTO v_open_session
    FROM public.driver_sessions
    WHERE driver_id = v_driver.id AND went_offline IS NULL
    ORDER BY went_online DESC
    LIMIT 1;

    IF v_open_session.id IS NULL THEN
      INSERT INTO public.driver_sessions (driver_id, went_online)
      VALUES (v_driver.id, v_now)
      RETURNING * INTO v_open_session;
    END IF;

    UPDATE public.drivers
    SET is_online = true,
        last_online_at = v_open_session.went_online,
        updated_at = v_now
    WHERE id = v_driver.id;

  ELSE
    SELECT * INTO v_open_session
    FROM public.driver_sessions
    WHERE driver_id = v_driver.id AND went_offline IS NULL
    ORDER BY went_online DESC
    LIMIT 1;

    IF v_open_session.id IS NOT NULL THEN
      UPDATE public.driver_sessions
      SET went_offline = v_now
      WHERE id = v_open_session.id;

      v_added_minutes := GREATEST(0, ROUND(EXTRACT(EPOCH FROM (v_now - v_open_session.went_online)) / 60.0)::integer);
    END IF;

    UPDATE public.drivers
    SET is_online = false,
        last_online_at = NULL,
        total_online_minutes = COALESCE(total_online_minutes, 0) + v_added_minutes,
        updated_at = v_now
    WHERE id = v_driver.id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'is_online', p_is_online,
    'driver_id', v_driver.id,
    'added_minutes', v_added_minutes
  );
END;
$$;


-- ────────────────────────────────────────────────────────────────────────────
-- 7. BILINGUAL LOCALIZATION (preferred_language ON public.profiles)
-- ────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS preferred_language text DEFAULT 'en';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'profiles_preferred_language_check'
  ) THEN
    ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_preferred_language_check
    CHECK (preferred_language IN ('en', 'tl'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_profiles_preferred_lang 
ON public.profiles(preferred_language);

COMMENT ON COLUMN public.profiles.preferred_language 
IS 'User preferred interface language: en (English) or tl (Tagalog/Filipino)';


-- ────────────────────────────────────────────────────────────────────────────
-- 8. REALTIME REPLICATION RE-SYNCHRONIZATION
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.drivers;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_locations;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_sessions;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_profile_change_requests;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.passengers;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;

  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- 9. DRIVER PUBLIC STATS & REVIEWS (SECURITY DEFINER RPCs)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_driver_public_stats(p_driver_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_completed_trips integer := 0;
  v_average_rating numeric(3,2) := 0.0;
  v_ratings_count integer := 0;
BEGIN
  -- Total completed trips from bookings across all passengers
  SELECT COUNT(*)
  INTO v_completed_trips
  FROM public.bookings
  WHERE driver_id = p_driver_id
    AND status = 'completed';

  -- Total ratings count and average rating from ratings table
  SELECT COUNT(*), COALESCE(ROUND(AVG(rating)::numeric, 2), 0.0)
  INTO v_ratings_count, v_average_rating
  FROM public.ratings
  WHERE driver_id = p_driver_id;

  RETURN json_build_object(
    'completed_trips', v_completed_trips,
    'average_rating', v_average_rating,
    'ratings_count', v_ratings_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_public_stats(uuid) TO authenticated, service_role, anon;

CREATE OR REPLACE FUNCTION public.get_driver_reviews(p_driver_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviews json;
BEGIN
  SELECT COALESCE(json_agg(r_data), '[]'::json)
  INTO v_reviews
  FROM (
    SELECT 
      r.id,
      r.rating,
      r.review,
      r.created_at,
      p.first_name,
      p.last_name
    FROM public.ratings r
    LEFT JOIN public.passengers pass ON pass.id = r.passenger_id
    LEFT JOIN public.profiles p ON p.id = pass.profile_id
    WHERE r.driver_id = p_driver_id
    ORDER BY r.created_at DESC
  ) r_data;

  RETURN v_reviews;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_reviews(uuid) TO authenticated, service_role, anon;

-- ────────────────────────────────────────────────────────────────────────────
-- COMPLETED ALL CUMULATIVE REVISIONS
-- ────────────────────────────────────────────────────────────────────────────

