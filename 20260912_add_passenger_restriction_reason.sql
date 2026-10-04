-- ====================================================================
-- Migration: Add admin action fields to passengers table
-- Date: September 12, 2026
-- Description: Adds admin_action_type, admin_action_reason, admin_action_date,
--              and admin_action_by to passengers table to match drivers table.
-- ====================================================================

ALTER TABLE public.passengers
ADD COLUMN IF NOT EXISTS admin_action_reason TEXT,
ADD COLUMN IF NOT EXISTS admin_action_type TEXT,
ADD COLUMN IF NOT EXISTS admin_action_date TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS admin_action_by UUID;

COMMENT ON COLUMN public.passengers.admin_action_reason IS 'Explanation provided by admin when restricting a passenger account.';
COMMENT ON COLUMN public.passengers.admin_action_type IS 'Type of administrative action taken (e.g. restricted).';
COMMENT ON COLUMN public.passengers.admin_action_date IS 'Timestamp when the administrative action occurred.';
COMMENT ON COLUMN public.passengers.admin_action_by IS 'Admin user ID who applied the action.';

-- Ensure permissions
GRANT SELECT, INSERT, UPDATE ON public.passengers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.passengers TO service_role;
