-- ============================================================================
-- Migration: Driver Profile Change Requests Workflow & Auto-Sync
-- Description:
--   1. Ensures review_driver_profile_change_request handles all possible field names
--   2. Updates profiles, drivers, or vehicles upon approval
--   3. Inserts in-app notifications for the driver
--   4. Grants execute permissions
-- ============================================================================

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

grant execute on function public.review_driver_profile_change_request(uuid, text, text) to authenticated, anon;
