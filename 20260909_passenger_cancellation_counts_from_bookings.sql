-- ============================================================================
-- TODA GO: Passenger Cancellation Counts From Booking Rows
-- Date: 2026-09-09
--
-- Purpose:
--   Visible cancelled trip history should come from public.bookings. The cached
--   passengers.cancel_count is kept only for the 3-cancellation restriction
--   policy and is recalculated from passenger-caused booking cancellations.
-- ============================================================================

begin;

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
begin
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

  if v_policy_cancelled >= 3 then
    select coalesce(booking_restriction_until, now() + interval '31 days')
    into v_restriction_until
    from public.passengers
    where id = p_passenger_id;
  else
    v_restriction_until := null;
  end if;

  update public.passengers
  set cancel_count = coalesce(v_policy_cancelled, 0),
      last_cancel_date = v_last_passenger_cancel,
      warning_status = coalesce(v_policy_cancelled, 0) = 2,
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

create or replace function public.update_passenger_cancel_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE'
     and (
       old.status is distinct from new.status
       or old.cancelled_by is distinct from new.cancelled_by
       or old.passenger_id is distinct from new.passenger_id
     ) then
    perform public.recalculate_passenger_cancellation_stats(new.passenger_id);
    if old.passenger_id is distinct from new.passenger_id then
      perform public.recalculate_passenger_cancellation_stats(old.passenger_id);
    end if;
  elsif tg_op = 'INSERT' and new.status = 'cancelled' then
    perform public.recalculate_passenger_cancellation_stats(new.passenger_id);
  elsif tg_op = 'DELETE' and old.status = 'cancelled' then
    perform public.recalculate_passenger_cancellation_stats(old.passenger_id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists after_booking_cancel_update on public.bookings;
drop trigger if exists trg_update_passenger_cancel_stats on public.bookings;
create trigger after_booking_cancel_update
  after insert or update of status, cancelled_by, passenger_id or delete on public.bookings
  for each row execute function public.update_passenger_cancel_stats();

do $$
declare
  v_passenger_id uuid;
begin
  for v_passenger_id in select id from public.passengers loop
    perform public.recalculate_passenger_cancellation_stats(v_passenger_id);
  end loop;
end $$;

grant execute on function public.recalculate_passenger_cancellation_stats(uuid) to authenticated, anon;

commit;
