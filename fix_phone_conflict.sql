BEGIN;

UPDATE auth.users
SET phone = '0979904148',
    raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '{"phone_number": "0979904148"}'::jsonb,
    updated_at = now()
WHERE lower(email) = 'roljohnraca41@gmail.com'
   OR id = '2eaf6f89-ae15-4048-a58a-1899e0d8deef';

UPDATE public.profiles
SET phone_number = '0979904148',
    updated_at = now()
WHERE id = '2eaf6f89-ae15-4048-a58a-1899e0d8deef';

UPDATE auth.users
SET phone = NULL,
    updated_at = now()
WHERE phone = '09092128908'
  AND lower(email) <> 'roljohnraca41@gmail.com'
  AND id <> '2eaf6f89-ae15-4048-a58a-1899e0d8deef';

CREATE OR REPLACE FUNCTION public.sync_profile_phone_to_auth()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  IF new.phone_number IS DISTINCT FROM old.phone_number THEN
    UPDATE auth.users
    SET phone = new.phone_number,
        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('phone_number', new.phone_number),
        updated_at = now()
    WHERE id = new.id;
  END IF;
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_profile_phone_to_auth ON public.profiles;
CREATE TRIGGER trg_sync_profile_phone_to_auth
AFTER UPDATE OF phone_number ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.sync_profile_phone_to_auth();

COMMIT;
