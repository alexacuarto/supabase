-- ====================================================================
-- Migration: Add franchise_back_url to drivers table
-- Date: September 05, 2026
-- Description: Adds column for storing the back page of driver franchise documents.
-- ====================================================================

ALTER TABLE public.drivers
ADD COLUMN IF NOT EXISTS franchise_back_url text;

COMMENT ON COLUMN public.drivers.franchise_back_url IS 'Public storage URL for the back page of the driver franchise/permit document.';

-- Grant permissions if necessary
GRANT SELECT, INSERT, UPDATE ON public.drivers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.drivers TO service_role;
