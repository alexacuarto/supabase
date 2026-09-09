-- Migration: 20260906_fix_driver_online_time_and_sessions.sql
-- Fixes driver online time tracking and ensures synchronized session logging

-- 1. Close any stale sessions left hanging without went_offline
UPDATE public.driver_sessions
SET went_offline = went_online + interval '30 minutes'
WHERE went_offline IS NULL
  AND went_online < now() - interval '24 hours';

-- 2. Improved set_driver_online_status RPC
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
    -- Auto-close any lingering/stale session older than 24 hours
    UPDATE public.driver_sessions
    SET went_offline = went_online + interval '30 minutes'
    WHERE driver_id = v_driver.id
      AND went_offline IS NULL
      AND went_online < v_now - interval '24 hours';

    -- Find or create open session
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

    -- Ensure last_online_at in drivers table is identical to session start
    UPDATE public.drivers
    SET is_online = true,
        last_online_at = v_open_session.went_online,
        updated_at = v_now
    WHERE id = v_driver.id;

  ELSE
    -- Going offline: close active session and compute elapsed minutes
    SELECT * INTO v_open_session
    FROM public.driver_sessions
    WHERE driver_id = v_driver.id AND went_offline IS NULL
    ORDER BY went_online DESC
    LIMIT 1
    FOR UPDATE;

    IF v_open_session.id IS NOT NULL THEN
      v_added_minutes := GREATEST(0, FLOOR(EXTRACT(epoch FROM (v_now - v_open_session.went_online)) / 60)::integer);
      UPDATE public.driver_sessions
      SET went_offline = v_now
      WHERE id = v_open_session.id;
    END IF;

    -- Ensure all open sessions for this driver are closed
    UPDATE public.driver_sessions
    SET went_offline = v_now
    WHERE driver_id = v_driver.id AND went_offline IS NULL;

    UPDATE public.drivers
    SET is_online = false,
        last_online_at = NULL,
        total_online_minutes = COALESCE(total_online_minutes, 0) + v_added_minutes,
        updated_at = v_now
    WHERE id = v_driver.id;
  END IF;

  RETURN json_build_object(
    'success', true,
    'driver_id', v_driver.id,
    'is_online', p_is_online,
    'added_minutes', v_added_minutes,
    'last_online_at', CASE WHEN p_is_online THEN v_open_session.went_online ELSE NULL END
  );
END;
$$;
