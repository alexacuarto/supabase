-- Migration: Admin-Only Passenger Restrictions & Clean Sync
-- Date: 2026-09-11
-- Ensures only administrators can restrict and lift passenger booking restrictions.
-- Matches passenger by id OR profile_id, re-activates profile on lift, and resets cancel stats.

begin;

-- 1. Admin restrict passenger function
create or replace function public.admin_restrict_passenger(p_passenger_id uuid, p_days int default 31)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_passenger_id uuid;
  v_profile_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Invalid restriction duration.'; end if;

  select id, profile_id into v_passenger_id, v_profile_id
  from public.passengers
  where id = p_passenger_id or profile_id = p_passenger_id
  limit 1;

  if v_passenger_id is null then
    if exists (select 1 from public.profiles where id = p_passenger_id and role = 'passenger') then
      insert into public.passengers (id, profile_id, booking_restriction_until, updated_at)
      values (gen_random_uuid(), p_passenger_id, now() + make_interval(days => p_days), now())
      returning id, profile_id into v_passenger_id, v_profile_id;
    else
      raise exception 'Passenger not found.';
    end if;
  else
    update public.passengers
    set booking_restriction_until = now() + make_interval(days => p_days),
        updated_at = now()
    where id = v_passenger_id;
  end if;

  if v_profile_id is not null then
    update public.profiles set updated_at = now() where id = v_profile_id;
  end if;
end;
$$;

-- 2. Admin lift passenger restriction function
create or replace function public.admin_lift_passenger_restriction(p_passenger_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_passenger_id uuid;
  v_profile_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required.'; end if;

  select id, profile_id into v_passenger_id, v_profile_id
  from public.passengers
  where id = p_passenger_id or profile_id = p_passenger_id
  limit 1;

  if v_passenger_id is not null then
    update public.passengers
    set booking_restriction_until = null,
        cancel_count = 0,
        warning_status = false,
        updated_at = now()
    where id = v_passenger_id;
  end if;

  -- Guarantee the profile is active so booking checks and triggers succeed
  update public.profiles
  set is_active = true,
      updated_at = now()
  where id = coalesce(v_profile_id, p_passenger_id);
end;
$$;

-- 3. Recalculate cancellation stats (warning status & count only; restrictions solely administered)
create or replace function public.recalculate_passenger_cancellation_stats(
  p_passenger_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_cancelled integer := 0;
  v_policy_cancelled integer := 0;
  v_driver_cancelled integer := 0;
  v_last_passenger_cancel timestamptz;
  v_restriction_until timestamptz;
  v_previous_count integer;
begin
  if auth.uid() is not null and not public.is_admin()
     and p_passenger_id is distinct from public.current_passenger_id()
     and pg_trigger_depth() = 0 then
    raise exception 'Not authorized to recalculate this passenger.';
  end if;

  select cancel_count, booking_restriction_until into v_previous_count, v_restriction_until
  from public.passengers where id = p_passenger_id for update;

  select
    count(*) filter (where status = 'cancelled')::integer,
    count(*) filter (
      where status = 'cancelled'
        and (cancelled_by = 'passenger' or cancelled_by is null)
        and coalesce(cancelled_at, created_at) >= now() - interval '31 days'
    )::integer,
    count(*) filter (where status = 'cancelled' and cancelled_by = 'driver')::integer,
    max(cancelled_at) filter (
      where status = 'cancelled'
        and (cancelled_by = 'passenger' or cancelled_by is null)
    )
  into v_total_cancelled, v_policy_cancelled, v_driver_cancelled, v_last_passenger_cancel
  from public.bookings
  where passenger_id = p_passenger_id;

  -- Only expire past restrictions; do not automatically impose restrictions
  if v_restriction_until is not null and v_restriction_until <= now() then
    v_restriction_until := null;
  end if;

  update public.passengers
  set cancel_count = coalesce(v_policy_cancelled, 0),
      last_cancel_date = v_last_passenger_cancel,
      warning_status = coalesce(v_policy_cancelled, 0) >= 2,
      booking_restriction_until = v_restriction_until,
      updated_at = now()
  where id = p_passenger_id;

  return jsonb_build_object(
    'success', true,
    'passenger_id', p_passenger_id,
    'total_cancelled', coalesce(v_total_cancelled, 0),
    'policy_cancelled', coalesce(v_policy_cancelled, 0),
    'driver_cancelled', coalesce(v_driver_cancelled, 0),
    'restricted_until', v_restriction_until
  );
end;
$$;

grant execute on function public.admin_restrict_passenger(uuid, int) to authenticated, anon;
grant execute on function public.admin_lift_passenger_restriction(uuid) to authenticated, anon;
grant execute on function public.recalculate_passenger_cancellation_stats(uuid) to authenticated, anon;

commit;
