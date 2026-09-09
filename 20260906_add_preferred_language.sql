-- Migration: Add preferred_language column to public.profiles table
-- Allows passengers and drivers to store their account-bound language selection ('en' for English, 'tl' for Tagalog/Filipino)

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS preferred_language text DEFAULT 'en';

-- Ensure values are constrained to supported language codes
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

-- Index for efficient querying if needed
CREATE INDEX IF NOT EXISTS idx_profiles_preferred_lang ON public.profiles(preferred_language);

COMMENT ON COLUMN public.profiles.preferred_language IS 'User preferred interface language: en (English) or tl (Tagalog/Filipino)';
