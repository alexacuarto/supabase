-- Booking-level companion discount verification.
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
  v_account_student int := 0;
  v_account_pwd int := 0;
  v_account_senior int := 0;
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

  select *
  into v_fare_config
  from public.fare_configurations
  where trip_type = case
    when lower(coalesce(v_booking.trip_type, 'one_way')) like '%round%' then 'round_trip'
    else 'one_way'
  end
    and is_active = true
  limit 1;

  if v_fare_config is null then
    v_final_fare := coalesce(v_booking.final_fare, v_booking.estimated_fare, 0);
    update public.bookings
    set final_fare = v_final_fare,
        discount_reviewed_at = now(),
        updated_at = now()
    where id = p_booking_id;
    return json_build_object('success', true, 'final_fare', v_final_fare);
  end if;

  if v_passenger.discount_eligible is true and v_passenger.discount_document_status = 'VERIFIED' then
    if v_passenger.account_passenger_type = 'Student' and v_student_count > 0 then
      v_account_student := 1;
    elsif v_passenger.account_passenger_type = 'PWD' and v_pwd_count > 0 then
      v_account_pwd := 1;
    elsif v_passenger.account_passenger_type = 'Senior Citizen' and v_senior_count > 0 then
      v_account_senior := 1;
    end if;
  end if;

  select
    count(*)::int,
    count(*) filter (where status = 'PENDING')::int,
    count(*) filter (where status = 'REJECTED')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'Student')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'PWD')::int,
    count(*) filter (where status = 'APPROVED' and discount_type = 'Senior Citizen')::int
  into v_request_count, v_pending_count, v_rejected_count, v_approved_student, v_approved_pwd, v_approved_senior
  from public.booking_discount_requests
  where booking_id = p_booking_id;

  v_approved_student := least(v_student_count, v_account_student + coalesce(v_approved_student, 0));
  v_approved_pwd := least(v_pwd_count, v_account_pwd + coalesce(v_approved_pwd, 0));
  v_approved_senior := least(v_senior_count, v_account_senior + coalesce(v_approved_senior, 0));

  v_additional_km := greatest(0, coalesce(v_booking.estimated_distance_km, 0) - v_fare_config.included_km);
  v_charged_additional_km := ceil(v_additional_km)::int;
  v_per_passenger_subtotal := v_fare_config.base_fare + (v_charged_additional_km * v_fare_config.succeeding_km_fare);
  v_regular_fare := v_per_passenger_subtotal * v_total_count;

  v_final_fare := v_regular_fare
    - (v_per_passenger_subtotal * (v_fare_config.student_discount / 100) * v_approved_student)
    - (v_per_passenger_subtotal * (v_fare_config.pwd_discount / 100) * v_approved_pwd)
    - (v_per_passenger_subtotal * (v_fare_config.senior_citizen_discount / 100) * v_approved_senior);
  v_final_fare := greatest(0, round(v_final_fare, 2));

  if v_request_count = 0 then
    v_status := 'NOT_REQUIRED';
  elsif v_pending_count > 0 and (v_rejected_count > 0 or (v_approved_student + v_approved_pwd + v_approved_senior) > 0) then
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

  update public.bookings
  set regular_fare = coalesce(regular_fare, v_regular_fare),
      provisional_discounted_fare = coalesce(provisional_discounted_fare, estimated_fare),
      final_fare = v_final_fare,
      actual_fare = case when status in ('droppedOff', 'paymentSent', 'completed') then v_final_fare else actual_fare end,
      discount_review_status = v_status,
      discount_reviewed_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return json_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'discount_review_status', v_status,
    'final_fare', v_final_fare
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
