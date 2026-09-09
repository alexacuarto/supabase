-- ============================================================================
-- TodaGo Revision: Driver Account Restriction & Real-Time Sync
-- Date: September 05, 2026
-- 
-- Description:
--   This SQL script contains ONLY the changes for the Driver Restriction revision.
--   Run this in your Supabase Dashboard -> SQL Editor.
-- ============================================================================

-- 1. Ensure driver restriction columns exist on public.drivers
ALTER TABLE public.drivers
  ADD COLUMN IF NOT EXISTS admin_action_type text,
  ADD COLUMN IF NOT EXISTS admin_action_reason text,
  ADD COLUMN IF NOT EXISTS admin_action_date timestamptz,
  ADD COLUMN IF NOT EXISTS admin_action_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.drivers.admin_action_type IS 'Status of administrative action (e.g. restricted, deleted_requested)';
COMMENT ON COLUMN public.drivers.admin_action_reason IS 'Reason given by administrator for the restriction';
COMMENT ON COLUMN public.drivers.admin_action_date IS 'Timestamp when the admin action was applied';
COMMENT ON COLUMN public.drivers.admin_action_by IS 'Admin profile ID who applied the restriction';

-- 2. Stored Procedure: Restrict Driver
-- Updates driver record, immediately forces driver offline, and sends an in-app notification
CREATE OR REPLACE FUNCTION public.admin_restrict_driver(
  p_driver_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  -- Check admin permission if called directly via authenticated user
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can restrict drivers.';
  END IF;

  UPDATE public.drivers
  SET admin_action_type = 'restricted',
      admin_action_reason = trim(p_reason),
      admin_action_date = now(),
      admin_action_by = coalesce(auth.uid(), admin_action_by),
      is_online = false,
      account_status = 'RESTRICTED',
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
      jsonb_build_object(
        'action', 'driver_restricted',
        'reason', trim(p_reason),
        'restricted_at', now()
      )
    );
  END IF;
END;
$$;

-- 3. Stored Procedure: Lift Driver Restriction
-- Clears restriction fields and notifies driver they can go online again
CREATE OR REPLACE FUNCTION public.admin_lift_driver_restriction(
  p_driver_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile_id uuid;
BEGIN
  -- Check admin permission if called directly via authenticated user
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can lift driver restrictions.';
  END IF;

  UPDATE public.drivers
  SET admin_action_type = null,
      admin_action_reason = null,
      admin_action_date = null,
      admin_action_by = null,
      account_status = CASE WHEN document_status = 'VERIFIED' THEN 'ACTIVE' ELSE 'PENDING' END,
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
      jsonb_build_object(
        'action', 'driver_restriction_lifted',
        'lifted_at', now()
      )
    );
  END IF;
END;
$$;

-- 4. Grant permissions
GRANT EXECUTE ON FUNCTION public.admin_restrict_driver(uuid, text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_lift_driver_restriction(uuid) TO authenticated, anon;
