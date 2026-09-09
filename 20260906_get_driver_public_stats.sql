-- ============================================================================
-- Migration: 20260906_get_driver_public_stats.sql
-- Description: Provide SECURITY DEFINER functions to fetch accurate driver
--              statistics (completed trips & ratings) and reviews without
--              violating passenger Row Level Security policies on bookings.
-- ============================================================================

-- 1. Function: get_driver_public_stats
-- Computes live completed trips count from bookings and rating statistics from ratings
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

-- Grant execution to authenticated users and service_role
GRANT EXECUTE ON FUNCTION public.get_driver_public_stats(uuid) TO authenticated, service_role, anon;

-- 2. Function: get_driver_reviews
-- Returns all ratings and reviews for a given driver with reviewer first name
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

-- Grant execution to authenticated users and service_role
GRANT EXECUTE ON FUNCTION public.get_driver_reviews(uuid) TO authenticated, service_role, anon;
