-- Fix driver accept failure:
-- PostgREST error P0001 "invalid transition from pending to accepted".
--
-- The driver app fetches available bookings with status pending, and the
-- accept_booking RPC atomically claims them by setting status = accepted.
-- Therefore pending -> accepted must be a valid transition.
--
-- Run this once in Supabase SQL Editor on an existing TodaGo database.

create or replace function public.enforce_booking_state_transitions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = new.status then
    return new;
  end if;

  if new.status = 'cancelled' then
    if old.status = 'completed' then
      raise exception 'Cannot cancel a completed booking.';
    end if;
    new.cancelled_at := coalesce(new.cancelled_at, now());
    new.updated_at := now();
    return new;
  end if;

  case old.status
    when 'pending' then
      if new.status not in ('searching', 'accepted') then
        raise exception 'Invalid transition from pending to %.', new.status;
      end if;
      if new.status = 'accepted' then
        new.accepted_at := coalesce(new.accepted_at, now());
      end if;
    when 'searching' then
      if new.status not in ('accepted') then
        raise exception 'Invalid transition from searching to %.', new.status;
      end if;
      new.accepted_at := coalesce(new.accepted_at, now());
    when 'accepted' then
      if new.status not in ('driver_arriving', 'pickedUp') then
        raise exception 'Invalid transition from accepted to %.', new.status;
      end if;
      if new.status = 'driver_arriving' then
        new.arrived_at := coalesce(new.arrived_at, now());
        new.driver_arrived_at := coalesce(new.driver_arrived_at, new.arrived_at);
      end if;
      if new.status = 'pickedUp' then
        new.picked_up_at := coalesce(new.picked_up_at, now());
      end if;
    when 'driver_arriving' then
      if new.status not in ('pickedUp') then
        raise exception 'Invalid transition from driver_arriving to %.', new.status;
      end if;
      new.picked_up_at := coalesce(new.picked_up_at, now());
    when 'pickedUp' then
      if new.status not in ('droppedOff', 'completed') then
        raise exception 'Invalid transition from pickedUp to %.', new.status;
      end if;
      if new.status = 'completed' then
        new.completed_at := coalesce(new.completed_at, now());
      end if;
    when 'droppedOff' then
      if new.status not in ('paymentSent', 'completed') then
        raise exception 'Invalid transition from droppedOff to %.', new.status;
      end if;
      if new.status = 'completed' then
        new.completed_at := coalesce(new.completed_at, now());
      end if;
    when 'paymentSent' then
      if new.status not in ('completed') then
        raise exception 'Invalid transition from paymentSent to %.', new.status;
      end if;
      new.completed_at := coalesce(new.completed_at, now());
    when 'completed' then
      raise exception 'Cannot change status of a completed booking.';
    when 'cancelled' then
      if new.status not in ('searching') then
        raise exception 'Cannot change status of a cancelled booking except retry to searching.';
      end if;
  end case;

  new.updated_at := now();
  return new;
end;
$$;
