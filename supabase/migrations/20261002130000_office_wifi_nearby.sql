-- Office Wi-Fi rule widened: a punch passes the Wi-Fi check when the phone is
-- connected to an office Wi-Fi OR sees one nearby in a scan (so staff on
-- mobile data at the office are not blocked). Office location is still checked.

create or replace function public.internal_commit_punch(
  p_auth_user_id uuid,
  p_session_id uuid,
  p_email text,
  p_operation_key uuid,
  p_payload_hash text,
  p_challenge_id uuid,
  p_action text,
  p_target_id uuid,
  p_device_id uuid,
  p_office_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy double precision,
  p_sample_at timestamptz,
  p_receipt_at timestamptz,
  p_integrity jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_emp hrms.employees;
  v_rec hrms.idempotency_records;
  v_ch hrms.punch_challenges;
  v_dev hrms.devices;
  v_inst hrms.work_schedule_instances;
  v_sess hrms.attendance_sessions;
  v_office hrms.offices;
  v_point extensions.geography;
  v_distance double precision;
  v_slots integer;
  v_calc hrms.day_calc;
  v_required_start timestamptz;
  v_required_end timestamptz;
  v_window_open timestamptz;
  v_event_id uuid;
  v_result jsonb;
  v_hits integer;
  v_policy jsonb;
begin
  -- Serialise every punch for this employee.
  select * into v_emp from hrms.employees where id = v_actor.employee_id for update;

  -- 1. Committed replay first: original result, before any freshness checks.
  select * into v_rec from hrms.idempotency_records
  where actor_employee_id = v_actor.employee_id and scope = 'punch' and operation_key = p_operation_key;
  if found then
    if v_rec.request_hash <> p_payload_hash then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'IDEMPOTENCY_CONFLICT', 'This punch was already recorded with different details.', null, p_receipt_at);
    end if;
    return v_rec.result;
  end if;

  v_hits := hrms.rate_limit_hit('punch:' || v_actor.employee_id::text, interval '1 minute');
  if v_hits > 10 then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'RATE_LIMITED', 'Too many attempts. Wait a minute and try again.', null, p_receipt_at, true);
  end if;

  -- 2. Bounded verification deadline measured from trusted receipt time.
  if p_receipt_at is null or clock_timestamp() - p_receipt_at > interval '30 seconds'
     or p_receipt_at > clock_timestamp() + interval '1 second' then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'VERIFICATION_FAILED', 'Verification took too long. Please try again.', null, p_receipt_at, true);
  end if;

  if p_action not in ('IN', 'OUT') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown action');
  end if;

  -- 3. Challenge: single use, bound to actor/device/action/target, valid at receipt.
  select * into v_ch from hrms.punch_challenges
  where id = p_challenge_id for update;
  if not found or v_ch.employee_id <> v_actor.employee_id or v_ch.device_id <> p_device_id
     or v_ch.action <> p_action or v_ch.target_id <> p_target_id
     or v_ch.consumed_at is not null or v_ch.expires_at < p_receipt_at then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'VERIFICATION_FAILED', 'Verification failed. Please try again.',
      jsonb_build_object('reason', 'challenge'), p_receipt_at, true);
  end if;

  select * into v_dev from hrms.devices where id = p_device_id;
  if not found or v_dev.employee_id <> v_actor.employee_id or v_dev.revoked_at is not null then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'VERIFICATION_FAILED', 'This phone is not registered for punching.',
      jsonb_build_object('reason', 'device'), p_receipt_at);
  end if;
  if v_dev.attestation_level = 'hardware' and not v_dev.biometric_bound
     and (select require_biometric_punch from hrms.organizations where id = v_actor.org_id) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'VERIFICATION_FAILED', 'Register this phone again with fingerprint or face unlock enabled.',
      jsonb_build_object('reason', 'biometric_required'), p_receipt_at);
  end if;
  if coalesce((p_integrity ->> 'mock_location')::boolean, false) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'VERIFICATION_FAILED', 'Location could not be verified on this phone.',
      jsonb_build_object('reason', 'integrity'), p_receipt_at);
  end if;

  -- 4. Location sanity (malformed values are rejected at the edge as well).
  if p_latitude is null or p_longitude is null or p_accuracy is null
     or p_latitude = 'NaN'::double precision or p_longitude = 'NaN'::double precision
     or p_accuracy = 'NaN'::double precision
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'LOCATION_REQUIRED', 'A valid location is required.', null, p_receipt_at);
  end if;

  -- 5. Lazy rollover of yesterday's stale open session (no fabricated OUT).
  perform hrms.rollover_stale_sessions(v_actor.employee_id, p_receipt_at);

  -- 6. Resolve the target shift / session.
  if p_action = 'IN' then
    select * into v_inst from hrms.work_schedule_instances
    where id = p_target_id and employee_id = v_actor.employee_id;
    if not found then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_SHIFT', 'No shift is scheduled for this check-in.', null, p_receipt_at);
    end if;
    if not v_inst.is_required then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_SHIFT', 'Today is not a working day for you.', jsonb_build_object('kind', v_inst.kind), p_receipt_at);
    end if;
    v_slots := hrms.approved_leave_slots(v_actor.employee_id, v_inst.shift_date);
    if v_slots = 3 then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_SHIFT', 'You are on approved leave today.', null, p_receipt_at);
    end if;
    v_required_start := case when v_slots = 1 then v_inst.half_split_at else v_inst.start_at end;
    v_required_end := case when v_slots = 2 then v_inst.half_split_at else v_inst.end_at end;
    v_window_open := v_required_start - make_interval(secs => v_inst.early_entry_seconds);
    if p_receipt_at < v_window_open or p_receipt_at >= v_required_end then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_PUNCH_SEQUENCE', 'Check-in is not open for this shift right now.',
        jsonb_build_object('opens_at', v_window_open, 'closes_at', v_required_end), p_receipt_at);
    end if;
    if exists (select 1 from hrms.attendance_sessions where schedule_instance_id = v_inst.id) then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_PUNCH_SEQUENCE', 'You have already checked in for this shift.', null, p_receipt_at);
    end if;
    if exists (select 1 from hrms.attendance_sessions where employee_id = v_actor.employee_id and state = 'open') then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_PUNCH_SEQUENCE', 'Check out of your current shift first.', null, p_receipt_at);
    end if;
  else
    select * into v_sess from hrms.attendance_sessions
    where id = p_target_id and employee_id = v_actor.employee_id for update;
    if not found or v_sess.state <> 'open' then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_PUNCH_SEQUENCE', 'There is no open check-in to close. Request a correction if needed.',
        null, p_receipt_at);
    end if;
    select * into v_inst from hrms.work_schedule_instances where id = v_sess.schedule_instance_id;
    if p_receipt_at > v_inst.end_at + make_interval(secs => v_inst.checkout_extension_seconds)
       or p_receipt_at <= v_sess.effective_in_at then
      return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
        'INVALID_PUNCH_SEQUENCE', 'The checkout window for this shift has closed. Request a correction.',
        null, p_receipt_at);
    end if;
  end if;

  -- 7. Office policy is rechecked now, not trusted from when the screen loaded.
  select o.* into v_office from hrms.offices o
  where o.id = v_inst.office_id and o.org_id = v_actor.org_id;
  if not found or not v_office.active or p_office_id is distinct from v_office.id
     or not exists (
       select 1 from hrms.office_assignments a
       where a.employee_id = v_actor.employee_id and a.office_id = v_office.id
         and daterange(a.effective_from, a.effective_to, '[)') @> v_inst.shift_date) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'OUTSIDE_ZONE', 'You are not assigned to an active office for this shift.', null, p_receipt_at);
  end if;

  if p_accuracy <= 0 or p_accuracy > v_office.max_accuracy_m then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'LOCATION_INACCURATE', 'Location is not precise enough. Move to a spot with better signal and retry.',
      jsonb_build_object('accuracy_m', p_accuracy, 'max_m', v_office.max_accuracy_m), p_receipt_at, true);
  end if;
  if p_sample_at is null
     or p_receipt_at - p_sample_at > make_interval(secs => v_office.max_sample_age_s)
     or p_sample_at - p_receipt_at > interval '2 seconds' then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'LOCATION_STALE', 'Location reading is too old. Please retry.', null, p_receipt_at, true);
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography;
  v_distance := extensions.st_distance(v_point, v_office.location);
  if v_distance > v_office.radius_m
     or (v_office.strict_mode and v_distance + p_accuracy > v_office.radius_m) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'OUTSIDE_ZONE', 'You appear to be outside the office area.',
      jsonb_build_object('distance_m', round(v_distance::numeric, 1), 'radius_m', v_office.radius_m),
      p_receipt_at, true);
  end if;

  -- Office Wi-Fi: when the office lists Wi-Fi names, the phone must be
  -- connected to one of them OR see one nearby in a scan (mobile data is fine).
  if cardinality(v_office.wifi_ssids) > 0 and not exists (
       select 1 from unnest(v_office.wifi_ssids) w
       join (select p_integrity ->> 'wifi_ssid' as n
             union all
             select jsonb_array_elements_text(case when jsonb_typeof(p_integrity -> 'wifi_nearby') = 'array'
                                                    then p_integrity -> 'wifi_nearby' else '[]'::jsonb end)) seen
         on lower(btrim(w)) = lower(btrim(seen.n))) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'WIFI_REQUIRED', 'Office Wi-Fi (' || array_to_string(v_office.wifi_ssids, ' or ')
        || ') was not found. Turn on Wi-Fi at the office and try again.',
      jsonb_build_object('wifi_ssid', p_integrity ->> 'wifi_ssid'), p_receipt_at, true);
  end if;

  v_policy := jsonb_build_object(
    'office_config_version', v_office.config_version, 'wifi_ssids', to_jsonb(v_office.wifi_ssids),
    'radius_m', v_office.radius_m, 'max_accuracy_m', v_office.max_accuracy_m,
    'max_sample_age_s', v_office.max_sample_age_s, 'strict_mode', v_office.strict_mode,
    'shift_version_id', v_inst.shift_version_id, 'leave_slots', coalesce(v_slots, 0));

  -- 8. Commit event + session atomically.
  if p_action = 'IN' then
    insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state,
                                          effective_in_at, effective_source)
    values (v_actor.org_id, v_actor.employee_id, v_inst.id, v_inst.shift_date, 'open', p_receipt_at, 'gps')
    returning * into v_sess;
  end if;

  insert into hrms.attendance_events (org_id, employee_id, session_id, action, server_timestamp,
    operation_key, latitude, longitude, accuracy_m, sample_at, distance_m, office_id,
    office_config_version, device_id, integrity, policy_snapshot)
  values (v_actor.org_id, v_actor.employee_id, v_sess.id, p_action, p_receipt_at, p_operation_key,
    p_latitude, p_longitude, p_accuracy, p_sample_at, v_distance, v_office.id, v_office.config_version,
    p_device_id, hrms.redact(coalesce(p_integrity, '{}'::jsonb)), v_policy)
  returning id into v_event_id;

  if p_action = 'IN' then
    update hrms.attendance_sessions set in_event_id = v_event_id where id = v_sess.id;
  else
    update hrms.attendance_sessions
       set out_event_id = v_event_id, effective_out_at = p_receipt_at, state = 'closed',
           version = version + 1
     where id = v_sess.id;
  end if;

  update hrms.punch_challenges set consumed_at = clock_timestamp(), consumed_operation_key = p_operation_key
  where id = v_ch.id;
  update hrms.devices set last_used_at = p_receipt_at where id = v_dev.id;

  select * into v_sess from hrms.attendance_sessions where id = v_sess.id;
  v_calc := hrms.calc_day(v_inst.is_required, v_inst.start_at, v_inst.end_at, v_inst.half_split_at,
    v_inst.expected_seconds, coalesce(v_slots, hrms.approved_leave_slots(v_actor.employee_id, v_inst.shift_date)),
    v_inst.grace_seconds, v_inst.early_credit, v_inst.checkout_extension_seconds,
    v_sess.effective_in_at, v_sess.effective_out_at);

  v_result := jsonb_build_object(
    'ok', true,
    'data', jsonb_build_object(
      'operation_key', p_operation_key,
      'action', p_action,
      'event_id', v_event_id,
      'server_time', p_receipt_at,
      'distance_m', round(v_distance::numeric, 1),
      'session', hrms.session_view(v_sess.id),
      'is_late', v_calc.is_late,
      'late_seconds', v_calc.late_seconds,
      'is_early_departure', v_calc.is_early_departure,
      'credited_seconds', v_calc.credited_seconds,
      'required_seconds', v_calc.required_seconds
    ),
    'request_id', hrms.request_id()
  );

  insert into hrms.idempotency_records (actor_employee_id, scope, operation_key, org_id, request_hash, result)
  values (v_actor.employee_id, 'punch', p_operation_key, v_actor.org_id, p_payload_hash, v_result);

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'attendance.punch_' || lower(p_action),
    'attendance_session', v_sess.id,
    jsonb_build_object('event_id', v_event_id, 'distance_m', round(v_distance::numeric, 1),
                       'accuracy_m', p_accuracy, 'integrity_level', p_integrity ->> 'level'),
    'business', v_actor.employee_id);
  return v_result;
end;
$$;

