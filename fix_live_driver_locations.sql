-- Live GPS tracking support for TODA GO.
-- Run this on existing Supabase projects before testing passenger/driver live maps.

begin;

create table if not exists public.driver_locations (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  latitude double precision not null,
  longitude double precision not null,
  heading double precision,
  speed double precision,
  accuracy double precision,
  recorded_at timestamptz not null default now()
);

create index if not exists idx_driver_locations_driver_time
  on public.driver_locations(driver_id, recorded_at desc);

alter table public.driver_locations enable row level security;

create or replace function public.update_driver_current_location()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.drivers
  set current_latitude = new.latitude,
      current_longitude = new.longitude,
      last_location_update = coalesce(new.recorded_at, now()),
      updated_at = now()
  where id = new.driver_id;
  return new;
end;
$$;

drop trigger if exists after_location_insert on public.driver_locations;
create trigger after_location_insert
  after insert on public.driver_locations
  for each row execute function public.update_driver_current_location();

drop policy if exists driver_locations_insert_own on public.driver_locations;
create policy driver_locations_insert_own
on public.driver_locations
for insert
with check (driver_id = public.current_driver_id() or public.is_admin());

drop policy if exists driver_locations_select_policy on public.driver_locations;
create policy driver_locations_select_policy
on public.driver_locations
for select
using (
  driver_id = public.current_driver_id()
  or public.is_admin()
  or exists (
    select 1
    from public.bookings b
    where b.driver_id = driver_locations.driver_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);

do $$
begin
  begin
    alter publication supabase_realtime add table public.driver_locations;
  exception when others then
    null;
  end;
end $$;

commit;
