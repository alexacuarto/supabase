-- TODA GO client revisions upgrade script.
-- Apply this to an existing Supabase project that was already bootstrapped
-- before the 2026-08-20 revisions were added to todago_final_bootstrap.sql.

alter table public.passengers
  add column if not exists account_passenger_type text not null default 'Regular',
  add column if not exists discount_document_url text,
  add column if not exists discount_document_status text not null default 'NOT_REQUIRED',
  add column if not exists discount_document_type text,
  add column if not exists discount_document_rejection_reason text,
  add column if not exists discount_document_submitted_at timestamptz,
  add column if not exists discount_document_reviewed_at timestamptz,
  add column if not exists discount_document_reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists discount_eligible boolean not null default false;

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

create index if not exists idx_fare_change_logs_created on public.fare_change_logs(created_at desc);
alter table public.fare_change_logs enable row level security;

drop policy if exists fare_change_logs_admin_select on public.fare_change_logs;
create policy fare_change_logs_admin_select on public.fare_change_logs for select using (public.is_admin());

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

  select * into v_existing
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

  insert into public.notifications (recipient_id, type, title, body, data, notification_category)
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
    raise exception 'Only admins can review passenger discount IDs.';
  end if;

  if p_status not in ('VERIFIED', 'REJECTED') then
    raise exception 'Discount review status must be VERIFIED or REJECTED.';
  end if;

  select * into v_passenger
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
      discount_eligible = p_status = 'VERIFIED',
      updated_at = now()
  where id = p_passenger_id;

  v_title := case when p_status = 'VERIFIED' then 'Discount ID Approved' else 'Discount ID Rejected' end;
  v_body := case
    when p_status = 'VERIFIED' then 'Your discount ID has been approved. Discounted fares are now available for your account.'
    else coalesce(nullif(trim(p_reason), ''), 'Your discount ID was not approved. Please upload a clear valid ID.')
  end;

  insert into public.notifications (recipient_id, type, title, body, data, notification_category)
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

drop policy if exists ratings_select_policy on public.ratings;
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
