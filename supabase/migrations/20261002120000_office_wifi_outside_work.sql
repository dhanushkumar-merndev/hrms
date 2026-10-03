-- 1. Office Wi-Fi: Admin lists the office Wi-Fi names; a punch must come
--    from the office area AND, when names are listed, from one of them.
--    The phone reports the connected Wi-Fi name with the punch.
-- 2. Outside work: Admin grants selected employees outside work for chosen
--    days. A granted working day with no punches counts as the full shift
--    (status present, source "outside"); revoking simply removes the credit.

alter table hrms.offices
  add column wifi_ssids text[] not null default '{}' check (cardinality(wifi_ssids) <= 10);

create table hrms.outside_work (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  employee_id uuid not null references hrms.employees(id) on delete restrict,
  work_date date not null,
  reason text not null check (char_length(reason) between 1 and 500),
  granted_by uuid not null references hrms.employees(id),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references hrms.employees(id),
  revoke_reason text check (char_length(revoke_reason) <= 500)
);
create unique index outside_work_active on hrms.outside_work (employee_id, work_date) where revoked_at is null;
create index outside_work_org_date on hrms.outside_work (org_id, work_date);
alter table hrms.outside_work enable row level security;

create or replace function hrms.attendance_rows(
  p_org uuid, p_employee_ids uuid[], p_from date, p_to date, p_now timestamptz
) returns setof hrms.attendance_row
language sql
stable
security definer
set search_path = ''
as $$
  with slots as (
    select ds.employee_id, ds.day,
           case when bool_or(ds.slot = 'FULL') or (bool_or(ds.slot = 'AM') and bool_or(ds.slot = 'PM')) then 3
                when bool_or(ds.slot = 'AM') then 1
                when bool_or(ds.slot = 'PM') then 2 else 0 end as slots
    from hrms.leave_day_slots ds
    where ds.employee_id = any(p_employee_ids) and ds.day between p_from and p_to and ds.state = 'approved'
    group by ds.employee_id, ds.day
  )
  select w.employee_id, w.shift_date, w.id, w.kind, w.is_required, w.timezone, w.start_at, w.end_at,
         w.half_split_at, w.lunch_start_at, w.lunch_end_at, w.lunch_paid, w.grace_seconds, w.expected_seconds,
         w.start_at - make_interval(secs => w.early_entry_seconds),
         w.end_at + make_interval(secs => w.checkout_extension_seconds),
         w.office_id,
         s.id, coalesce(s.state, case when ow.id is not null and p_now >= w.start_at then 'closed' end),
         coalesce(s.effective_in_at, case when ow.id is not null then w.start_at end),
         coalesce(s.effective_out_at, case when ow.id is not null then w.end_at end),
         coalesce(s.effective_source, case when ow.id is not null then 'outside' end),
         coalesce(s.effective_revision, case when ow.id is not null then 0 end),
         coalesce(sl.slots, 0),
         hrms.day_status(w.kind, w.is_required, w.start_at,
                         w.end_at + make_interval(secs => w.checkout_extension_seconds),
                         coalesce(s.state, case when ow.id is not null and p_now >= w.start_at then 'closed' end),
                         coalesce(sl.slots, 0), p_now),
         hrms.calc_day(w.is_required, w.start_at, w.end_at, w.half_split_at, w.expected_seconds,
                       coalesce(sl.slots, 0), w.grace_seconds, w.early_credit, w.checkout_extension_seconds,
                       coalesce(s.effective_in_at, case when ow.id is not null and p_now >= w.start_at then w.start_at end),
                       case when s.state = 'closed' then s.effective_out_at
                            when s.id is null and ow.id is not null and p_now >= w.start_at then w.end_at end)
  from hrms.work_schedule_instances w
  left join hrms.attendance_sessions s on s.schedule_instance_id = w.id
  left join slots sl on sl.employee_id = w.employee_id and sl.day = w.shift_date
  -- Admin-granted outside work: a working day with no punches counts as the full shift.
  left join hrms.outside_work ow
    on ow.employee_id = w.employee_id and ow.work_date = w.shift_date and ow.revoked_at is null
   and w.kind in ('workday', 'extra_workday') and s.id is null
  where w.org_id = p_org
    and w.employee_id = any(p_employee_ids)
    and w.shift_date between p_from and p_to;
$$;


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

  -- Office Wi-Fi: when the office lists Wi-Fi names, the phone must be on one of them.
  if cardinality(v_office.wifi_ssids) > 0 and not exists (
       select 1 from unnest(v_office.wifi_ssids) w
       where lower(btrim(w)) = lower(btrim(coalesce(p_integrity ->> 'wifi_ssid', '')))) then
    return hrms.punch_reject(v_actor.org_id, v_actor.employee_id, p_operation_key, p_action,
      'WIFI_REQUIRED', 'Connect to the office Wi-Fi (' || array_to_string(v_office.wifi_ssids, ' or ') || ') and try again.',
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


create or replace function hrms.office_json(o hrms.offices) returns jsonb
language sql stable set search_path = ''
as $$
  select jsonb_build_object('id', o.id, 'name', o.name, 'timezone', o.timezone,
    'latitude', extensions.st_y(o.location::extensions.geometry), 'longitude', extensions.st_x(o.location::extensions.geometry),
    'radius_m', o.radius_m, 'max_accuracy_m', o.max_accuracy_m, 'max_sample_age_s', o.max_sample_age_s,
    'strict_mode', o.strict_mode, 'active', o.active, 'wifi_ssids', to_jsonb(o.wifi_ssids), 'calibration_status', o.calibration_status,
    'calibration_notes', o.calibration_notes, 'config_version', o.config_version, 'version', o.version,
    'assigned_count', (select count(*) from hrms.office_assignments a join hrms.employees e on e.id = a.employee_id
                       where a.office_id = o.id and e.status = 'active'
                         and daterange(a.effective_from, a.effective_to, '[)') @> hrms.org_today(o.org_id)));
$$;


create or replace function hrms.current_shift(p_actor hrms.actor, p_now timestamptz) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := hrms.org_today(p_actor.org_id);
  v_pick hrms.attendance_row;
  v_in_opens timestamptz;
  v_in_closes timestamptz;
begin
  perform hrms.ensure_schedule_instances(p_actor.org_id, array[p_actor.employee_id], v_today - 1, v_today + 1);
  perform hrms.rollover_stale_sessions(p_actor.employee_id, p_now);

  -- Preference: open session > shift whose check-in window contains now >
  -- today's shift > yesterday's.
  select (x.r).* into v_pick
  from (
    select r, r.shift_date, r.session_state, r.session_id, r.is_required, r.leave_slots,
           (case when r.leave_slots = 1 then r.split_at else r.start_at end)
             - (r.start_at - r.checkin_opens_at) as in_opens,
           case when r.leave_slots = 2 then r.split_at else r.end_at end as in_closes
    from hrms.attendance_rows(p_actor.org_id, array[p_actor.employee_id], v_today - 1, v_today, p_now) r
  ) x
  order by coalesce(x.session_state = 'open', false) desc,
           coalesce(x.session_id is null and x.is_required and x.leave_slots < 3
             and p_now >= x.in_opens and p_now < x.in_closes, false) desc,
           (x.shift_date = v_today) desc,
           x.shift_date desc
  limit 1;

  if not found then
    return null;
  end if;
  v_in_opens := (case when v_pick.leave_slots = 1 then v_pick.split_at else v_pick.start_at end)
                - (v_pick.start_at - v_pick.checkin_opens_at);
  v_in_closes := case when v_pick.leave_slots = 2 then v_pick.split_at else v_pick.end_at end;

  return hrms.attendance_row_json(v_pick) || jsonb_build_object(
    'checkin_opens_at', v_in_opens,
    'checkin_closes_at', v_in_closes,
    'office', (select jsonb_build_object('id', o.id, 'name', o.name, 'radius_m', o.radius_m,
                                         'wifi_ssids', to_jsonb(o.wifi_ssids),
                                         'max_accuracy_m', o.max_accuracy_m,
                                         'max_sample_age_s', o.max_sample_age_s, 'active', o.active,
                                         'latitude', extensions.st_y(o.location::extensions.geometry),
                                         'longitude', extensions.st_x(o.location::extensions.geometry))
               from hrms.offices o where o.id = v_pick.office_id),
    'outside_work', v_pick.effective_source = 'outside',
    'next_action', case
      when v_pick.effective_source = 'outside' then null
      when v_pick.session_state = 'open' and p_now <= v_pick.checkout_closes_at then 'OUT'
      when v_pick.session_id is null and v_pick.is_required and v_pick.leave_slots < 3
           and p_now >= v_in_opens and p_now < v_in_closes then 'IN'
      else null end,
    'blocked_reason', case
      when v_pick.effective_source = 'outside' then 'outside_work'
      when v_pick.leave_slots = 3 then 'on_leave'
      when not v_pick.is_required then v_pick.kind
      when v_pick.office_id is null then 'no_office'
      when v_pick.session_id is null and p_now < v_in_opens then 'not_open_yet'
      when v_pick.session_id is null and p_now >= v_in_closes then 'window_closed'
      when v_pick.session_state = 'closed' then 'completed'
      when v_pick.session_state = 'needs_correction' then 'needs_correction'
      else null end);
end;
$$;


-- Admin sets the office Wi-Fi names (empty list = location only).
create or replace function public.set_office_wifi(p_office_id uuid, p_ssids text[]) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_clean text[];
  v_office hrms.offices;
begin
  perform hrms.require_admin(v_actor);
  select coalesce(array_agg(distinct x), '{}') into v_clean
  from (select hrms.clean_text(s, 64) as x from unnest(coalesce(p_ssids, '{}')) s) t where x is not null;
  if cardinality(v_clean) > 10 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Up to 10 Wi-Fi names.', '{"wifi_ssids":"Up to 10"}'::jsonb);
  end if;
  update hrms.offices set wifi_ssids = v_clean, config_version = config_version + 1, version = version + 1
  where id = p_office_id and org_id = v_actor.org_id
  returning * into v_office;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'office.wifi_changed', 'office', v_office.id,
    jsonb_build_object('wifi_ssids', to_jsonb(v_clean)));
  return hrms.ok(hrms.office_json(v_office));
end;
$$;

-- Admin grants outside work to employees for a date range (max 31 days,
-- 200 people). One set-based insert; days already granted are skipped.
create or replace function public.grant_outside_work(
  p_employee_ids uuid[], p_from date, p_to date, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
  v_ids uuid[];
  v_count integer;
begin
  perform hrms.require_admin(v_actor);
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 30 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Pick up to 31 days.', '{"dates":"Pick up to 31 days"}'::jsonb);
  end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select array_agg(e.id) into v_ids from hrms.employees e
  where e.org_id = v_actor.org_id and e.status = 'active' and e.id = any(p_employee_ids);
  if v_ids is null or cardinality(p_employee_ids) > 200 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose people to send out.', '{"employees":"Choose people"}'::jsonb);
  end if;
  insert into hrms.outside_work (org_id, employee_id, work_date, reason, granted_by)
  select v_actor.org_id, e, d::date, v_reason, v_actor.employee_id
  from unnest(v_ids) e cross join generate_series(p_from, p_to, interval '1 day') d
  on conflict (employee_id, work_date) where revoked_at is null do nothing;
  get diagnostics v_count = row_count;
  perform hrms.ensure_schedule_instances(v_actor.org_id, v_ids, p_from, p_to);
  perform hrms.notify(v_actor.org_id, e, 'attendance.outside_work', 'Outside work approved',
    'Admin marked you on outside work. No check-in is needed on those days.', '/attendance', null,
    md5(e::text || ':outside:' || p_from::text || ':' || p_to::text)::uuid)
  from unnest(v_ids) e;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'attendance.outside_work_granted', 'organization',
    v_actor.org_id, jsonb_build_object('employees', to_jsonb(v_ids), 'from', p_from, 'to', p_to,
                                       'reason', v_reason, 'days_added', v_count));
  return hrms.ok(jsonb_build_object('days_added', v_count));
end;
$$;

create or replace function public.revoke_outside_work(p_id uuid, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
  v_row hrms.outside_work;
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  update hrms.outside_work set revoked_at = now(), revoked_by = v_actor.employee_id, revoke_reason = v_reason
  where id = p_id and org_id = v_actor.org_id and revoked_at is null
  returning * into v_row;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'attendance.outside_work_revoked', 'employee',
    v_row.employee_id, jsonb_build_object('work_date', v_row.work_date, 'reason', v_reason), 'business',
    v_row.employee_id);
  return hrms.ok(jsonb_build_object('id', v_row.id));
end;
$$;

-- Active grants from a date onwards (Admin), newest first, keyset-paged.
create or replace function public.list_outside_work(
  p_from date default null, p_limit integer default 50,
  p_before_date date default null, p_before_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform hrms.require_admin(v_actor);
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'work_date', x.work_date, 'reason', x.reason,
      'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name))
      order by x.work_date desc, x.id desc), '[]'::jsonb)
    from (select * from hrms.outside_work o
          where o.org_id = v_actor.org_id and o.revoked_at is null
            and o.work_date >= coalesce(p_from, hrms.org_today(v_actor.org_id) - 30)
            and (p_before_date is null or (o.work_date, o.id) < (p_before_date, p_before_id))
          order by o.work_date desc, o.id desc limit v_limit) x
    join hrms.employees e on e.id = x.employee_id));
end;
$$;

select hrms.apply_api_grants();
