-- ============================================================================
-- TODA GO FINAL SUPABASE BOOTSTRAP
-- ============================================================================
-- Use this on a NEW Supabase project. It replaces the historical migration
-- chain in this repository with one readable schema entry.
--
-- Apps sharing this backend:
--   - toda_go: passenger Flutter app
--   - toda_go_driver: driver Flutter app
--   - todago-admin-react: admin React dashboard
--
-- Notes:
--   - Run from the Supabase SQL editor as project owner.
--   - Create your first admin in Supabase Auth, then update public.profiles.role
--     and auth.users.raw_user_meta_data for that user to "admin".
--   - The create_driver_account RPC creates driver Auth users directly. This is
--     kept for compatibility with the current admin dashboard.
-- ============================================================================

begin;

create extension if not exists pgcrypto with schema extensions;
create extension if not exists postgis;

-- ============================================================================
-- TYPES
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type public.user_role as enum ('passenger', 'driver', 'admin');
  end if;

  if not exists (select 1 from pg_type where typname = 'driver_status') then
    create type public.driver_status as enum ('pending', 'approved', 'rejected', 'suspended', 'inactive');
  end if;

  if not exists (select 1 from pg_type where typname = 'booking_status') then
    create type public.booking_status as enum (
      'pending',
      'searching',
      'accepted',
      'driver_arriving',
      'pickedUp',
      'droppedOff',
      'paymentSent',
      'completed',
      'cancelled'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'cancellation_actor') then
    create type public.cancellation_actor as enum ('passenger', 'driver', 'system');
  end if;

  if not exists (select 1 from pg_type where typname = 'notification_type') then
    create type public.notification_type as enum ('push', 'in_app', 'sms', 'email');
  end if;

  if not exists (select 1 from pg_type where typname = 'fare_type') then
    create type public.fare_type as enum ('fixed', 'per_km', 'per_km_with_base');
  end if;
end $$;

-- ============================================================================
-- TABLES
-- ============================================================================

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.user_role not null default 'passenger',
  first_name text not null default '',
  last_name text not null default '',
  full_name text,
  email text,
  phone_number text,
  passenger_type text not null default 'Regular',
  avatar_url text,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.passengers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  default_address text,
  account_passenger_type text not null default 'Regular',
  selfie_photo_url text,
  discount_document_url text,
  discount_document_status text not null default 'NOT_REQUIRED',
  discount_document_type text,
  discount_document_rejection_reason text,
  discount_document_submitted_at timestamptz,
  discount_document_reviewed_at timestamptz,
  discount_document_reviewed_by uuid references public.profiles(id) on delete set null,
  discount_eligible boolean not null default false,
  cancel_count integer not null default 0,
  last_cancel_date timestamptz,
  booking_restriction_until timestamptz,
  warning_status boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.drivers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  license_number text not null default 'PENDING',
  license_expiry_date date,
  license_photo_url text,
  license_front_url text,
  license_back_url text,
  selfie_photo_url text,
  franchise_url text,
  franchise_back_url text,
  franchise_number text,
  franchise_expiry_date date,
  toda_association text not null default 'LHITC-TODA' check (toda_association in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA')),
  status public.driver_status not null default 'pending',
  account_status text not null default 'PENDING',
  document_status text not null default 'PENDING',
  document_issue_reason text,
  rejection_reason text,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  is_online boolean not null default false,
  current_latitude double precision,
  current_longitude double precision,
  last_location_update timestamptz,
  last_online_at timestamptz,
  total_online_minutes integer not null default 0,
  total_rides integer not null default 0,
  average_rating numeric(3,2) not null default 0,
  last_completed_ride_at timestamptz,
  admin_action_type text,
  admin_action_reason text,
  admin_action_date timestamptz,
  admin_action_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vehicle_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text,
  max_passengers integer not null default 3,
  icon_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null unique references public.drivers(id) on delete cascade,
  vehicle_type_id uuid references public.vehicle_types(id) on delete restrict,
  plate_number text not null unique,
  color text,
  model text,
  year integer,
  photo_url text,
  or_cr_photo_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.fare_configurations (
  id uuid primary key default gen_random_uuid(),
  vehicle_type_id uuid references public.vehicle_types(id) on delete cascade,
  fare_type public.fare_type not null default 'per_km_with_base',
  trip_type text not null default 'one_way',
  display_label text not null default 'One Way Trip',
  base_fare numeric(10,2) not null default 0,
  included_km numeric(8,2) not null default 0,
  succeeding_km_fare numeric(10,2) not null default 0,
  per_km_rate numeric(10,2) not null default 0,
  minimum_fare numeric(10,2) not null default 0,
  booking_fee numeric(10,2) not null default 0,
  surge_multiplier numeric(4,2) not null default 1,
  student_discount numeric(5,2) not null default 20,
  pwd_discount numeric(5,2) not null default 20,
  senior_citizen_discount numeric(5,2) not null default 20,
  is_active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_type)
);

create table if not exists public.fare_change_logs (
  id uuid primary key default gen_random_uuid(),
  fare_configuration_id uuid references public.fare_configurations(id) on delete set null,
  trip_type text not null,
  old_base_fare numeric(10,2),
  new_base_fare numeric(10,2),
  old_included_km numeric(8,2),
  new_included_km numeric(8,2),
  old_succeeding_km_fare numeric(10,2),
  new_succeeding_km_fare numeric(10,2),
  message text not null,
  changed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_number text unique,
  passenger_id uuid not null references public.passengers(id) on delete restrict,
  driver_id uuid references public.drivers(id) on delete set null,
  vehicle_type_id uuid references public.vehicle_types(id) on delete restrict,
  fare_configuration_id uuid references public.fare_configurations(id) on delete set null,
  pickup_address text not null,
  pickup_latitude double precision not null default 0,
  pickup_longitude double precision not null default 0,
  dropoff_address text not null,
  dropoff_latitude double precision not null default 0,
  dropoff_longitude double precision not null default 0,
  estimated_distance_km numeric(8,2) default 0,
  estimated_fare numeric(10,2) default 0,
  actual_distance_km numeric(8,2),
  actual_fare numeric(10,2),
  status public.booking_status not null default 'pending',
  trip_type text,
  trip_phase text not null default 'to_pickup' check (
    trip_phase in (
      'to_pickup',
      'waiting_pickup',
      'to_destination',
      'to_stop',
      'to_return',
      'payment',
      'completed'
    )
  ),
  stops jsonb not null default '[]'::jsonb,
  total_stops integer not null default 1,
  current_stop_index integer not null default 0,
  passenger_qty jsonb,
  passenger_note text,
  return_address text,
  return_latitude double precision,
  return_longitude double precision,
  discount_passenger_type text,
  discount_id_image text,
  discount_verified boolean,
  discount_rejected_reason text,
  discount_original_type text,
  passenger_type_display text,
  cancel_reason text,
  cancel_details text,
  cancellation_reason text,
  cancelled_by public.cancellation_actor,
  accepted_at timestamptz,
  arrived_at timestamptz,
  driver_arrived_at timestamptz,
  picked_up_at timestamptz,
  started_at timestamptz,
  destination_arrived_at timestamptz,
  return_arrived_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.booking_status_history (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  old_status public.booking_status,
  new_status public.booking_status not null,
  changed_by uuid references public.profiles(id) on delete set null,
  note text,
  created_at timestamptz not null default now()
);

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

create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  passenger_id uuid not null references public.passengers(id) on delete cascade,
  driver_id uuid not null references public.drivers(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  review text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  type public.notification_type not null default 'in_app',
  title text not null,
  body text not null,
  data jsonb,
  notification_category text,
  scheduled_at timestamptz,
  is_sent boolean not null default true,
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.driver_sessions (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  went_online timestamptz not null default now(),
  went_offline timestamptz,
  duration_mins integer generated always as (
    case
      when went_offline is not null
      then extract(epoch from (went_offline - went_online))::integer / 60
      else null
    end
  ) stored,
  created_at timestamptz not null default now()
);

-- Future/admin support tables retained from the original schema.
create table if not exists public.saved_places (
  id uuid primary key default gen_random_uuid(),
  passenger_id uuid not null references public.passengers(id) on delete cascade,
  label text not null,
  address text not null,
  latitude double precision not null,
  longitude double precision not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  report_type text not null,
  title text not null,
  description text,
  parameters jsonb,
  data jsonb not null default '{}'::jsonb,
  generated_by uuid references public.profiles(id) on delete set null,
  reporter_profile_id uuid references public.profiles(id) on delete set null,
  reporter_passenger_id uuid references public.passengers(id) on delete set null,
  driver_id uuid references public.drivers(id) on delete set null,
  booking_id uuid references public.bookings(id) on delete set null,
  category text,
  message text,
  status text not null default 'OPEN' check (status in ('OPEN', 'REVIEWING', 'RESOLVED', 'DISMISSED')),
  admin_notes text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  period_start date,
  period_end date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.driver_profile_change_requests (
  id uuid primary key default gen_random_uuid(),
  driver_id uuid not null references public.drivers(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  field_name text not null,
  current_value text,
  requested_value text not null,
  status text not null default 'PENDING' check (status in ('PENDING', 'APPROVED', 'REJECTED')),
  rejection_reason text,
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  token text not null,
  device_type text not null check (device_type in ('android', 'ios', 'web')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, token)
);

-- ============================================================================
-- INDEXES
-- ============================================================================

create index if not exists idx_profiles_role on public.profiles(role);
create index if not exists idx_profiles_phone on public.profiles(phone_number);
create index if not exists idx_passengers_profile on public.passengers(profile_id);
create index if not exists idx_drivers_profile on public.drivers(profile_id);
create index if not exists idx_drivers_status on public.drivers(status);
create index if not exists idx_drivers_online on public.drivers(is_online) where is_online = true;
create index if not exists idx_driver_account_status on public.drivers(account_status);
create index if not exists idx_driver_document_status on public.drivers(document_status);
create index if not exists idx_vehicles_driver on public.vehicles(driver_id);
create index if not exists idx_bookings_passenger on public.bookings(passenger_id);
create index if not exists idx_bookings_driver on public.bookings(driver_id);
create index if not exists idx_bookings_status on public.bookings(status);
create index if not exists idx_bookings_created on public.bookings(created_at desc);
create index if not exists idx_booking_status_history_booking on public.booking_status_history(booking_id, created_at desc);
create index if not exists idx_driver_locations_driver_time on public.driver_locations(driver_id, recorded_at desc);
create index if not exists idx_passenger_locations_booking_time on public.passenger_locations(booking_id, recorded_at desc);
create index if not exists idx_passenger_locations_passenger_time on public.passenger_locations(passenger_id, recorded_at desc);
create index if not exists idx_ratings_driver on public.ratings(driver_id);
create index if not exists idx_ratings_passenger on public.ratings(passenger_id);
create index if not exists idx_notifications_recipient on public.notifications(recipient_id, is_read, created_at desc);
create index if not exists idx_driver_sessions_driver on public.driver_sessions(driver_id, went_online desc);
create index if not exists idx_fare_configuration_trip_vehicle on public.fare_configurations(vehicle_type_id, trip_type);
create index if not exists idx_fare_change_logs_created on public.fare_change_logs(created_at desc);
create unique index if not exists idx_driver_change_requests_one_pending
  on public.driver_profile_change_requests(driver_id, field_name)
  where status = 'PENDING';
create index if not exists idx_driver_change_requests_status
  on public.driver_profile_change_requests(status, created_at desc);
create index if not exists idx_reports_status_created on public.reports(status, created_at desc);
create index if not exists idx_reports_reporter on public.reports(reporter_profile_id, created_at desc);
create index if not exists idx_reports_driver on public.reports(driver_id, created_at desc);

-- ============================================================================
-- STORAGE BUCKETS
-- ============================================================================

insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('discount-ids', 'discount-ids', false),
  ('driver-documents', 'driver-documents', true)
on conflict (id) do update set public = excluded.public;

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select
    coalesce((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin', false)
    or exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.role = 'admin'
        and p.is_active = true
    );
$$;

create or replace function public.current_passenger_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select p.id from public.passengers p where p.profile_id = auth.uid() limit 1;
$$;

create or replace function public.current_driver_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select d.id from public.drivers d where d.profile_id = auth.uid() limit 1;
$$;

create or replace function public.current_driver_can_view_bookings()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.drivers d
    where d.profile_id = auth.uid()
      and d.document_status = 'VERIFIED'
      and d.admin_action_type is null
      and d.is_online = true
  );
$$;

create or replace function public.passenger_can_view_driver(p_driver_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.bookings b
    where b.driver_id = p_driver_id
      and b.passenger_id = public.current_passenger_id()
  );
$$;

create or replace function public.can_view_profile(p_profile_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if p_profile_id = auth.uid() or public.is_admin() then
    return true;
  end if;

  if exists (
    select 1
    from public.drivers d
    join public.bookings b on b.driver_id = d.id
    join public.passengers p on p.id = b.passenger_id
    where d.profile_id = auth.uid()
      and p.profile_id = p_profile_id
  ) then
    return true;
  end if;

  if exists (
    select 1
    from public.passengers p
    join public.bookings b on b.passenger_id = p.id
    join public.drivers d on d.id = b.driver_id
    where p.profile_id = auth.uid()
      and d.profile_id = p_profile_id
      and b.status not in ('searching', 'pending')
  ) then
    return true;
  end if;

  if exists (
    select 1
    from public.passengers p
    join public.bookings b on b.passenger_id = p.id
    where p.profile_id = p_profile_id
      and b.status in ('searching', 'pending')
      and b.driver_id is null
  ) then
    return true;
  end if;

  return false;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role_txt text;
  v_role public.user_role;
  v_first_name text;
  v_last_name text;
  v_full_name text;
begin
  v_role_txt := coalesce(new.raw_user_meta_data->>'role', 'passenger');
  if v_role_txt not in ('passenger', 'driver', 'admin') then
    v_role_txt := 'passenger';
  end if;
  v_role := v_role_txt::public.user_role;

  v_first_name := coalesce(new.raw_user_meta_data->>'first_name', '');
  v_last_name := coalesce(new.raw_user_meta_data->>'last_name', '');
  v_full_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', concat_ws(' ', v_first_name, v_last_name))), '');

  insert into public.profiles (id, role, first_name, last_name, full_name, phone_number, email)
  values (
    new.id,
    v_role,
    v_first_name,
    v_last_name,
    v_full_name,
    coalesce(new.raw_user_meta_data->>'phone_number', new.phone),
    new.email
  )
  on conflict (id) do update set
    role = excluded.role,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    updated_at = now();

  if v_role = 'passenger' then
    insert into public.passengers (id, profile_id)
    values (new.id, new.id)
    on conflict (profile_id) do nothing;
  end if;

  return new;
end;
$$;

create or replace function public.fn_update_driver_status()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();

  if (
    coalesce(new.license_front_url, '') <> ''
    and coalesce(new.license_back_url, '') <> ''
    and coalesce(new.license_number, '') not in ('', 'PENDING')
    and new.license_expiry_date is not null
    and coalesce(new.franchise_url, '') <> ''
    and coalesce(new.franchise_number, '') <> ''
    and new.franchise_expiry_date is not null
    and coalesce(new.toda_association, '') not in ('', 'Not provided')
  ) then
    if new.license_expiry_date < (timezone('Asia/Manila', now()))::date
       and new.franchise_expiry_date < (timezone('Asia/Manila', now()))::date then
      new.document_status := 'PENDING';
      new.document_issue_reason := 'Driver License and Franchise expired';
    elsif new.license_expiry_date < (timezone('Asia/Manila', now()))::date then
      new.document_status := 'PENDING';
      new.document_issue_reason := 'Driver License expired';
    elsif new.franchise_expiry_date < (timezone('Asia/Manila', now()))::date then
      new.document_status := 'PENDING';
      new.document_issue_reason := 'Franchise/Prangkisa expired';
    else
      new.document_status := 'VERIFIED';
      new.document_issue_reason := null;
    end if;
  else
    new.document_status := 'PENDING';
    new.document_issue_reason := 'Required documents missing';
  end if;

  if new.admin_action_type in ('suspended', 'deleted_requested') then
    new.status := 'inactive';
    new.account_status := 'SUSPENDED';
    new.is_online := false;
  elsif new.document_status = 'VERIFIED' then
    new.status := 'approved';
    new.account_status := 'ACTIVE';
  else
    new.status := 'pending';
    new.account_status := 'PENDING';
    new.is_online := false;
  end if;

  return new;
end;
$$;

create sequence if not exists public.booking_number_seq;

create or replace function public.generate_booking_number()
returns trigger
language plpgsql
as $$
declare
  sequence_value bigint;
begin
  if new.booking_number is not null then
    return new;
  end if;

  sequence_value := nextval('public.booking_number_seq');

  new.booking_number :=
    'TG-' ||
    to_char(coalesce(new.created_at, now()) at time zone 'Asia/Manila', 'YYYYMMDD') ||
    '-' ||
    lpad(sequence_value::text, 6, '0');
  return new;
end;
$$;

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

create or replace function public.log_booking_status_change()
returns trigger
language plpgsql
as $$
begin
  if old.status is distinct from new.status then
    insert into public.booking_status_history (booking_id, old_status, new_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return new;
end;
$$;

create or replace function public.sync_driver_current_location()
returns trigger
language plpgsql
as $$
begin
  update public.drivers
  set current_latitude = new.latitude,
      current_longitude = new.longitude,
      last_location_update = new.recorded_at
  where id = new.driver_id;
  return new;
end;
$$;

create or replace function public.update_driver_rating()
returns trigger
language plpgsql
as $$
declare
  v_driver_id uuid;
begin
  v_driver_id := coalesce(new.driver_id, old.driver_id);

  update public.drivers
  set average_rating = coalesce((
        select round(avg(r.rating)::numeric, 2)
        from public.ratings r
        where r.driver_id = v_driver_id
      ), 0),
      total_rides = (
        select count(*)
        from public.bookings b
        where b.driver_id = v_driver_id
          and b.status = 'completed'
      )
  where id = v_driver_id;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.review_driver_profile_change_request(
  p_request_id uuid,
  p_status text,
  p_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.driver_profile_change_requests%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only admins can review driver profile change requests.';
  end if;

  if p_status not in ('APPROVED', 'REJECTED') then
    raise exception 'Status must be APPROVED or REJECTED.';
  end if;

  select * into v_request
  from public.driver_profile_change_requests
  where id = p_request_id
  for update;

  if v_request.id is null then
    raise exception 'Driver profile change request not found.';
  end if;

  if v_request.status <> 'PENDING' then
    raise exception 'This request has already been reviewed.';
  end if;

  if p_status = 'APPROVED' then
    if v_request.field_name = 'full_name' then
      update public.profiles
      set first_name = split_part(v_request.requested_value, ' ', 1),
          last_name = nullif(trim(substr(v_request.requested_value, length(split_part(v_request.requested_value, ' ', 1)) + 1)), ''),
          updated_at = now()
      where id = v_request.profile_id;
    elsif v_request.field_name in ('first_name', 'last_name', 'phone_number', 'email', 'address') then
      execute format('update public.profiles set %I = $1, updated_at = now() where id = $2', v_request.field_name)
      using v_request.requested_value, v_request.profile_id;
    elsif v_request.field_name in ('license_number', 'toda_association', 'license_expiry_date', 'franchise_number', 'franchise_expiry_date', 'license_front_url', 'license_back_url', 'franchise_url', 'franchise_back_url') then
      execute format('update public.drivers set %I = $1, updated_at = now() where id = $2', v_request.field_name)
      using v_request.requested_value, v_request.driver_id;
    elsif v_request.field_name = 'toda' then
      update public.drivers
      set toda_association = v_request.requested_value,
          updated_at = now()
      where id = v_request.driver_id;
    elsif v_request.field_name in ('plate_number', 'plate') then
      update public.vehicles
      set plate_number = v_request.requested_value,
          updated_at = now()
      where driver_id = v_request.driver_id;
    else
      raise exception 'Unsupported change request field: %', v_request.field_name;
    end if;
  end if;

  update public.driver_profile_change_requests
  set status = p_status,
      rejection_reason = case when p_status = 'REJECTED' then nullif(trim(coalesce(p_reason, '')), '') else null end,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_request_id;

  insert into public.notifications (recipient_id, title, body, notification_category, data)
  values (
    v_request.profile_id,
    case when p_status = 'APPROVED' then 'Profile update approved' else 'Profile update rejected' end,
    case
      when p_status = 'APPROVED' then format('Your %s update request was approved.', replace(v_request.field_name, '_', ' '))
      else format('Your %s update request was rejected.%s', replace(v_request.field_name, '_', ' '), case when nullif(trim(coalesce(p_reason, '')), '') is null then '' else ' Reason: ' || trim(p_reason) end)
    end,
    'driver_profile_change_request',
    jsonb_build_object('request_id', p_request_id, 'field_name', v_request.field_name, 'status', p_status)
  );

  return json_build_object('success', true, 'status', p_status);
end;
$$;

create or replace function public.set_driver_online_status(p_is_online boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver public.drivers%rowtype;
  v_open_session public.driver_sessions%rowtype;
  v_now timestamptz := now();
  v_added_minutes integer := 0;
begin
  select * into v_driver
  from public.drivers
  where profile_id = auth.uid()
  for update;

  if v_driver.id is null then
    raise exception 'No driver record found for current user.';
  end if;

  if p_is_online then
    -- Auto-close any lingering/stale session older than 24 hours
    update public.driver_sessions
    set went_offline = went_online + interval '30 minutes'
    where driver_id = v_driver.id
      and went_offline is null
      and went_online < v_now - interval '24 hours';

    -- Find or create open session
    select * into v_open_session
    from public.driver_sessions
    where driver_id = v_driver.id and went_offline is null
    order by went_online desc
    limit 1;

    if v_open_session.id is null then
      insert into public.driver_sessions (driver_id, went_online)
      values (v_driver.id, v_now)
      returning * into v_open_session;
    end if;

    -- Ensure last_online_at in drivers table is identical to session start
    update public.drivers
    set is_online = true,
        last_online_at = v_open_session.went_online,
        updated_at = v_now
    where id = v_driver.id;
  else
    -- Going offline: close active session and compute elapsed minutes
    select * into v_open_session
    from public.driver_sessions
    where driver_id = v_driver.id and went_offline is null
    order by went_online desc
    limit 1
    for update;

    if v_open_session.id is not null then
      v_added_minutes := greatest(0, floor(extract(epoch from (v_now - v_open_session.went_online)) / 60)::integer);
      update public.driver_sessions
      set went_offline = v_now
      where id = v_open_session.id;
    end if;

    -- Ensure all open sessions for this driver are closed
    update public.driver_sessions
    set went_offline = v_now
    where driver_id = v_driver.id and went_offline is null;

    update public.drivers
    set is_online = false,
        last_online_at = null,
        total_online_minutes = coalesce(total_online_minutes, 0) + v_added_minutes,
        updated_at = v_now
    where id = v_driver.id;
  end if;

  return json_build_object(
    'success', true,
    'driver_id', v_driver.id,
    'is_online', p_is_online,
    'added_minutes', v_added_minutes
  );
end;
$$;

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
create or replace function public.admin_restrict_passenger(
  p_passenger_id uuid,
  p_days int default 31
)
returns void
language plpgsql
security definer
set search_path = public
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

create or replace function public.admin_lift_passenger_restriction(
  p_passenger_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
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

  update public.profiles
  set is_active = true,
      updated_at = now()
  where id = coalesce(v_profile_id, p_passenger_id);
end;
$$;

create or replace function public.update_fare_configuration_with_message(
  p_trip_type text,
  p_display_label text,
  p_base_fare numeric,
  p_included_km numeric,
  p_succeeding_km_fare numeric,
  p_student_discount numeric,
  p_pwd_discount numeric,
  p_senior_citizen_discount numeric,
  p_message text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing public.fare_configurations%rowtype;
  v_log_id uuid;
  v_change_lines text[] := array[]::text[];
  v_notification_body text;
begin
  if not public.is_admin() then
    raise exception 'Only admins can change fare settings.';
  end if;

  if nullif(trim(coalesce(p_message, '')), '') is null then
    raise exception 'A fare change message is required.';
  end if;

  select *
  into v_existing
  from public.fare_configurations
  where trip_type = p_trip_type
  for update;

  if not found then
    raise exception 'Fare configuration for trip type % was not found.', p_trip_type;
  end if;

  if v_existing.display_label is distinct from p_display_label then
    v_change_lines := array_append(v_change_lines, format('Label: %s -> %s', v_existing.display_label, p_display_label));
  end if;
  if v_existing.base_fare is distinct from p_base_fare then
    v_change_lines := array_append(v_change_lines, format('Base fare: PHP %s -> PHP %s', to_char(v_existing.base_fare, 'FM999999990.00'), to_char(p_base_fare, 'FM999999990.00')));
  end if;
  if v_existing.included_km is distinct from p_included_km then
    v_change_lines := array_append(v_change_lines, format('Included KM: %s km -> %s km', to_char(v_existing.included_km, 'FM999999990.00'), to_char(p_included_km, 'FM999999990.00')));
  end if;
  if v_existing.succeeding_km_fare is distinct from p_succeeding_km_fare then
    v_change_lines := array_append(v_change_lines, format('Succeeding KM fare: PHP %s -> PHP %s', to_char(v_existing.succeeding_km_fare, 'FM999999990.00'), to_char(p_succeeding_km_fare, 'FM999999990.00')));
  end if;
  if v_existing.student_discount is distinct from p_student_discount then
    v_change_lines := array_append(v_change_lines, format('Student discount: %s%% -> %s%%', to_char(v_existing.student_discount, 'FM999999990.00'), to_char(p_student_discount, 'FM999999990.00')));
  end if;
  if v_existing.pwd_discount is distinct from p_pwd_discount then
    v_change_lines := array_append(v_change_lines, format('PWD discount: %s%% -> %s%%', to_char(v_existing.pwd_discount, 'FM999999990.00'), to_char(p_pwd_discount, 'FM999999990.00')));
  end if;
  if v_existing.senior_citizen_discount is distinct from p_senior_citizen_discount then
    v_change_lines := array_append(v_change_lines, format('Senior Citizen discount: %s%% -> %s%%', to_char(v_existing.senior_citizen_discount, 'FM999999990.00'), to_char(p_senior_citizen_discount, 'FM999999990.00')));
  end if;

  v_notification_body := trim(p_message) || E'\n\nChanges made:\n' ||
    case
      when array_length(v_change_lines, 1) is null then 'No fare values changed.'
      else array_to_string(v_change_lines, E'\n')
    end;

  update public.fare_configurations
  set display_label = p_display_label,
      base_fare = p_base_fare,
      included_km = p_included_km,
      succeeding_km_fare = p_succeeding_km_fare,
      student_discount = p_student_discount,
      pwd_discount = p_pwd_discount,
      senior_citizen_discount = p_senior_citizen_discount,
      updated_at = now()
  where id = v_existing.id;

  insert into public.fare_change_logs (
    fare_configuration_id,
    trip_type,
    old_base_fare,
    new_base_fare,
    old_included_km,
    new_included_km,
    old_succeeding_km_fare,
    new_succeeding_km_fare,
    message,
    changed_by
  )
  values (
    v_existing.id,
    p_trip_type,
    v_existing.base_fare,
    p_base_fare,
    v_existing.included_km,
    p_included_km,
    v_existing.succeeding_km_fare,
    p_succeeding_km_fare,
    trim(p_message),
    auth.uid()
  )
  returning id into v_log_id;

  insert into public.notifications (
    recipient_id,
    type,
    title,
    body,
    data,
    notification_category
  )
  select
    p.id,
    'in_app',
    'Fare Update',
    v_notification_body,
    jsonb_build_object(
      'fare_change_log_id', v_log_id,
      'trip_type', p_trip_type,
      'changes', coalesce(to_jsonb(v_change_lines), '[]'::jsonb)
    ),
    'fare_adjustment'
  from public.profiles p
  where p.role in ('passenger', 'driver')
    and p.is_active = true;

  return jsonb_build_object('success', true, 'fare_change_log_id', v_log_id);
end;
$$;

create or replace function public.review_passenger_discount_document(
  p_passenger_id uuid,
  p_status text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_passenger public.passengers%rowtype;
  v_title text;
  v_body text;
begin
  if not public.is_admin() then
    raise exception 'Only admins can review passenger verification IDs.';
  end if;

  if p_status not in ('VERIFIED', 'REJECTED') then
    raise exception 'Verification review status must be VERIFIED or REJECTED.';
  end if;

  select *
  into v_passenger
  from public.passengers
  where id = p_passenger_id
  for update;

  if not found then
    raise exception 'Passenger was not found.';
  end if;

  update public.passengers
  set discount_document_status = p_status,
      discount_document_rejection_reason = case when p_status = 'REJECTED' then nullif(trim(coalesce(p_reason, '')), '') else null end,
      discount_document_reviewed_at = now(),
      discount_document_reviewed_by = auth.uid(),
      discount_eligible = false,
      updated_at = now()
  where id = p_passenger_id;

  update public.profiles
  set is_active = p_status = 'VERIFIED',
      updated_at = now()
  where id = v_passenger.profile_id;

  v_title := case when p_status = 'VERIFIED' then 'ID Verification Approved' else 'ID Verification Rejected' end;
  v_body := case
    when p_status = 'VERIFIED' then 'Your ID has been approved. You can now access TODA Go.'
    else coalesce(nullif(trim(p_reason), ''), 'Your ID was not approved. Please upload a clear valid ID.')
  end;

  insert into public.notifications (
    recipient_id,
    type,
    title,
    body,
    data,
    notification_category
  )
  values (
    v_passenger.profile_id,
    'in_app',
    v_title,
    v_body,
    jsonb_build_object('passenger_id', p_passenger_id, 'discount_document_status', p_status),
    'account'
  );

  return jsonb_build_object('success', true, 'status', p_status);
end;
$$;

create or replace function public.confirm_user_email(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = auth, public
as $$
begin
  update auth.users
  set email_confirmed_at = coalesce(email_confirmed_at, now()),
      phone_confirmed_at = coalesce(phone_confirmed_at, now()),
      updated_at = now()
  where id = p_user_id;
end;
$$;

create or replace function public.check_email_exists(p_email text)
returns boolean
language sql
security definer
set search_path = auth, public
stable
as $$
  select exists (
    select 1
    from auth.users u
    where lower(u.email) = lower(p_email)
  );
$$;

create or replace function public.get_email_by_phone(
  p_phone text,
  p_role text default 'passenger'
)
returns text
language sql
security definer
set search_path = auth, public
stable
as $$
  select u.email
  from auth.users u
  join public.profiles p on p.id = u.id
  where p.phone_number = p_phone
    and p.role = p_role::public.user_role
  limit 1;
$$;

create or replace function public.accept_booking(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_booking_status text;
  v_current_driver_id uuid;
begin
  select id
  into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
    and status = 'approved'
    and document_status = 'VERIFIED'
    and admin_action_type is null
  limit 1;

  if v_driver_id is null then
    return json_build_object('success', false, 'error', 'You are not registered as an approved driver.');
  end if;

  select status::text, driver_id
  into v_booking_status, v_current_driver_id
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking_status is null then
    return json_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_booking_status not in ('pending', 'searching') or v_current_driver_id is not null then
    return json_build_object('success', false, 'error', 'This ride is no longer available.');
  end if;

  update public.bookings
  set driver_id = v_driver_id,
      status = 'accepted',
      trip_phase = 'to_pickup',
      accepted_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object('success', true, 'driver_id', v_driver_id, 'booking_id', p_booking_id, 'status', 'accepted');
end;
$$;

create or replace function public.complete_booking(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_booking record;
begin
  select id
  into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
    and status = 'approved'
  limit 1;

  if v_driver_id is null then
    return json_build_object('success', false, 'error', 'You are not registered as an approved driver.');
  end if;

  select *
  into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking is null then
    return json_build_object('success', false, 'error', 'Booking not found.');
  end if;

  if v_booking.driver_id != v_driver_id then
    return json_build_object('success', false, 'error', 'This booking is not assigned to you.');
  end if;

  if v_booking.status::text not in ('pickedUp', 'droppedOff', 'paymentSent') then
    return json_build_object('success', false, 'error', 'Booking cannot be completed from current status: ' || v_booking.status::text);
  end if;

  if lower(coalesce(v_booking.trip_type, '')) like '%round%'
     and v_booking.trip_phase <> 'payment' then
    return json_build_object('success', false, 'error', 'Round trip cannot be completed before arriving at the return location.');
  end if;

  -- Determine final settled fare (final_fare takes highest precedence, then actual_fare, then regular_fare if rejected, then estimated_fare)
  declare
    v_final_fare numeric;
  begin
    v_final_fare := coalesce(
      v_booking.final_fare,
      v_booking.actual_fare,
      case when v_booking.discount_review_status = 'REJECTED' or v_booking.discount_verified = false then v_booking.regular_fare else null end,
      v_booking.estimated_fare,
      0
    );

    update public.bookings
    set status = 'completed',
        trip_phase = 'completed',
        final_fare = v_final_fare,
        actual_fare = v_final_fare,
        completed_at = now(),
        updated_at = now()
    where id = p_booking_id;

    update public.drivers
    set last_completed_ride_at = now()
    where id = v_driver_id;

    return json_build_object('success', true, 'booking_id', p_booking_id, 'status', 'completed', 'fare', v_final_fare);
  end;
end;
$$;

create or replace function public.create_driver_account(
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text,
  p_phone text,
  p_plate_number text,
  p_toda_association text default 'LHITC-TODA'
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
  v_driver_id uuid;
  v_type_id uuid;
  v_existing_profile_role public.user_role;
  v_clean_toda text;
begin
  if (auth.jwt() -> 'user_metadata' ->> 'role') is distinct from 'admin'
     and not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only admins can create driver accounts.');
  end if;

  v_clean_toda := coalesce(nullif(trim(p_toda_association), ''), 'LHITC-TODA');
  if v_clean_toda not in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') then
    v_clean_toda := 'LHITC-TODA';
  end if;

  select id into v_user_id from auth.users where email = p_email;
  if v_user_id is not null then
    select role into v_existing_profile_role from public.profiles where id = v_user_id;
    if exists (select 1 from public.drivers where profile_id = v_user_id and document_status = 'VERIFIED') then
      return json_build_object('success', false, 'error', 'Driver account already exists.');
    elsif v_existing_profile_role = 'passenger' then
      return json_build_object('success', false, 'error', 'This email is already registered as a passenger account.');
    end if;
  end if;

  if p_phone is not null and p_phone <> '' and exists (
    select 1
    from public.profiles
    where phone_number = p_phone
      and (v_user_id is null or id <> v_user_id)
      and role = 'passenger'
  ) then
    return json_build_object('success', false, 'error', 'This phone number is already registered as a passenger account.');
  end if;

  if exists (
    select 1
    from public.vehicles v
    join public.drivers d on d.id = v.driver_id
    where v.plate_number = p_plate_number
      and (v_user_id is null or d.profile_id <> v_user_id)
  ) then
    return json_build_object('success', false, 'error', 'Plate number already registered to another driver.');
  end if;

  if v_user_id is null then
    v_user_id := gen_random_uuid();

    insert into auth.users (
      id, instance_id, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      aud, role, phone, phone_confirmed_at,
      confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current,
      phone_change_token, reauthentication_token
    ) values (
      v_user_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      p_email,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      json_build_object('first_name', p_first_name, 'last_name', p_last_name, 'phone_number', p_phone, 'role', 'driver')::jsonb,
      now(), now(),
      'authenticated', 'authenticated', p_phone, now(),
      '', '', '', '', '', '', ''
    );

    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (
      v_user_id,
      v_user_id,
      p_email,
      'email',
      json_build_object('sub', v_user_id::text, 'email', p_email)::jsonb,
      now(), now(), now()
    )
    on conflict do nothing;
  end if;

  insert into public.profiles (id, first_name, last_name, full_name, phone_number, role, email)
  values (v_user_id, p_first_name, p_last_name, nullif(trim(concat_ws(' ', p_first_name, p_last_name)), ''), p_phone, 'driver', p_email)
  on conflict (id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    role = 'driver',
    updated_at = now();

  insert into public.drivers (profile_id, license_number, status, approved_at, toda_association)
  values (v_user_id, 'PENDING', 'approved', now(), v_clean_toda)
  on conflict (profile_id) do update set
    approved_at = coalesce(public.drivers.approved_at, now()),
    toda_association = coalesce(nullif(trim(excluded.toda_association), ''), public.drivers.toda_association, v_clean_toda),
    updated_at = now()
  returning id into v_driver_id;

  select id into v_type_id from public.vehicle_types where is_active = true order by created_at limit 1;

  if v_type_id is not null and v_driver_id is not null then
  insert into public.vehicles (driver_id, vehicle_type_id, plate_number)
  values (v_driver_id, v_type_id, p_plate_number)
  on conflict (driver_id) do update set
    vehicle_type_id = excluded.vehicle_type_id,
    plate_number = excluded.plate_number,
    updated_at = now();
  end if;

  return json_build_object('success', true, 'driver_id', v_driver_id, 'user_id', v_user_id, 'toda_association', v_clean_toda);
end;
$$;

create or replace function public.update_driver_toda_association(
  p_driver_id uuid,
  p_toda_association text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_clean_toda text;
  v_driver public.drivers%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can update driver TODA associations.';
  end if;

  v_clean_toda := trim(coalesce(p_toda_association, ''));
  if v_clean_toda not in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') then
    raise exception 'Invalid TODA association. Must be LHITC-TODA, BYPASS ILAYANG BAGUIO-TODA, or CHOT-TODA.';
  end if;

  update public.drivers
  set toda_association = v_clean_toda,
      updated_at = now()
  where id = p_driver_id
  returning * into v_driver;

  if not found then
    raise exception 'Driver with ID % was not found.', p_driver_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'driver_id', p_driver_id,
    'toda_association', v_clean_toda
  );
end;
$$;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

drop trigger if exists trigger_update_driver_status on public.drivers;
create trigger trigger_update_driver_status
  before insert or update on public.drivers
  for each row execute function public.fn_update_driver_status();

drop trigger if exists before_booking_insert on public.bookings;
create trigger before_booking_insert
  before insert on public.bookings
  for each row execute function public.generate_booking_number();

drop trigger if exists bookings_state_transition_trg on public.bookings;
create trigger bookings_state_transition_trg
  before update of status on public.bookings
  for each row execute function public.enforce_booking_state_transitions();

drop trigger if exists after_booking_status_update on public.bookings;
create trigger after_booking_status_update
  after update of status on public.bookings
  for each row execute function public.log_booking_status_change();

drop trigger if exists after_booking_cancel_update on public.bookings;
create trigger after_booking_cancel_update
  after insert or update of status, cancelled_by, passenger_id or delete on public.bookings
  for each row execute function public.update_passenger_cancel_stats();

drop trigger if exists after_location_insert on public.driver_locations;
create trigger after_location_insert
  after insert on public.driver_locations
  for each row execute function public.sync_driver_current_location();

drop trigger if exists after_rating_insert on public.ratings;
drop trigger if exists after_rating_change on public.ratings;
create trigger after_rating_change
  after insert or update or delete on public.ratings
  for each row execute function public.update_driver_rating();

do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'passengers', 'drivers', 'vehicle_types', 'vehicles',
    'fare_configurations', 'ratings', 'saved_places', 'reports',
    'push_tokens', 'driver_profile_change_requests'
  ]
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.handle_updated_at()', t);
  end loop;
end $$;

-- ============================================================================
-- RLS
-- ============================================================================

alter table public.profiles enable row level security;
alter table public.passengers enable row level security;
alter table public.drivers enable row level security;
alter table public.vehicle_types enable row level security;
alter table public.vehicles enable row level security;
alter table public.fare_configurations enable row level security;
alter table public.fare_change_logs enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_status_history enable row level security;
alter table public.driver_locations enable row level security;
alter table public.passenger_locations enable row level security;
alter table public.ratings enable row level security;
alter table public.notifications enable row level security;
alter table public.driver_sessions enable row level security;
alter table public.saved_places enable row level security;
alter table public.reports enable row level security;
alter table public.driver_profile_change_requests enable row level security;
alter table public.push_tokens enable row level security;

create policy profiles_select_policy on public.profiles for select using (public.can_view_profile(id));
create policy profiles_insert_own on public.profiles for insert with check (id = auth.uid());
create policy profiles_update_own on public.profiles for update using (id = auth.uid() or public.is_admin());

create policy passengers_select_policy on public.passengers for select using (
  profile_id = auth.uid()
  or public.is_admin()
  or exists (
    select 1 from public.bookings b
    where b.passenger_id = passengers.id
      and ((b.status in ('searching', 'pending') and b.driver_id is null) or b.driver_id = public.current_driver_id())
  )
);
create policy passengers_insert_own on public.passengers for insert with check (profile_id = auth.uid() or public.is_admin());
create policy passengers_update_own on public.passengers for update using (profile_id = auth.uid() or public.is_admin());

create policy drivers_select_policy on public.drivers for select using (
  profile_id = auth.uid()
  or public.is_admin()
  or public.passenger_can_view_driver(id)
  or (document_status = 'VERIFIED' and admin_action_type is null and is_online = true)
);
create policy drivers_insert_own on public.drivers for insert with check (profile_id = auth.uid() or public.is_admin());
create policy drivers_update_own on public.drivers for update using (profile_id = auth.uid() or public.is_admin());

create policy vehicle_types_select_all on public.vehicle_types for select using (true);
create policy vehicle_types_admin_all on public.vehicle_types for all using (public.is_admin()) with check (public.is_admin());

create policy vehicles_select_policy on public.vehicles for select using (
  driver_id = public.current_driver_id()
  or public.is_admin()
  or exists (
    select 1 from public.bookings b
    where b.driver_id = vehicles.driver_id
      and b.passenger_id = public.current_passenger_id()
  )
);
create policy vehicles_write_policy on public.vehicles for all using (
  driver_id = public.current_driver_id() or public.is_admin()
) with check (
  driver_id = public.current_driver_id() or public.is_admin()
);

create policy fare_config_select_all on public.fare_configurations for select using (true);
create policy fare_config_admin_all on public.fare_configurations for all using (public.is_admin()) with check (public.is_admin());
create policy fare_change_logs_admin_select on public.fare_change_logs for select using (public.is_admin());

create policy bookings_insert_passenger on public.bookings for insert with check (
  passenger_id = public.current_passenger_id() or public.is_admin()
);
create policy bookings_select_policy on public.bookings for select using (
  passenger_id = public.current_passenger_id()
  or driver_id = public.current_driver_id()
  or public.is_admin()
  or (status in ('searching', 'pending') and driver_id is null and public.current_driver_can_view_bookings())
);
create policy bookings_update_policy on public.bookings for update using (
  passenger_id = public.current_passenger_id()
  or driver_id = public.current_driver_id()
  or public.is_admin()
  or (status in ('searching', 'pending') and driver_id is null and public.current_driver_can_view_bookings())
);
create policy bookings_delete_admin on public.bookings for delete using (public.is_admin());

create policy booking_status_history_select_policy on public.booking_status_history for select using (
  public.is_admin()
  or exists (
    select 1
    from public.bookings b
    where b.id = booking_status_history.booking_id
      and (b.passenger_id = public.current_passenger_id() or b.driver_id = public.current_driver_id())
  )
);
create policy booking_status_history_insert_authenticated on public.booking_status_history for insert with check (auth.uid() is not null);

create policy driver_locations_insert_own on public.driver_locations for insert with check (driver_id = public.current_driver_id() or public.is_admin());
create policy driver_locations_select_policy on public.driver_locations for select using (
  driver_id = public.current_driver_id()
  or public.is_admin()
  or exists (
    select 1 from public.bookings b
    where b.driver_id = driver_locations.driver_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('pending', 'searching', 'accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);

create policy passenger_locations_insert_own on public.passenger_locations for insert with check (
  passenger_id = public.current_passenger_id()
  and exists (
    select 1 from public.bookings b
    where b.id = passenger_locations.booking_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('pending', 'searching', 'accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);
create policy passenger_locations_select_booking_participants on public.passenger_locations for select using (
  public.is_admin()
  or passenger_id = public.current_passenger_id()
  or exists (
    select 1 from public.bookings b
    where b.id = passenger_locations.booking_id
      and b.driver_id = public.current_driver_id()
      and b.status in ('pending', 'searching', 'accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent')
  )
);

create policy ratings_select_policy on public.ratings for select using (
  passenger_id = public.current_passenger_id()
  or driver_id = public.current_driver_id()
  or public.is_admin()
  or exists (
    select 1
    from public.bookings b
    where b.driver_id = ratings.driver_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('accepted', 'driver_arriving', 'pickedUp', 'droppedOff', 'paymentSent', 'completed')
  )
);
create policy ratings_insert_passenger on public.ratings for insert with check (passenger_id = public.current_passenger_id());

create policy notifications_select_own on public.notifications for select using (recipient_id = auth.uid() or public.is_admin());
create policy notifications_update_own on public.notifications for update using (recipient_id = auth.uid() or public.is_admin());
create policy notifications_insert_authenticated on public.notifications for insert with check (auth.uid() is not null);
create policy notifications_delete_admin on public.notifications for delete using (public.is_admin());

create policy driver_sessions_select_policy on public.driver_sessions for select using (driver_id = public.current_driver_id() or public.is_admin());
create policy driver_sessions_insert_own on public.driver_sessions for insert with check (driver_id = public.current_driver_id() or public.is_admin());
create policy driver_sessions_update_own on public.driver_sessions for update using (driver_id = public.current_driver_id() or public.is_admin());

create policy saved_places_owner_all on public.saved_places for all using (
  passenger_id = public.current_passenger_id() or public.is_admin()
) with check (
  passenger_id = public.current_passenger_id() or public.is_admin()
);

create policy reports_select_own_or_admin on public.reports for select using (
  public.is_admin() or reporter_profile_id = auth.uid()
);
create policy reports_insert_passenger on public.reports for insert with check (
  reporter_profile_id = auth.uid()
  and (
    reporter_passenger_id is null
    or reporter_passenger_id = public.current_passenger_id()
  )
);
create policy reports_update_admin on public.reports for update using (public.is_admin()) with check (public.is_admin());

create policy driver_change_requests_select on public.driver_profile_change_requests for select using (
  profile_id = auth.uid() or public.is_admin()
);
create policy driver_change_requests_insert_own on public.driver_profile_change_requests for insert with check (
  profile_id = auth.uid()
  and driver_id = public.current_driver_id()
  and status = 'PENDING'
);
create policy driver_change_requests_update_admin on public.driver_profile_change_requests for update using (public.is_admin())
with check (public.is_admin());

create policy push_tokens_owner_all on public.push_tokens for all using (
  profile_id = auth.uid() or public.is_admin()
) with check (
  profile_id = auth.uid() or public.is_admin()
);

-- Storage policies.
create policy avatars_public_read on storage.objects for select using (bucket_id = 'avatars');
create policy avatars_owner_insert on storage.objects for insert with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
create policy avatars_owner_update on storage.objects for update using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
create policy avatars_owner_delete on storage.objects for delete using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);

create policy discount_ids_owner_read on storage.objects for select using (
  bucket_id = 'discount-ids' and (auth.uid()::text = (storage.foldername(name))[1] or public.is_admin())
);
create policy discount_ids_owner_insert on storage.objects for insert with check (
  bucket_id = 'discount-ids' and auth.uid()::text = (storage.foldername(name))[1]
);
create policy discount_ids_owner_update on storage.objects for update using (
  bucket_id = 'discount-ids' and auth.uid()::text = (storage.foldername(name))[1]
);
create policy discount_ids_owner_delete on storage.objects for delete using (
  bucket_id = 'discount-ids' and (auth.uid()::text = (storage.foldername(name))[1] or public.is_admin())
);

create policy driver_documents_public_read on storage.objects for select using (bucket_id = 'driver-documents');
create policy driver_documents_authenticated_insert on storage.objects for insert with check (bucket_id = 'driver-documents' and auth.uid() is not null);
create policy driver_documents_owner_update on storage.objects for update using (bucket_id = 'driver-documents' and auth.uid() is not null);
create policy driver_documents_owner_delete on storage.objects for delete using (bucket_id = 'driver-documents' and (auth.uid() is not null or public.is_admin()));

-- ============================================================================
-- REALTIME
-- ============================================================================

do $$
begin
  begin alter publication supabase_realtime add table public.bookings; exception when others then null; end;
  begin alter publication supabase_realtime add table public.drivers; exception when others then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when others then null; end;
  begin alter publication supabase_realtime add table public.passengers; exception when others then null; end;
  begin alter publication supabase_realtime add table public.vehicles; exception when others then null; end;
  begin alter publication supabase_realtime add table public.vehicle_types; exception when others then null; end;
  begin alter publication supabase_realtime add table public.fare_configurations; exception when others then null; end;
  begin alter publication supabase_realtime add table public.driver_locations; exception when others then null; end;
  begin alter publication supabase_realtime add table public.passenger_locations; exception when others then null; end;
  begin alter publication supabase_realtime add table public.notifications; exception when others then null; end;
  begin alter publication supabase_realtime add table public.driver_profile_change_requests; exception when others then null; end;
  begin alter publication supabase_realtime add table public.reports; exception when others then null; end;
end $$;

-- ============================================================================
-- SEED DATA
-- ============================================================================

insert into public.vehicle_types (name, description, max_passengers, is_active)
values ('Tricycle', 'Standard Tayabas tricycle', 3, true)
on conflict (name) do update set
  description = excluded.description,
  max_passengers = excluded.max_passengers,
  is_active = true,
  updated_at = now();

insert into public.fare_configurations (
  vehicle_type_id, trip_type, display_label, base_fare, included_km,
  succeeding_km_fare, student_discount, pwd_discount, senior_citizen_discount,
  is_active
)
select id, 'one_way', 'One Way Trip', 25, 1, 2, 20, 20, 20, true
from public.vehicle_types
where lower(name) = 'tricycle'
on conflict (trip_type) do update set
  vehicle_type_id = excluded.vehicle_type_id,
  display_label = excluded.display_label,
  base_fare = excluded.base_fare,
  included_km = excluded.included_km,
  succeeding_km_fare = excluded.succeeding_km_fare,
  student_discount = excluded.student_discount,
  pwd_discount = excluded.pwd_discount,
  senior_citizen_discount = excluded.senior_citizen_discount,
  is_active = true,
  updated_at = now();

insert into public.fare_configurations (
  vehicle_type_id, trip_type, display_label, base_fare, included_km,
  succeeding_km_fare, student_discount, pwd_discount, senior_citizen_discount,
  is_active
)
select id, 'round_trip', 'Round Trip', 40, 2, 2, 20, 20, 20, true
from public.vehicle_types
where lower(name) = 'tricycle'
on conflict (trip_type) do update set
  vehicle_type_id = excluded.vehicle_type_id,
  display_label = excluded.display_label,
  base_fare = excluded.base_fare,
  included_km = excluded.included_km,
  succeeding_km_fare = excluded.succeeding_km_fare,
  student_discount = excluded.student_discount,
  pwd_discount = excluded.pwd_discount,
  senior_citizen_discount = excluded.senior_citizen_discount,
  is_active = true,
  updated_at = now();

commit;

-- ============================================================================
-- POST-RUN ADMIN BOOTSTRAP
-- ============================================================================
-- After creating your first admin account in Supabase Auth, run this with your
-- admin email:
--
-- update public.profiles
-- set role = 'admin', updated_at = now()
-- where email = 'YOUR_ADMIN_EMAIL';
--
-- update auth.users
-- set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
-- where email = 'YOUR_ADMIN_EMAIL';
-- ============================================================================

-- ============================================================================
-- BOOKING-LEVEL COMPANION DISCOUNTS (2026-08-21)
-- ============================================================================

-- Apply this to existing projects that already ran an older bootstrap.

alter table public.bookings
  add column if not exists regular_fare numeric(10,2),
  add column if not exists provisional_discounted_fare numeric(10,2),
  add column if not exists final_fare numeric(10,2),
  add column if not exists discount_review_status text not null default 'NOT_REQUIRED',
  add column if not exists discount_reviewed_at timestamptz;

create table if not exists public.booking_discount_requests (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  passenger_id uuid not null references public.passengers(id) on delete cascade,
  discount_type text not null check (discount_type in ('Student', 'Senior Citizen', 'PWD')),
  companion_index integer not null check (companion_index > 0),
  id_image_path text not null,
  status text not null default 'PENDING' check (status in ('PENDING', 'APPROVED', 'REJECTED')),
  reviewed_by_driver_id uuid references public.drivers(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_id, discount_type, companion_index)
);

create index if not exists idx_booking_discount_requests_booking_id
  on public.booking_discount_requests (booking_id);
create index if not exists idx_booking_discount_requests_passenger_id
  on public.booking_discount_requests (passenger_id);
create index if not exists idx_booking_discount_requests_status
  on public.booking_discount_requests (status);

alter table public.booking_discount_requests enable row level security;

drop policy if exists booking_discount_requests_select_policy on public.booking_discount_requests;
drop policy if exists booking_discount_requests_insert_passenger on public.booking_discount_requests;
drop policy if exists booking_discount_requests_update_driver on public.booking_discount_requests;

create policy booking_discount_requests_select_policy
on public.booking_discount_requests for select using (
  public.is_admin()
  or passenger_id = public.current_passenger_id()
  or exists (
    select 1
    from public.bookings b
    where b.id = booking_discount_requests.booking_id
      and (
        b.driver_id = public.current_driver_id()
        or (b.status in ('pending', 'searching') and b.driver_id is null and public.current_driver_can_view_bookings())
      )
  )
);

create policy booking_discount_requests_insert_passenger
on public.booking_discount_requests for insert with check (
  passenger_id = public.current_passenger_id()
  and exists (
    select 1
    from public.bookings b
    where b.id = booking_discount_requests.booking_id
      and b.passenger_id = public.current_passenger_id()
      and b.status in ('pending', 'searching')
  )
);

create policy booking_discount_requests_update_driver
on public.booking_discount_requests for update using (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_discount_requests.booking_id
      and b.driver_id = public.current_driver_id()
  )
) with check (
  exists (
    select 1
    from public.bookings b
    where b.id = booking_discount_requests.booking_id
      and b.driver_id = public.current_driver_id()
  )
);

drop policy if exists discount_ids_assigned_driver_read on storage.objects;
create policy discount_ids_assigned_driver_read
on storage.objects for select using (
  bucket_id = 'discount-ids'
  and public.current_driver_id() is not null
  and exists (
    select 1
    from public.bookings b
    left join public.booking_discount_requests bdr on bdr.booking_id = b.id
    where (
        bdr.id_image_path = storage.objects.name
        or b.discount_id_image = storage.objects.name
      )
      and (
        b.driver_id = public.current_driver_id()
        or (
          b.status in ('pending', 'searching')
          and b.driver_id is null
        )
      )
  )
);

create or replace function public.recalculate_booking_discount_summary(p_booking_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking record;
  v_passenger record;
  v_fare_config record;
  v_regular_count int;
  v_student_count int;
  v_pwd_count int;
  v_senior_count int;
  v_total_count int;
  v_approved_student int := 0;
  v_approved_pwd int := 0;
  v_approved_senior int := 0;
  v_pending_count int := 0;
  v_rejected_count int := 0;
  v_request_count int := 0;
  v_base_per_passenger numeric;
  v_regular_fare numeric;
  v_final_fare numeric;
  v_additional_km numeric;
  v_charged_additional_km int;
  v_per_passenger_subtotal numeric;
  v_status text;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if v_booking is null then
    raise exception 'Booking not found.';
  end if;

  select p.*
  into v_passenger
  from public.passengers p
  where p.id = v_booking.passenger_id;

  v_regular_count := coalesce((v_booking.passenger_qty ->> 'Regular')::int, 0);
  v_student_count := coalesce((v_booking.passenger_qty ->> 'Student')::int, 0);
  v_pwd_count := coalesce((v_booking.passenger_qty ->> 'PWD')::int, 0);
  v_senior_count := coalesce((v_booking.passenger_qty ->> 'Senior Citizens')::int, 0)
                    + coalesce((v_booking.passenger_qty ->> 'Senior Citizen')::int, 0);
  v_total_count := greatest(1, v_regular_count + v_student_count + v_pwd_count + v_senior_count);

  -- Fetch total stops count (minimum 1)
  v_stops_count := greatest(
    1,
    coalesce(
      v_booking.total_stops,
      case
        when v_booking.stops is not null and jsonb_typeof(to_jsonb(v_booking.stops)) = 'array'
        then jsonb_array_length(to_jsonb(v_booking.stops))
        else 1
      end
    )
  );

  -- Select proper fare configuration based on trip_type (Special Trip maps to round_trip)
  select *
  into v_fare_config
  from public.fare_configurations
  where trip_type = case
    when lower(coalesce(v_booking.trip_type, 'one_way')) like '%round%'
      or lower(coalesce(v_booking.trip_type, 'one_way')) like '%special%' then 'round_trip'
    else 'one_way'
  end
    and is_active = true
  limit 1;

  if v_fare_config is null then
    select *
    into v_fare_config
    from public.fare_configurations
    where is_active = true
    order by (case when trip_type = 'one_way' then 1 else 2 end)
    limit 1;
  end if;

  if v_fare_config is null then
    v_final_fare := coalesce(v_booking.final_fare, v_booking.estimated_fare, 0);
    update public.bookings
    set final_fare = v_final_fare,
        discount_reviewed_at = now(),
        updated_at = now()
    where id = p_booking_id;
    return json_build_object('success', true, 'final_fare', v_final_fare);
  end if;

  -- Count discount requests:
  -- Eligible discounts include APPROVED and PENDING (provisional). REJECTED discounts are NOT eligible.
  select
    count(*)::int,
    count(*) filter (where status = 'PENDING')::int,
    count(*) filter (where status = 'REJECTED')::int,
    count(*) filter (where status = 'APPROVED')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and lower(discount_type) like '%student%')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and lower(discount_type) like '%pwd%')::int,
    count(*) filter (where status in ('APPROVED', 'PENDING') and (lower(discount_type) like '%senior%' or lower(discount_type) like '%citizen%'))::int
  into v_request_count, v_pending_count, v_rejected_count, v_approved_count, v_eligible_student, v_eligible_pwd, v_eligible_senior
  from public.booking_discount_requests
  where booking_id = p_booking_id;

  v_eligible_student := least(v_student_count, coalesce(v_eligible_student, 0));
  v_eligible_pwd := least(v_pwd_count, coalesce(v_eligible_pwd, 0));
  v_eligible_senior := least(v_senior_count, coalesce(v_eligible_senior, 0));

  -- Distance & fare calculation incorporating stops
  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - (v_fare_config.included_km * v_stops_count));
  v_charged_additional_km := ceil(v_additional_km)::int;
  v_base_per_passenger := v_fare_config.base_fare * v_stops_count;
  v_per_passenger_subtotal := v_base_per_passenger + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := v_per_passenger_subtotal * v_total_count;

  -- Dynamic final fare: subtract only currently eligible discounts
  v_final_fare := v_regular_fare
    - (v_per_passenger_subtotal * (v_fare_config.student_discount / 100) * v_eligible_student)
    - (v_per_passenger_subtotal * (v_fare_config.pwd_discount / 100) * v_eligible_pwd)
    - (v_per_passenger_subtotal * (v_fare_config.senior_citizen_discount / 100) * v_eligible_senior);
  v_final_fare := greatest(0, round(v_final_fare, 2));

  if v_request_count = 0 then
    v_status := 'NOT_REQUIRED';
  elsif v_pending_count > 0 and (v_rejected_count > 0 or v_approved_count > 0) then
    v_status := 'PARTIALLY_APPROVED';
  elsif v_pending_count > 0 then
    v_status := 'PENDING_DRIVER_REVIEW';
  elsif v_rejected_count = v_request_count then
    v_status := 'REJECTED';
  elsif v_rejected_count > 0 then
    v_status := 'PARTIALLY_APPROVED';
  else
    v_status := 'APPROVED';
  end if;

  -- Ensure that when all discounts are rejected, final_fare equals regular_fare exactly
  if v_status = 'REJECTED' then
    v_final_fare := v_regular_fare;
  end if;

  update public.bookings
  set regular_fare = coalesce(regular_fare, v_regular_fare),
      provisional_discounted_fare = coalesce(provisional_discounted_fare, estimated_fare),
      final_fare = v_final_fare,
      actual_fare = v_final_fare,
      estimated_fare = case when v_status = 'REJECTED' then v_final_fare else estimated_fare end,
      discount_review_status = v_status,
      discount_verified = case
        when v_status = 'APPROVED' then true
        when v_status = 'REJECTED' then false
        else discount_verified
      end,
      passenger_type_display = case
        when v_status = 'REJECTED' then 'Regular'
        else passenger_type_display
      end,
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare,
    'actual_fare', v_final_fare,
    'regular_fare', v_regular_fare
  );
end;
$$;

create or replace function public.review_booking_discount_request(
  p_discount_request_id uuid,
  p_status text,
  p_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver_id uuid;
  v_request record;
  v_summary json;
  v_passenger_profile_id uuid;
begin
  if p_status not in ('APPROVED', 'REJECTED') then
    raise exception 'Invalid discount review status.';
  end if;

  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
  limit 1;

  if v_driver_id is null then
    raise exception 'Only an assigned driver can review booking discount IDs.';
  end if;

  select bdr.*, b.driver_id, b.passenger_id as booking_passenger_id
  into v_request
  from public.booking_discount_requests bdr
  join public.bookings b on b.id = bdr.booking_id
  where bdr.id = p_discount_request_id
  for update;

  if v_request is null then
    raise exception 'Discount request not found.';
  end if;

  if v_request.driver_id is distinct from v_driver_id then
    raise exception 'This booking is not assigned to you.';
  end if;

  update public.booking_discount_requests
  set status = p_status,
      reviewed_by_driver_id = v_driver_id,
      reviewed_at = now(),
      rejection_reason = case when p_status = 'REJECTED' then nullif(trim(coalesce(p_reason, '')), '') else null end,
      updated_at = now()
  where id = p_discount_request_id;

  v_summary := public.recalculate_booking_discount_summary(v_request.booking_id);

  select profile_id into v_passenger_profile_id
  from public.passengers
  where id = v_request.booking_passenger_id;

  if v_passenger_profile_id is not null then
    insert into public.notifications (
      recipient_id, type, title, body, notification_category, data, is_read, is_sent
    )
    values (
      v_passenger_profile_id,
      'in_app',
      case when p_status = 'APPROVED' then 'Companion Discount Approved' else 'Companion Discount Not Accepted' end,
      case
        when p_status = 'APPROVED' then format('Your driver approved a %s companion discount ID.', v_request.discount_type)
        else format('Your driver could not verify a %s companion discount ID. Regular fare applies for that companion.', v_request.discount_type)
      end,
      case when p_status = 'APPROVED' then 'discount_approved' else 'discount_rejected' end,
      jsonb_build_object(
        'booking_id', v_request.booking_id,
        'discount_request_id', p_discount_request_id,
        'discount_type', v_request.discount_type,
        'status', p_status,
        'summary', v_summary
      ),
      false,
      true
    );
  end if;

  return v_summary;
end;
$$;

create or replace function public.review_booking_discount_requests_bulk(
  p_booking_id uuid,
  p_request_ids uuid[],
  p_status text,
  p_reason text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request_id uuid;
  v_last json;
begin
  foreach v_request_id in array p_request_ids loop
    v_last := public.review_booking_discount_request(v_request_id, p_status, p_reason);
  end loop;
  if v_last is null then
    v_last := public.recalculate_booking_discount_summary(p_booking_id);
  end if;
  return v_last;
end;
$$;

create or replace function public.reject_booking_discount_and_revert_fare(
  p_booking_id uuid,
  p_reason text default 'Physical ID not accepted'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_regular_fare numeric(10,2);
  v_driver_id uuid;
  v_passenger_profile_id uuid;
  v_summary json;
begin
  select id into v_driver_id
  from public.drivers
  where profile_id = auth.uid()
  limit 1;

  if v_driver_id is null and not public.is_admin() then
    raise exception 'Only assigned drivers or admins can reject discount.';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Booking not found.';
  end if;

  v_regular_fare := coalesce(v_booking.regular_fare, v_booking.estimated_fare);

  -- Mark all pending companion requests for this booking as REJECTED
  update public.booking_discount_requests
  set status = 'REJECTED',
      rejection_reason = p_reason,
      reviewed_by_driver_id = v_driver_id,
      reviewed_at = now(),
      updated_at = now()
  where booking_id = p_booking_id
    and status = 'PENDING';

  -- Recalculate summary to guarantee math consistency
  v_summary := public.recalculate_booking_discount_summary(p_booking_id);

  -- Ensure direct booking columns are fully updated
  update public.bookings
  set discount_verified = false,
      discount_rejected_reason = p_reason,
      passenger_type_display = 'Regular',
      discount_review_status = 'REJECTED',
      final_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      actual_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      estimated_fare = coalesce((v_summary->>'final_fare')::numeric, v_regular_fare),
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  -- Notify passenger of regular fare reversion
  select profile_id into v_passenger_profile_id
  from public.passengers
  where id = v_booking.passenger_id;

  if v_passenger_profile_id is not null then
    insert into public.notifications (
      recipient_id, type, title, body, notification_category, data, is_read, is_sent
    )
    values (
      v_passenger_profile_id,
      'in_app',
      'Discount Not Accepted - Fare Reverted',
      format('Your driver could not accept the discount ID. The fare has reverted to the regular price of ₱%s.', coalesce(v_regular_fare, 0)),
      'discount_rejected',
      jsonb_build_object(
        'booking_id', p_booking_id,
        'status', 'REJECTED',
        'reason', p_reason,
        'fare', v_regular_fare
      ),
      false,
      true
    );
  end if;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'fare', v_regular_fare,
    'regular_fare', v_regular_fare,
    'final_fare', v_regular_fare,
    'actual_fare', v_regular_fare
  );
end;
$$;

insert into public.booking_discount_requests (
  booking_id, passenger_id, discount_type, companion_index, id_image_path, status, rejection_reason, created_at, updated_at
)
select
  b.id,
  b.passenger_id,
  case when b.discount_passenger_type = 'Senior Citizens' then 'Senior Citizen' else b.discount_passenger_type end,
  1,
  b.discount_id_image,
  case
    when b.discount_verified is true then 'APPROVED'
    when b.discount_verified is false then 'REJECTED'
    else 'PENDING'
  end,
  b.discount_rejected_reason,
  coalesce(b.created_at, now()),
  now()
from public.bookings b
where b.discount_id_image is not null
  and b.discount_passenger_type in ('Student', 'Senior Citizen', 'Senior Citizens', 'PWD')
on conflict (booking_id, discount_type, companion_index) do nothing;

do $$
begin
  alter publication supabase_realtime add table public.booking_discount_requests;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;

-- September 9: database synchronization and authorization corrections.
-- Apply once to an existing project before deploying the revised apps.
-- Does not delete booking history or reset operational records.
begin;

create or replace function public.is_admin()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and is_active = true
  );
$$;

create or replace function public.guard_profile_role()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      if new.role = 'admin' then raise exception 'Only administrators can assign administrator access.'; end if;
    elsif old.role is distinct from new.role then
      raise exception 'Only administrators can change account roles.';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_guard_role_trg on public.profiles;
create trigger profiles_guard_role_trg before insert or update on public.profiles
for each row execute function public.guard_profile_role();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role_txt text;
  v_role public.user_role;
  v_first_name text;
  v_last_name text;
  v_full_name text;
begin
  v_role_txt := coalesce(new.raw_user_meta_data->>'role', 'passenger');
  if v_role_txt not in ('passenger', 'driver') then
    v_role_txt := 'passenger';
  end if;
  v_role := v_role_txt::public.user_role;

  v_first_name := coalesce(new.raw_user_meta_data->>'first_name', '');
  v_last_name := coalesce(new.raw_user_meta_data->>'last_name', '');
  v_full_name := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', concat_ws(' ', v_first_name, v_last_name))), '');

  insert into public.profiles (id, role, first_name, last_name, full_name, phone_number, email)
  values (
    new.id,
    v_role,
    v_first_name,
    v_last_name,
    v_full_name,
    coalesce(new.raw_user_meta_data->>'phone_number', new.phone),
    new.email
  )
  on conflict (id) do update set
    role = excluded.role,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    updated_at = now();

  if v_role = 'passenger' then
    insert into public.passengers (id, profile_id)
    values (new.id, new.id)
    on conflict (profile_id) do nothing;
  end if;

  return new;
end;
$$;

create or replace function public.create_driver_account(
  p_email text,
  p_password text,
  p_first_name text,
  p_last_name text,
  p_phone text,
  p_plate_number text,
  p_toda_association text default 'LHITC-TODA'
)
returns json
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_user_id uuid;
  v_driver_id uuid;
  v_type_id uuid;
  v_existing_profile_role public.user_role;
  v_clean_toda text;
begin
  if not public.is_admin() then
    return json_build_object('success', false, 'error', 'Only admins can create driver accounts.');
  end if;

  v_clean_toda := coalesce(nullif(trim(p_toda_association), ''), 'LHITC-TODA');
  if v_clean_toda not in ('LHITC-TODA', 'BYPASS ILAYANG BAGUIO-TODA', 'CHOT-TODA') then
    v_clean_toda := 'LHITC-TODA';
  end if;

  select id into v_user_id from auth.users where email = p_email;
  if v_user_id is not null then
    select role into v_existing_profile_role from public.profiles where id = v_user_id;
    if exists (select 1 from public.drivers where profile_id = v_user_id and document_status = 'VERIFIED') then
      return json_build_object('success', false, 'error', 'Driver account already exists.');
    elsif v_existing_profile_role = 'passenger' then
      return json_build_object('success', false, 'error', 'This email is already registered as a passenger account.');
    end if;
  end if;

  if p_phone is not null and p_phone <> '' and exists (
    select 1
    from public.profiles
    where phone_number = p_phone
      and (v_user_id is null or id <> v_user_id)
      and role = 'passenger'
  ) then
    return json_build_object('success', false, 'error', 'This phone number is already registered as a passenger account.');
  end if;

  if exists (
    select 1
    from public.vehicles v
    join public.drivers d on d.id = v.driver_id
    where v.plate_number = p_plate_number
      and (v_user_id is null or d.profile_id <> v_user_id)
  ) then
    return json_build_object('success', false, 'error', 'Plate number already registered to another driver.');
  end if;

  if v_user_id is null then
    v_user_id := gen_random_uuid();

    insert into auth.users (
      id, instance_id, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      aud, role, phone, phone_confirmed_at,
      confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current,
      phone_change_token, reauthentication_token
    ) values (
      v_user_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      p_email,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      json_build_object('first_name', p_first_name, 'last_name', p_last_name, 'phone_number', p_phone, 'role', 'driver')::jsonb,
      now(), now(),
      'authenticated', 'authenticated', p_phone, now(),
      '', '', '', '', '', '', ''
    );

    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (
      v_user_id,
      v_user_id,
      p_email,
      'email',
      json_build_object('sub', v_user_id::text, 'email', p_email)::jsonb,
      now(), now(), now()
    )
    on conflict do nothing;
  end if;

  insert into public.profiles (id, first_name, last_name, full_name, phone_number, role, email)
  values (v_user_id, p_first_name, p_last_name, nullif(trim(concat_ws(' ', p_first_name, p_last_name)), ''), p_phone, 'driver', p_email)
  on conflict (id) do update set
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    full_name = excluded.full_name,
    phone_number = excluded.phone_number,
    email = excluded.email,
    role = 'driver',
    updated_at = now();

  insert into public.drivers (profile_id, license_number, status, approved_at, toda_association)
  values (v_user_id, 'PENDING', 'approved', now(), v_clean_toda)
  on conflict (profile_id) do update set
    approved_at = coalesce(public.drivers.approved_at, now()),
    toda_association = coalesce(nullif(trim(excluded.toda_association), ''), public.drivers.toda_association, v_clean_toda),
    updated_at = now()
  returning id into v_driver_id;

  select id into v_type_id from public.vehicle_types where is_active = true order by created_at limit 1;

  if v_type_id is not null and v_driver_id is not null then
  insert into public.vehicles (driver_id, vehicle_type_id, plate_number)
  values (v_driver_id, v_type_id, p_plate_number)
  on conflict (driver_id) do update set
    vehicle_type_id = excluded.vehicle_type_id,
    plate_number = excluded.plate_number,
    updated_at = now();
  end if;

  return json_build_object('success', true, 'driver_id', v_driver_id, 'user_id', v_user_id, 'toda_association', v_clean_toda);
end;
$$;

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

-- Passenger cancellation statistics (admin solely controls booking restrictions)
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

-- Validate passenger eligibility at the database boundary as well as in the app.
create or replace function public.guard_passenger_booking_insert()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_passenger public.passengers%rowtype;
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  select * into v_passenger from public.passengers where id = new.passenger_id;
  if v_passenger.profile_id is distinct from auth.uid() then raise exception 'Passenger account mismatch.'; end if;
  if not exists (select 1 from public.profiles where id = auth.uid() and is_active) then raise exception 'Account is inactive.'; end if;
  if v_passenger.discount_document_status in ('PENDING', 'REJECTED') then raise exception 'Account verification is required.'; end if;
  if v_passenger.booking_restriction_until > now() then raise exception 'Account is restricted from booking.'; end if;
  return new;
end;
$$;
drop trigger if exists bookings_guard_passenger_insert_trg on public.bookings;
create trigger bookings_guard_passenger_insert_trg before insert on public.bookings
for each row execute function public.guard_passenger_booking_insert();

create or replace function public.guard_booking_cancellation()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status <> 'cancelled' or old.status = 'cancelled' then return new; end if;
  if old.status = 'completed' then raise exception 'Cannot cancel a completed booking.'; end if;
  if auth.uid() is not null and not public.is_admin() then
    if old.passenger_id = public.current_passenger_id() then
      if old.status not in ('pending', 'searching') or old.driver_id is not null then
        raise exception 'Ask your driver to cancel an ongoing trip.';
      end if;
      new.cancelled_by := 'passenger';
    elsif old.driver_id = public.current_driver_id() then
      if old.status not in ('accepted', 'driver_arriving', 'pickedUp') then
        raise exception 'This trip can no longer be cancelled by the driver.';
      end if;
      new.cancelled_by := 'driver';
    else
      raise exception 'Only the booking participants or an administrator can cancel this trip.';
    end if;
  end if;
  new.cancelled_at := now();
  return new;
end;
$$;
drop trigger if exists bookings_guard_cancellation_trg on public.bookings;
create trigger bookings_guard_cancellation_trg before update on public.bookings
for each row execute function public.guard_booking_cancellation();

create or replace function public.notify_booking_event()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_title text;
  v_body text;
  v_category text;
begin
  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status
       and old.trip_phase is not distinct from new.trip_phase then return new; end if;
  end if;
  case new.status
    when 'pending', 'searching' then
      v_title := 'Ride Request Sent'; v_body := 'Searching for an available driver.'; v_category := 'search';
    when 'accepted' then
      v_title := 'Driver Accepted'; v_body := 'A driver has accepted your booking.'; v_category := 'accept';
    when 'driver_arriving' then
      v_title := 'Driver Arriving'; v_body := 'Your driver is at or approaching the pickup location.'; v_category := 'arriving';
    when 'pickedUp' then
      v_title := case when new.trip_phase = 'to_return' then 'Return Trip Started' else 'Trip Started' end;
      v_body := case when new.trip_phase = 'to_return' then 'Your trip is heading to the return location.' else 'Your trip is underway.' end;
      v_category := 'pickup';
    when 'droppedOff' then
      v_title := 'Destination Reached'; v_body := 'The trip has reached its destination. Payment is pending.'; v_category := 'complete';
    when 'paymentSent' then
      v_title := 'Payment Confirmation Pending'; v_body := 'The passenger marked cash as paid. Driver confirmation is pending.'; v_category := 'payment';
    when 'completed' then
      v_title := 'Trip Completed'; v_body := 'The driver confirmed payment and completed this booking.'; v_category := 'complete';
    when 'cancelled' then
      v_title := 'Booking Cancelled';
      v_body := case when new.cancelled_by = 'driver' then 'The driver cancelled this booking.'
                     when new.cancelled_by = 'passenger' then 'The passenger cancelled this booking.'
                     else 'This booking was cancelled.' end;
      if nullif(trim(new.cancel_reason), '') is not null then v_body := v_body || ' Reason: ' || new.cancel_reason; end if;
      v_category := 'cancel';
    else return new;
  end case;

  insert into public.notifications(recipient_id, title, body, notification_category, data)
  select profile_id, v_title, v_body, v_category,
    jsonb_build_object('booking_id', new.id, 'status', new.status, 'trip_phase', new.trip_phase, 'cancelled_by', new.cancelled_by)
  from (
    select profile_id from public.passengers where id = new.passenger_id
    union
    select profile_id from public.drivers where id = new.driver_id
  ) recipients where profile_id is not null;
  return new;
end;
$$;
drop trigger if exists bookings_notify_event_trg on public.bookings;
create trigger bookings_notify_event_trg after insert or update of status, trip_phase on public.bookings
for each row execute function public.notify_booking_event();

drop policy if exists notifications_delete_own on public.notifications;
create policy notifications_delete_own on public.notifications for delete to authenticated
using (recipient_id = auth.uid());

create or replace function public.get_passenger_public_stats(p_passenger_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() and p_passenger_id is distinct from public.current_passenger_id()
    and not exists (
      select 1 from public.bookings where passenger_id = p_passenger_id
      and (driver_id = public.current_driver_id() or
        (driver_id is null and status in ('pending', 'searching') and public.current_driver_can_view_bookings()))
    ) then raise exception 'Passenger is not visible to this account.'; end if;
  return jsonb_build_object('completed_trips',
    (select count(*) from public.bookings where passenger_id = p_passenger_id and status = 'completed'));
end;
$$;
revoke all on function public.get_passenger_public_stats(uuid) from public;
grant execute on function public.get_passenger_public_stats(uuid) to authenticated;

do $$
declare v_table text;
begin
  foreach v_table in array array['bookings', 'profiles', 'passengers', 'drivers', 'vehicles', 'notifications', 'booking_discount_requests', 'driver_profile_change_requests', 'reports'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end;
$$;
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
