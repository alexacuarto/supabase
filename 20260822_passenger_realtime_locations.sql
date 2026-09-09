-- Passenger realtime GPS support for live driver/passenger maps.
-- Apply this to existing Supabase projects that already ran the final bootstrap.

begin;

create table if not exists public.passenger_locations (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  passenger_id uuid not null references public.passengers(id) on delete cascade,
  latitude double precision not null,
  longitude double precision not null,
  heading double precision,
  speed double precision,
  accuracy double precision,
  recorded_at timestamptz not null default now()
);

create index if not exists idx_passenger_locations_booking_time
  on public.passenger_locations (booking_id, recorded_at desc);

create index if not exists idx_passenger_locations_passenger_time
  on public.passenger_locations (passenger_id, recorded_at desc);

alter table public.passenger_locations enable row level security;

drop policy if exists passenger_locations_insert_own on public.passenger_locations;
drop policy if exists passenger_locations_select_booking_participants on public.passenger_locations;

create policy passenger_locations_insert_own
on public.passenger_locations for insert with check (
  passenger_id = public.current_passenger_id()
  and exists (
    select 1
    from public.bookings b
    where b.id = passenger_locations.booking_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('pending', 'searching', 'accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);

create policy passenger_locations_select_booking_participants
on public.passenger_locations for select using (
  public.is_admin()
  or passenger_id = public.current_passenger_id()
  or exists (
    select 1
    from public.bookings b
    where b.id = passenger_locations.booking_id
      and b.driver_id = public.current_driver_id()
      and b.status in ('pending', 'searching', 'accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);

do $$
begin
  alter publication supabase_realtime add table public.passenger_locations;
exception when others then null;
end $$;

commit;
