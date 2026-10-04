-- Revision: Add selfie_photo_url to passengers table for mandatory selfie verification
-- Date: 2026-09-10

alter table public.passengers
  add column if not exists selfie_photo_url text;

-- Also ensure RLS / permissions allow authenticated users to update their own passenger row
-- or insert when registering.
