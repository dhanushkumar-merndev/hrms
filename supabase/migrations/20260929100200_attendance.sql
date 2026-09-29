-- =============================================================================
-- Devices, punch challenges, attendance sessions/events, adjustments and the
-- transactional punch commit (architecture.md §5.1).
--
-- Integrity for internal (non-store) distribution: each app installation
-- registers a hardware-backed signing key whose Android Key Attestation chain
-- is verified by the device-register Edge Function. Every punch payload is
-- signed with that key and verified at the edge before commit. The database
-- stores only the verified public key and a summary — never raw proofs.
-- =============================================================================

create table hrms.devices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  installation_id uuid not null,
  platform text not null check (platform in ('android', 'ios')),
  key_algorithm text not null default 'ES256' check (key_algorithm in ('ES256')),
  public_key_spki text not null check (char_length(public_key_spki) between 60 and 400),
  attestation_level text not null check (attestation_level in ('hardware', 'software')),
  attestation_summary jsonb not null default '{}'::jsonb,
  -- Hardware-verified: the key cannot sign without a fresh strong biometric,
  -- and is destroyed if a new biometric is enrolled on the phone.
  biometric_bound boolean not null default false,
  device_label text check (char_length(device_label) <= 120),
  registered_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text check (char_length(revoke_reason) <= 300),
  unique (employee_id, installation_id, registered_at),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
-- One active signing device per employee; registering a new one revokes the old.
create unique index devices_one_active on hrms.devices (employee_id) where revoked_at is null;

create table hrms.device_challenges (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  nonce text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create index device_challenges_emp_idx on hrms.device_challenges (employee_id, created_at desc);

create table hrms.punch_challenges (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  device_id uuid not null references hrms.devices(id) on delete restrict,
  action text not null check (action in ('IN', 'OUT')),
  target_id uuid not null,
  nonce text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  consumed_operation_key uuid,
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create index punch_challenges_emp_idx on hrms.punch_challenges (employee_id, created_at desc);
create index punch_challenges_expiry_idx on hrms.punch_challenges (expires_at) where consumed_at is null;

create table hrms.attendance_sessions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  schedule_instance_id uuid not null unique references hrms.work_schedule_instances(id) on delete restrict,
  shift_date date not null,
  state text not null check (state in ('open', 'closed', 'needs_correction')),
  in_event_id uuid,
  out_event_id uuid,
  effective_in_at timestamptz,
  effective_out_at timestamptz,
  effective_source text not null default 'gps' check (effective_source in ('gps', 'manual', 'mixed')),
  effective_revision integer not null default 0,
  needs_correction_reason text check (needs_correction_reason in ('missing_out', 'missing_in')),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  check (effective_out_at is null or effective_in_at is null or effective_out_at > effective_in_at)
);
-- At most one open session per employee.
create unique index attendance_sessions_one_open on hrms.attendance_sessions (employee_id) where state = 'open';
create index attendance_sessions_org_date_idx on hrms.attendance_sessions (org_id, shift_date desc, employee_id, id);
create index attendance_sessions_emp_date_idx on hrms.attendance_sessions (employee_id, shift_date desc, id);
create trigger attendance_sessions_touch before update on hrms.attendance_sessions
  for each row execute function hrms.touch_updated_at();
create trigger attendance_sessions_no_delete before delete on hrms.attendance_sessions
  for each row execute function hrms.forbid_mutation();

-- Accepted punch events: append-only evidence.
create table hrms.attendance_events (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  session_id uuid not null references hrms.attendance_sessions(id) on delete restrict,
  action text not null check (action in ('IN', 'OUT')),
  server_timestamp timestamptz not null,
  committed_at timestamptz not null default clock_timestamp(),
  operation_key uuid not null,
  latitude double precision not null,
  longitude double precision not null,
  accuracy_m double precision not null,
  sample_at timestamptz not null,
  distance_m double precision not null,
  office_id uuid not null,
  office_config_version integer not null,
  device_id uuid not null references hrms.devices(id) on delete restrict,
  integrity jsonb not null,
  policy_snapshot jsonb not null,
  unique (employee_id, operation_key)
);
create index attendance_events_emp_time_idx on hrms.attendance_events (employee_id, server_timestamp desc, id);
create index attendance_events_session_idx on hrms.attendance_events (session_id, server_timestamp, id);
create trigger attendance_events_append_only before update or delete on hrms.attendance_events
  for each row execute function hrms.forbid_mutation();

-- Rejected punch attempts, kept separate from accepted evidence.
create table hrms.punch_rejections (
  id bigint generated always as identity primary key,
  org_id uuid,
  employee_id uuid,
  operation_key uuid,
  action text,
  code text not null,
  detail jsonb,
  receipt_at timestamptz,
  created_at timestamptz not null default now()
);
create index punch_rejections_emp_idx on hrms.punch_rejections (employee_id, created_at desc);

-- Approved corrections: append-only effective revisions of a session. The
-- original events are never changed; the session's effective_* columns are
-- a derived projection of the latest revision.
create table hrms.attendance_adjustments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  session_id uuid not null references hrms.attendance_sessions(id) on delete restrict,
  revision integer not null,
  based_on_revision integer not null,
  effective_in_at timestamptz not null,
  effective_out_at timestamptz not null,
  request_id uuid,
  approved_by uuid not null,
  reason text not null check (char_length(reason) between 1 and 1000),
  created_at timestamptz not null default now(),
  unique (session_id, revision),
  check (effective_out_at > effective_in_at),
  check (revision = based_on_revision + 1)
);
create trigger attendance_adjustments_append_only before update or delete on hrms.attendance_adjustments
  for each row execute function hrms.forbid_mutation();

-- Removes and rebuilds FUTURE schedule instances that have no attendance,
-- after a holiday/shift/assignment change (prospective reconciliation).
create or replace function hrms.refresh_future_instances(
  p_org uuid, p_employee_ids uuid[], p_from date, p_to date
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := hrms.org_today(p_org);
  v_from date := greatest(p_from, v_today + 1);
begin
  if p_to < v_from then return; end if;
  perform set_config('hrms.schedule_refresh', 'on', true);
  delete from hrms.work_schedule_instances w
  where w.org_id = p_org
    and w.employee_id = any(p_employee_ids)
    and w.shift_date between v_from and p_to
    and not exists (select 1 from hrms.attendance_sessions s where s.schedule_instance_id = w.id);
  perform set_config('hrms.schedule_refresh', 'off', true);
  perform hrms.ensure_schedule_instances(p_org, p_employee_ids, v_from, p_to);
end;
$$;

-- Marks the employee's open sessions whose last permitted checkout has passed
-- as needs_correction, WITHOUT inventing an OUT event. Called lazily by the
-- next IN (under the employee lock), by reads, and by the maintenance runner.
create or replace function hrms.rollover_stale_sessions(p_employee uuid, p_at timestamptz)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update hrms.attendance_sessions s
     set state = 'needs_correction',
         needs_correction_reason = 'missing_out',
         version = s.version + 1
    from hrms.work_schedule_instances w
   where s.employee_id = p_employee
     and s.state = 'open'
     and w.id = s.schedule_instance_id
     and w.end_at + make_interval(secs => w.checkout_extension_seconds) < p_at;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Canonical punch payload (v1). Exact UTF-8 bytes signed by the device key:
--   lines joined by '\n', no trailing newline:
--   hrms-punch-v1, challenge_id, nonce, operation_key, employee_id, device_id,
--   action, target_id, office_id, latitude (7 dp), longitude (7 dp),
--   accuracy (2 dp), sample_at (epoch milliseconds)
-- Numbers travel as the exact decimal strings used in the payload.
-- -----------------------------------------------------------------------------
create or replace function hrms.punch_payload_v1(
  p_challenge_id uuid, p_nonce text, p_operation_key uuid, p_employee uuid, p_device uuid,
  p_action text, p_target uuid, p_office uuid, p_lat text, p_lng text, p_accuracy text,
  p_sample_ms bigint
) returns text
language sql
immutable
set search_path = ''
as $$
  select concat_ws(E'\n', 'hrms-punch-v1', p_challenge_id::text, p_nonce, p_operation_key::text,
                   p_employee::text, p_device::text, p_action, p_target::text, p_office::text,
                   p_lat, p_lng, p_accuracy, p_sample_ms::text);
$$;

create or replace function hrms.sha256_hex(p text) returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(p, 'UTF8'), 'sha256'), 'hex');
$$;

-- Approved leave slots on a date: 0 none, 1 AM, 2 PM, 3 full. Defined here as
-- a stub returning 0 and replaced by the leave migration.
create or replace function hrms.approved_leave_slots(p_employee uuid, p_day date) returns integer
language sql
stable
set search_path = ''
as $$ select 0; $$;

-- Session + schedule projection returned to the app after punches/reads.
create or replace function hrms.session_view(p_session_id uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'session_id', s.id,
    'schedule_instance_id', s.schedule_instance_id,
    'shift_date', s.shift_date,
    'state', s.state,
    'effective_in_at', s.effective_in_at,
    'effective_out_at', s.effective_out_at,
    'effective_source', s.effective_source,
    'effective_revision', s.effective_revision,
    'needs_correction_reason', s.needs_correction_reason,
    'version', s.version,
    'checkout_closes_at', w.end_at + make_interval(secs => w.checkout_extension_seconds)
  )
  from hrms.attendance_sessions s
  join hrms.work_schedule_instances w on w.id = s.schedule_instance_id
  where s.id = p_session_id;
$$;

-- Records a rejected attempt and returns the rejection envelope. Business
-- rejections are RETURNED (not raised) so this log row commits.
create or replace function hrms.punch_reject(
  p_org uuid, p_employee uuid, p_key uuid, p_action text, p_code text, p_message text,
  p_detail jsonb, p_receipt timestamptz, p_retryable boolean default false
) returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  insert into hrms.punch_rejections (org_id, employee_id, operation_key, action, code, detail, receipt_at)
  values (p_org, p_employee, p_key, p_action, p_code, hrms.redact(p_detail), p_receipt);
  return jsonb_build_object(
    'ok', false,
    'error', jsonb_build_object('code', p_code, 'message', p_message, 'retryable', p_retryable),
    'request_id', hrms.request_id()
  );
end;
$$;

-- Looks up a committed punch for the actor's operation key. Returns the
-- original result when the payload hash matches (even if the challenge,
-- location or proof has since expired), a conflict for a different payload,
-- or {found:false}.
create or replace function public.internal_punch_lookup(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_operation_key uuid, p_payload_hash text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_rec hrms.idempotency_records;
begin
  select * into v_rec from hrms.idempotency_records
  where actor_employee_id = v_actor.employee_id and scope = 'punch' and operation_key = p_operation_key;
  if not found then
    return jsonb_build_object('found', false);
  end if;
  if v_rec.request_hash <> p_payload_hash then
    return jsonb_build_object('found', true, 'conflict', true);
  end if;
  return jsonb_build_object('found', true, 'conflict', false, 'result', v_rec.result);
end;
$$;

-- Device public key for edge signature verification (actor-owned only).
create or replace function public.internal_device_key(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_device_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_dev hrms.devices;
begin
  select * into v_dev from hrms.devices
  where id = p_device_id and employee_id = v_actor.employee_id and revoked_at is null;
  if not found then
    return jsonb_build_object('found', false);
  end if;
  return jsonb_build_object('found', true, 'employee_id', v_actor.employee_id,
    'public_key_spki', v_dev.public_key_spki, 'attestation_level', v_dev.attestation_level,
    'platform', v_dev.platform);
end;
$$;

-- The authoritative punch commit. Called ONLY by the punch Edge Function
-- (service_role) after it verified the JWT, reconstructed the canonical
-- payload and verified the device signature. p_receipt_at is the trusted
-- edge receipt time; no external caller can supply it.
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

  v_policy := jsonb_build_object(
    'office_config_version', v_office.config_version,
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

-- Records a punch rejected at the edge (bad signature, malformed payload) so
-- security review sees it; returns nothing.
create or replace function public.internal_log_punch_rejection(
  p_auth_user_id uuid, p_code text, p_detail jsonb, p_ip_hash text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_emp hrms.employees;
begin
  select * into v_emp from hrms.employees where auth_user_id = p_auth_user_id;
  insert into hrms.punch_rejections (org_id, employee_id, code, detail, receipt_at)
  values (v_emp.org_id, v_emp.id, left(p_code, 60), hrms.redact(p_detail), now());
  perform hrms.security_event(v_emp.org_id, v_emp.id, 'punch.edge_rejected',
    jsonb_build_object('code', left(p_code, 60)), p_ip_hash);
end;
$$;

do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'hrms' loop
    execute format('alter table hrms.%I enable row level security', r.tablename);
  end loop;
end $$;

select hrms.apply_api_grants();
