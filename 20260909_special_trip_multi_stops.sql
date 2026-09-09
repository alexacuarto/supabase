-- ============================================================================
-- TODA GO: Special Trip Multi-Stop Support
-- Date: 2026-09-09
--
-- Purpose:
--   1. Adds multi-stop support for Special Trips (up to 8 stops).
--   2. Adds stops (jsonb), total_stops (integer), current_stop_index (integer).
--   3. Relaxes/updates trip_phase check constraint.
--   4. Adds helper RPC advance_booking_stop to atomically advance to next stop.
-- ============================================================================

begin;

-- 1. Add multi-stop columns to public.bookings
alter table public.bookings
  add column if not exists stops jsonb not null default '[]'::jsonb,
  add column if not exists total_stops integer not null default 1,
  add column if not exists current_stop_index integer not null default 0;

-- 2. Update trip_phase check constraint to support multi-stop phases
alter table public.bookings
  drop constraint if exists bookings_trip_phase_check;

alter table public.bookings
  add constraint bookings_trip_phase_check
  check (
    trip_phase in (
      'to_pickup',
      'waiting_pickup',
      'to_destination',
      'to_stop',
      'to_return',
      'payment',
      'completed'
    )
  );

-- 3. Atomic RPC to advance to the next stop
create or replace function public.advance_booking_stop(
  p_booking_id uuid,
  p_completed_stop_index integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_booking record;
  v_stops jsonb;
  v_total_stops integer;
  v_new_index integer;
  v_stop_obj jsonb;
  v_updated_stops jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_idx integer := 0;
begin
  -- Identify the calling driver
  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
  limit 1;

  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking.id is null then
    return jsonb_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_driver_id is not null and v_booking.driver_id is distinct from v_driver_id then
    return jsonb_build_object('success', false, 'error', 'You are not assigned to this booking.');
  end if;

  v_stops := coalesce(v_booking.stops, '[]'::jsonb);
  v_total_stops := coalesce(v_booking.total_stops, jsonb_array_length(v_stops), 1);
  v_new_index := p_completed_stop_index + 1;

  -- Stamp arrived_at on the completed stop
  for v_elem in select * from jsonb_array_elements(v_stops)
  loop
    if v_idx = p_completed_stop_index then
      v_updated_stops := v_updated_stops || jsonb_build_array(
        v_elem || jsonb_build_object('arrived_at', now(), 'status', 'arrived')
      );
    else
      v_updated_stops := v_updated_stops || jsonb_build_array(v_elem);
    end if;
    v_idx := v_idx + 1;
  end loop;

  update public.bookings
  set stops = v_updated_stops,
      current_stop_index = v_new_index,
      trip_phase = case when v_new_index >= v_total_stops then 'payment' else 'to_destination' end,
      updated_at = now()
  where id = p_booking_id;

  return jsonb_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'current_stop_index', v_new_index,
    'total_stops', v_total_stops,
    'is_last_stop', v_new_index >= v_total_stops
  );
end;
$$;

grant execute on function public.advance_booking_stop(uuid, integer) to authenticated, anon;

commit;
