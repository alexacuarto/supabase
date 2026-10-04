-- ====================================================================
-- Migration: Dynamic Driver Document Status & Admin Activation
-- Date: September 19, 2026
-- Description:
--   1. Updates public.fn_update_driver_status() trigger function so that
--      manual admin verification (document_status = 'VERIFIED') is preserved
--      and not overwritten back to 'PENDING', even if some document files are missing.
--   2. Provides public.admin_set_driver_document_status() RPC function
--      for instant dynamic activation/deactivation from the Admin Dashboard,
--      with automatic notification and audit logging.
-- ====================================================================

-- 1. Update trigger function fn_update_driver_status()
CREATE OR REPLACE FUNCTION public.fn_update_driver_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  new.updated_at := now();

  -- First, check if expiry dates are in the past
  IF (new.license_expiry_date IS NOT NULL AND new.license_expiry_date < (timezone('Asia/Manila', now()))::date)
     AND (new.franchise_expiry_date IS NOT NULL AND new.franchise_expiry_date < (timezone('Asia/Manila', now()))::date) THEN
    new.document_status := 'PENDING';
    new.document_issue_reason := 'Driver License and Franchise expired';

  ELSIF (new.license_expiry_date IS NOT NULL AND new.license_expiry_date < (timezone('Asia/Manila', now()))::date) THEN
    new.document_status := 'PENDING';
    new.document_issue_reason := 'Driver License expired';

  ELSIF (new.franchise_expiry_date IS NOT NULL AND new.franchise_expiry_date < (timezone('Asia/Manila', now()))::date) THEN
    new.document_status := 'PENDING';
    new.document_issue_reason := 'Franchise/Prangkisa expired';

  -- If explicitly set or preserved as VERIFIED by admin, allow it!
  ELSIF new.document_status = 'VERIFIED' THEN
    new.document_status := 'VERIFIED';
    new.document_issue_reason := null;

  -- If all documents and required fields are uploaded, automatically verify
  ELSIF (
    coalesce(new.license_front_url, '') <> ''
    AND coalesce(new.license_back_url, '') <> ''
    AND coalesce(new.license_number, '') NOT IN ('', 'PENDING')
    AND new.license_expiry_date IS NOT NULL
    AND coalesce(new.franchise_url, '') <> ''
    AND coalesce(new.franchise_number, '') <> ''
    AND new.franchise_expiry_date IS NOT NULL
    AND coalesce(new.toda_association, '') NOT IN ('', 'Not provided')
  ) THEN
    new.document_status := 'VERIFIED';
    new.document_issue_reason := null;

  ELSE
    -- If it was previously VERIFIED and not explicitly reset, maintain VERIFIED
    IF TG_OP = 'UPDATE' AND old.document_status = 'VERIFIED' THEN
      new.document_status := 'VERIFIED';
    ELSE
      new.document_status := 'PENDING';
      IF coalesce(new.document_issue_reason, '') = '' THEN
        new.document_issue_reason := 'Required documents missing';
      END IF;
    END IF;
  END IF;

  -- Sync status, account_status, and online availability
  IF new.admin_action_type IN ('suspended', 'deleted_requested') THEN
    new.status := 'inactive';
    new.account_status := 'SUSPENDED';
    new.is_online := false;
  ELSIF new.document_status = 'VERIFIED' THEN
    new.status := 'approved';
    new.account_status := 'ACTIVE';
  ELSE
    new.status := 'pending';
    new.account_status := 'PENDING';
    new.is_online := false;
  END IF;

  RETURN new;
END;
$$;

-- Ensure trigger is properly bound to public.drivers
DROP TRIGGER IF EXISTS trigger_update_driver_status ON public.drivers;
CREATE TRIGGER trigger_update_driver_status
  BEFORE INSERT OR UPDATE ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.fn_update_driver_status();


-- 2. Stored Procedure: Admin Set Driver Document Status
CREATE OR REPLACE FUNCTION public.admin_set_driver_document_status(
  p_driver_id uuid,
  p_status text,
  p_reason text DEFAULT null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_norm_status text;
  v_profile_id uuid;
  v_updated_driver record;
BEGIN
  -- Verify admin permissions if invoked by authenticated user
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only administrators can change driver document status.';
  END IF;

  v_norm_status := upper(trim(p_status));
  IF v_norm_status NOT IN ('VERIFIED', 'PENDING', 'EXPIRED', 'REJECTED') THEN
    RAISE EXCEPTION 'Invalid document status: %', p_status;
  END IF;

  UPDATE public.drivers
  SET
    document_status = v_norm_status,
    document_issue_reason = CASE
      WHEN v_norm_status = 'VERIFIED' THEN null
      ELSE coalesce(nullif(trim(p_reason), ''), 'Set to pending by administrator')
    END,
    status = CASE
      WHEN v_norm_status = 'VERIFIED' THEN 'approved'
      ELSE 'pending'
    END,
    account_status = CASE
      WHEN v_norm_status = 'VERIFIED' THEN 'ACTIVE'
      ELSE 'PENDING'
    END,
    is_online = CASE
      WHEN v_norm_status = 'VERIFIED' THEN is_online
      ELSE false
    END,
    approved_at = CASE
      WHEN v_norm_status = 'VERIFIED' THEN coalesce(approved_at, now())
      ELSE approved_at
    END,
    approved_by = CASE
      WHEN v_norm_status = 'VERIFIED' THEN coalesce(auth.uid(), approved_by)
      ELSE approved_by
    END,
    updated_at = now()
  WHERE id = p_driver_id
  RETURNING id, profile_id, document_status, status, account_status, is_online INTO v_updated_driver;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Driver with ID % not found', p_driver_id;
  END IF;

  -- Send in-app notification to the driver
  IF v_updated_driver.profile_id IS NOT NULL THEN
    IF v_norm_status = 'VERIFIED' THEN
      INSERT INTO public.notifications (
        recipient_id,
        type,
        title,
        body,
        notification_category,
        data
      ) VALUES (
        v_updated_driver.profile_id,
        'in_app',
        'Documents Approved',
        'Your documents have been approved by the administrator. Your account is now active and you can go online to accept ride requests.',
        'account_status',
        jsonb_build_object(
          'action', 'driver_documents_verified',
          'document_status', 'VERIFIED',
          'date', now()
        )
      );
    ELSE
      INSERT INTO public.notifications (
        recipient_id,
        type,
        title,
        body,
        notification_category,
        data
      ) VALUES (
        v_updated_driver.profile_id,
        'in_app',
        'Document Status Updated',
        'Your document status is currently pending. Reason: ' || coalesce(nullif(trim(p_reason), ''), 'Under review by administrator'),
        'account_status',
        jsonb_build_object(
          'action', 'driver_documents_pending',
          'document_status', v_norm_status,
          'reason', coalesce(nullif(trim(p_reason), ''), 'Under review by administrator'),
          'date', now()
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'driver_id', v_updated_driver.id,
    'document_status', v_updated_driver.document_status,
    'status', v_updated_driver.status,
    'account_status', v_updated_driver.account_status,
    'is_online', v_updated_driver.is_online
  );
END;
$$;

-- Grant permissions for RPC execution
GRANT EXECUTE ON FUNCTION public.admin_set_driver_document_status(uuid, text, text) TO authenticated, service_role, anon;
