BEGIN;

-- 1. Remove auth identity & session records for this specific user
DELETE FROM auth.identities 
WHERE user_id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

DELETE FROM auth.sessions 
WHERE user_id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

-- 2. Clean up any leftover profile, notification, or token records if any exist
DELETE FROM public.notifications 
WHERE recipient_id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

DELETE FROM public.push_tokens 
WHERE profile_id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

DELETE FROM public.profiles 
WHERE id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

-- 3. Permanently delete the user from Supabase Authentication
DELETE FROM auth.users 
WHERE id = '1424b0f4-1c5a-4b5c-97a4-db0247896b1c';

COMMIT;