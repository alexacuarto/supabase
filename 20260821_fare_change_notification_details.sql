-- Updates fare-change notifications to include exact old -> new values.
-- Apply this if the 2026-08-20 client revisions were already installed.

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
