-- ============================================================================
-- Migration: Passenger 3-Cancellation Restriction Policy (31 Days) & Admin Controls
-- Description:
--   1. Enforces strict 3 cancellations policy for passengers.
--   2. Restricts booking for 31 days automatically when cancelled bookings reach 3.
--   3. Provides helper RPC functions for admins to manually restrict or lift restrictions immediately.
-- ============================================================================

-- 1. Update cancellation stats trigger function
create or replace function public.update_passenger_cancel_stats()
returns trigger
language plpgsql
security definer
as $$
begin
  if old.status is distinct from new.status
     and new.status = 'cancelled'
     and new.cancelled_by = 'passenger' then
    update public.passengers
    set cancel_count = coalesce(cancel_count, 0) + 1,
        last_cancel_date = now(),
        warning_status = coalesce(cancel_count, 0) + 1 >= 2,
        booking_restriction_until = case
          when coalesce(cancel_count, 0) + 1 >= 3 then now() + interval '31 days'
          else booking_restriction_until
        end,
        updated_at = now()
    where id = new.passenger_id;
  end if;
  return new;
end;
$$;

-- Ensure trigger is attached on bookings
drop trigger if exists trg_update_passenger_cancel_stats on public.bookings;
create trigger trg_update_passenger_cancel_stats
  after update of status on public.bookings
  for each row execute function public.update_passenger_cancel_stats();

-- 2. Admin function to restrict passenger for N days (defaults to 31)
create or replace function public.admin_restrict_passenger(
  p_passenger_id uuid,
  p_days int default 31
)
returns void
language plpgsql
security definer
as $$
begin
  update public.passengers
  set booking_restriction_until = now() + (coalesce(p_days, 31) || ' days')::interval,
      cancel_count = greatest(coalesce(cancel_count, 0), 3),
      warning_status = true,
      updated_at = now()
  where id = p_passenger_id;
end;
$$;

-- 3. Admin function to immediately lift passenger restriction and reset cancel counts
create or replace function public.admin_lift_passenger_restriction(
  p_passenger_id uuid
)
returns void
language plpgsql
security definer
as $$
declare
  v_profile_id uuid;
begin
  select profile_id into v_profile_id
  from public.passengers
  where id = p_passenger_id;

  update public.passengers
  set booking_restriction_until = null,
      cancel_count = 0,
      warning_status = false,
      updated_at = now()
  where id = p_passenger_id;

  if v_profile_id is not null then
    update public.profiles
    set is_active = true
    where id = v_profile_id;
  end if;
end;
$$;

grant execute on function public.admin_restrict_passenger(uuid, int) to authenticated, anon;
grant execute on function public.admin_lift_passenger_restriction(uuid) to authenticated, anon;
