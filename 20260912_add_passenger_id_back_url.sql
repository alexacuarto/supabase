-- ====================================================================
-- Migration: Add discount_document_back_url to passengers table
-- Date: September 12, 2026
-- Description: Adds column for storing the back page of passenger verification ID.
-- ====================================================================

ALTER TABLE public.passengers
ADD COLUMN IF NOT EXISTS discount_document_back_url text;

COMMENT ON COLUMN public.passengers.discount_document_back_url IS 'Storage path or URL for the back page of the passenger verification ID.';

-- Ensure permissions
GRANT SELECT, INSERT, UPDATE ON public.passengers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.passengers TO service_role;
