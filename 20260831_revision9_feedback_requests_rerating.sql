-- Revision 9: repeated passenger ratings, driver profile change requests,
-- passenger feedback reports, and atomic driver online session accounting.

alter table if exists public.ratings
  drop constraint if exists ratings_booking_id_key;

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

drop trigger if exists after_rating_insert on public.ratings;
drop trigger if exists after_rating_change on public.ratings;
create trigger after_rating_change
  after insert or update or delete on public.ratings
  for each row execute function public.update_driver_rating();

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

create unique index if not exists idx_driver_change_requests_one_pending
  on public.driver_profile_change_requests(driver_id, field_name)
  where status = 'PENDING';

create index if not exists idx_driver_change_requests_status
  on public.driver_profile_change_requests(status, created_at desc);

alter table public.driver_profile_change_requests enable row level security;

drop policy if exists driver_change_requests_select on public.driver_profile_change_requests;
drop policy if exists driver_change_requests_insert_own on public.driver_profile_change_requests;
drop policy if exists driver_change_requests_update_admin on public.driver_profile_change_requests;

create policy driver_change_requests_select
on public.driver_profile_change_requests for select using (
  profile_id = auth.uid() or public.is_admin()
);

create policy driver_change_requests_insert_own
on public.driver_profile_change_requests for insert with check (
  profile_id = auth.uid()
  and driver_id = public.current_driver_id()
  and status = 'PENDING'
);

create policy driver_change_requests_update_admin
on public.driver_profile_change_requests for update using (public.is_admin())
with check (public.is_admin());

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
    elsif v_request.field_name in ('license_number', 'toda_association', 'license_expiry_date', 'franchise_number', 'franchise_expiry_date') then
      execute format('update public.drivers set %I = $1, updated_at = now() where id = $2', v_request.field_name)
      using v_request.requested_value, v_request.driver_id;
    elsif v_request.field_name = 'plate_number' then
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

alter table public.reports
  add column if not exists reporter_profile_id uuid references public.profiles(id) on delete set null,
  add column if not exists reporter_passenger_id uuid references public.passengers(id) on delete set null,
  add column if not exists driver_id uuid references public.drivers(id) on delete set null,
  add column if not exists booking_id uuid references public.bookings(id) on delete set null,
  add column if not exists category text,
  add column if not exists message text,
  add column if not exists status text not null default 'OPEN',
  add column if not exists admin_notes text,
  add column if not exists reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists updated_at timestamptz not null default now();

alter table public.reports
  drop constraint if exists reports_status_check;
alter table public.reports
  add constraint reports_status_check check (status in ('OPEN', 'REVIEWING', 'RESOLVED', 'DISMISSED'));

create index if not exists idx_reports_status_created on public.reports(status, created_at desc);
create index if not exists idx_reports_reporter on public.reports(reporter_profile_id, created_at desc);
create index if not exists idx_reports_driver on public.reports(driver_id, created_at desc);

drop policy if exists reports_admin_all on public.reports;
drop policy if exists reports_insert_passenger on public.reports;
drop policy if exists reports_select_own_or_admin on public.reports;
drop policy if exists reports_update_admin on public.reports;

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

create policy reports_update_admin on public.reports for update using (public.is_admin())
with check (public.is_admin());

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
    update public.drivers
    set is_online = true,
        last_online_at = coalesce(last_online_at, v_now),
        updated_at = v_now
    where id = v_driver.id;

    select * into v_open_session
    from public.driver_sessions
    where driver_id = v_driver.id and went_offline is null
    order by went_online desc
    limit 1;

    if v_open_session.id is null then
      insert into public.driver_sessions (driver_id, went_online)
      values (v_driver.id, v_now);
    end if;
  else
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

do $$
begin
  begin alter publication supabase_realtime add table public.driver_profile_change_requests; exception when others then null; end;
  begin alter publication supabase_realtime add table public.reports; exception when others then null; end;
end $$;
