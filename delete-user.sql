-- ============================================================================
-- Delete Specific User from Supabase Auth & Public Tables
-- Target User UUID: f11dc5c2-0483-428c-9bd0-bee8b4af8f07
-- Safe execution: Affects ONLY this user without breaking the rest of the database
-- ============================================================================

BEGIN;

-- 1. Remove auth identity & session records for this specific user
DELETE FROM auth.identities 
WHERE user_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM auth.sessions 
WHERE user_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

-- 2. Clean up any leftover profile, notification, or token records if any exist
DELETE FROM public.notifications 
WHERE recipient_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM public.push_tokens 
WHERE profile_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM public.reports 
WHERE reporter_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07' 
   OR reporter_profile_id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

DELETE FROM public.profiles 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

-- 3. Permanently delete the user from Supabase Authentication
DELETE FROM auth.users 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';

COMMIT;

-- 4. Verification Query: Confirm deletion (should return 0 rows)
SELECT id, email, created_at 
FROM auth.users 
WHERE id = 'f11dc5c2-0483-428c-9bd0-bee8b4af8f07';
