-- =============================================================================
-- Attendance read/write API: devices, punch challenges, home summary, own
-- history and day detail. Aggregations are single set-based queries: one
-- grouped pass per table joined onto the schedule rows, never a subquery
-- re-run per day or per employee.
-- =============================================================================

create or replace function hrms.random_token(p_bytes integer default 32) returns text
language sql
volatile
set search_path = ''
as $$
  select rtrim(translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), E'+/\n', '-_'), '=');
$$;

-- Day status used by the app and reports:
-- leave | holiday | weekly_off | day_off | present | in_progress |
-- needs_correction | upcoming | not_yet_in | absent
create or replace function hrms.day_status(
  p_kind text, p_is_required boolean, p_start timestamptz, p_checkout_closes timestamptz,
  p_session_state text, p_leave_slots integer, p_now timestamptz
) returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_leave_slots = 3 then 'leave'
    when p_kind = 'holiday' then 'holiday'
    when p_kind = 'weekly_off' then 'weekly_off'
    when p_kind = 'day_off' then 'day_off'
    when p_session_state = 'closed' then 'present'
    when p_session_state = 'needs_correction' then 'needs_correction'
    when p_session_state = 'open' and p_now > p_checkout_closes then 'needs_correction'
    when p_session_state = 'open' then 'in_progress'
    when not p_is_required then 'weekly_off'
    when p_now < p_start then 'upcoming'
    when p_now <= p_checkout_closes then 'not_yet_in'
    else 'absent'
  end;
$$;

-- Per-day attendance rows for a set of employees over a bounded range.
create type hrms.attendance_row as (
  employee_id uuid, shift_date date, instance_id uuid, kind text, is_required boolean,
  timezone text, start_at timestamptz, end_at timestamptz, split_at timestamptz,
  lunch_start_at timestamptz, lunch_end_at timestamptz, lunch_paid boolean, grace_seconds integer,
  expected_seconds integer, checkin_opens_at timestamptz, checkout_closes_at timestamptz, office_id uuid,
  session_id uuid, session_state text, effective_in_at timestamptz, effective_out_at timestamptz,
  effective_source text, effective_revision integer, leave_slots integer, status text, calc hrms.day_calc
);

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
         s.id, s.state, s.effective_in_at, s.effective_out_at, s.effective_source, s.effective_revision,
         coalesce(sl.slots, 0),
         hrms.day_status(w.kind, w.is_required, w.start_at,
                         w.end_at + make_interval(secs => w.checkout_extension_seconds),
                         s.state, coalesce(sl.slots, 0), p_now),
         hrms.calc_day(w.is_required, w.start_at, w.end_at, w.half_split_at, w.expected_seconds,
                       coalesce(sl.slots, 0), w.grace_seconds, w.early_credit, w.checkout_extension_seconds,
                       s.effective_in_at, case when s.state = 'closed' then s.effective_out_at end)
  from hrms.work_schedule_instances w
  left join hrms.attendance_sessions s on s.schedule_instance_id = w.id
  left join slots sl on sl.employee_id = w.employee_id and sl.day = w.shift_date
  where w.org_id = p_org
    and w.employee_id = any(p_employee_ids)
    and w.shift_date between p_from and p_to;
$$;

create or replace function hrms.attendance_row_json(r hrms.attendance_row) returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'employee_id', r.employee_id, 'shift_date', r.shift_date, 'instance_id', r.instance_id,
    'kind', r.kind, 'is_required', r.is_required, 'status', r.status,
    'start_at', r.start_at, 'end_at', r.end_at, 'split_at', r.split_at,
    'lunch_start_at', r.lunch_start_at, 'lunch_end_at', r.lunch_end_at, 'lunch_paid', r.lunch_paid,
    'checkout_closes_at', r.checkout_closes_at, 'timezone', r.timezone,
    'session_id', r.session_id, 'session_state', r.session_state,
    'effective_in_at', r.effective_in_at, 'effective_out_at', r.effective_out_at,
    'effective_source', r.effective_source, 'effective_revision', r.effective_revision,
    'leave_slots', r.leave_slots,
    'required_start', (r.calc).required_start, 'required_end', (r.calc).required_end,
    'required_seconds', (r.calc).required_seconds, 'presence_seconds', (r.calc).presence_seconds,
    'credited_seconds', (r.calc).credited_seconds, 'shortfall_seconds', (r.calc).shortfall_seconds,
    'extra_seconds', (r.calc).extra_seconds, 'is_late', (r.calc).is_late,
    'late_seconds', (r.calc).late_seconds, 'is_early_departure', (r.calc).is_early_departure,
    'early_seconds', (r.calc).early_seconds, 'leave_conflict_seconds', (r.calc).leave_conflict_seconds
  );
$$;

-- -----------------------------------------------------------------------------
-- Devices
-- -----------------------------------------------------------------------------

create or replace function public.create_device_challenge() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.device_challenges;
begin
  if hrms.rate_limit_hit('device_challenge:' || v_actor.employee_id::text, interval '10 minutes') > 5 then
    perform hrms.raise_error('RATE_LIMITED', 'Too many attempts. Try again in a few minutes.', null, true);
  end if;
  insert into hrms.device_challenges (org_id, employee_id, nonce, expires_at)
  values (v_actor.org_id, v_actor.employee_id, hrms.random_token(32), clock_timestamp() + interval '5 minutes')
  returning * into v_row;
  return hrms.ok(jsonb_build_object('challenge_id', v_row.id, 'nonce', v_row.nonce,
                                    'expires_at', v_row.expires_at));
end;
$$;

-- Called by the device-register Edge Function after verifying the key
-- attestation chain. Replaces any previous active device (audited).
create or replace function public.internal_register_device(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_challenge_id uuid, p_nonce text,
  p_installation_id uuid, p_platform text, p_public_key_spki text, p_attestation_level text,
  p_attestation_summary jsonb, p_device_label text, p_biometric_bound boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_ch hrms.device_challenges;
  v_old hrms.devices;
  v_dev hrms.devices;
begin
  select * into v_ch from hrms.device_challenges where id = p_challenge_id for update;
  if not found or v_ch.employee_id <> v_actor.employee_id or v_ch.consumed_at is not null
     or v_ch.expires_at < clock_timestamp() or v_ch.nonce <> p_nonce then
    perform hrms.raise_error('VERIFICATION_FAILED', 'Registration expired. Please try again.', null, true);
  end if;
  update hrms.device_challenges set consumed_at = clock_timestamp() where id = v_ch.id;

  select * into v_old from hrms.devices where employee_id = v_actor.employee_id and revoked_at is null for update;
  if found then
    update hrms.devices set revoked_at = now(), revoked_by = v_actor.employee_id,
                            revoke_reason = 'Replaced by a new registration'
    where id = v_old.id;
  end if;

  if p_attestation_level = 'hardware' and not coalesce(p_biometric_bound, false)
     and (select require_biometric_punch from hrms.organizations where id = v_actor.org_id) then
    perform hrms.raise_error('VERIFICATION_FAILED',
      'Turn on fingerprint or face unlock on this phone, then register again.');
  end if;
  insert into hrms.devices (org_id, employee_id, installation_id, platform, public_key_spki, attestation_level,
                            attestation_summary, device_label, biometric_bound)
  values (v_actor.org_id, v_actor.employee_id, p_installation_id, p_platform, p_public_key_spki,
          p_attestation_level, coalesce(p_attestation_summary, '{}'::jsonb), hrms.clean_text(p_device_label, 120),
          coalesce(p_biometric_bound, false))
  returning * into v_dev;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'device.registered', 'device', v_dev.id,
    jsonb_build_object('platform', p_platform, 'attestation_level', p_attestation_level,
                       'biometric_bound', v_dev.biometric_bound,
                       'replaced_device_id', v_old.id, 'label', v_dev.device_label),
    'security', v_actor.employee_id);
  if v_old.id is not null then
    perform hrms.notify(v_actor.org_id, v_actor.employee_id, 'device.replaced', 'New phone registered',
      'Punching is now enabled on a new phone. Contact HR if this was not you.', '/settings', null,
      md5(v_dev.id::text || ':replaced')::uuid);
  end if;
  return hrms.ok(jsonb_build_object('device_id', v_dev.id, 'attestation_level', v_dev.attestation_level,
                                    'biometric_bound', v_dev.biometric_bound, 'registered_at', v_dev.registered_at));
end;
$$;

create or replace function public.get_my_device_status(p_installation_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_dev hrms.devices;
begin
  select * into v_dev from hrms.devices where employee_id = v_actor.employee_id and revoked_at is null;
  return hrms.ok(jsonb_build_object(
    'registered', v_dev.id is not null,
    'device_id', v_dev.id,
    'this_installation', v_dev.installation_id is not distinct from p_installation_id,
    'platform', v_dev.platform, 'label', v_dev.device_label,
    'attestation_level', v_dev.attestation_level, 'registered_at', v_dev.registered_at,
    'biometric_bound', v_dev.biometric_bound, 'last_used_at', v_dev.last_used_at,
    'biometric_required', (select require_biometric_punch from hrms.organizations where id = v_actor.org_id)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Punch challenge + operation recovery
-- -----------------------------------------------------------------------------

-- Short-lived (60 s) nonce bound to actor, device, action and target. It is
-- requested BEFORE the GPS sample; the device signs the canonical payload
-- (which includes the sample) only after the sample exists.
create or replace function public.create_punch_challenge(p_action text, p_target_id uuid, p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.punch_challenges;
begin
  if p_action not in ('IN', 'OUT') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown action');
  end if;
  if hrms.rate_limit_hit('punch_challenge:' || v_actor.employee_id::text, interval '1 minute') > 12 then
    perform hrms.raise_error('RATE_LIMITED', 'Too many attempts. Wait a minute and try again.', null, true);
  end if;
  if not exists (select 1 from hrms.devices where id = p_device_id and employee_id = v_actor.employee_id
                 and revoked_at is null) then
    perform hrms.raise_error('VERIFICATION_FAILED', 'Register this phone for punching first.');
  end if;
  if p_action = 'IN' and not exists (
       select 1 from hrms.work_schedule_instances where id = p_target_id and employee_id = v_actor.employee_id) then
    perform hrms.raise_error('INVALID_SHIFT', 'No shift is scheduled for this check-in.');
  end if;
  if p_action = 'OUT' and not exists (
       select 1 from hrms.attendance_sessions where id = p_target_id and employee_id = v_actor.employee_id
         and state = 'open') then
    perform hrms.raise_error('INVALID_PUNCH_SEQUENCE', 'There is no open check-in to close.');
  end if;
  insert into hrms.punch_challenges (org_id, employee_id, device_id, action, target_id, nonce, expires_at)
  values (v_actor.org_id, v_actor.employee_id, p_device_id, p_action, p_target_id, hrms.random_token(32),
          clock_timestamp() + interval '60 seconds')
  returning * into v_row;
  return hrms.ok(jsonb_build_object('challenge_id', v_row.id, 'nonce', v_row.nonce,
    'expires_at', v_row.expires_at, 'server_time', clock_timestamp()));
end;
$$;

-- Recovers the outcome of a punch whose response was lost (actor-owned only).
create or replace function public.get_punch_operation(p_operation_key uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_rec hrms.idempotency_records;
begin
  select * into v_rec from hrms.idempotency_records
  where actor_employee_id = v_actor.employee_id and scope = 'punch' and operation_key = p_operation_key;
  if not found then
    return hrms.ok(jsonb_build_object('found', false));
  end if;
  return hrms.ok(jsonb_build_object('found', true, 'result', v_rec.result));
end;
$$;

-- -----------------------------------------------------------------------------
-- Home summary: one request for the Home screen
-- -----------------------------------------------------------------------------

-- The shift the actor should act on now: an open session's shift, else the
-- (yesterday/today) shift whose check-in window contains now, else today's.
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
  order by (x.session_state = 'open') desc nulls last,
           (x.session_id is null and x.is_required and x.leave_slots < 3
             and p_now >= x.in_opens and p_now < x.in_closes) desc nulls last,
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
                                         'max_accuracy_m', o.max_accuracy_m,
                                         'max_sample_age_s', o.max_sample_age_s, 'active', o.active,
                                         'latitude', extensions.st_y(o.location::extensions.geometry),
                                         'longitude', extensions.st_x(o.location::extensions.geometry))
               from hrms.offices o where o.id = v_pick.office_id),
    'next_action', case
      when v_pick.session_state = 'open' and p_now <= v_pick.checkout_closes_at then 'OUT'
      when v_pick.session_id is null and v_pick.is_required and v_pick.leave_slots < 3
           and p_now >= v_in_opens and p_now < v_in_closes then 'IN'
      else null end,
    'blocked_reason', case
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

-- Team "Who is in" counts for the actor's visible scope today (managed teams
-- for managers; organisation for HR/Admin). One grouped query.
create or replace function hrms.team_today(p_actor hrms.actor, p_now timestamptz) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today date := hrms.org_today(p_actor.org_id);
  v_ids uuid[];
  v_counts jsonb;
begin
  if hrms.has_perm(p_actor, 'reports.org') then
    select array_agg(e.id) into v_ids from hrms.employees e
    where e.org_id = p_actor.org_id and e.status = 'active' and e.id <> p_actor.employee_id;
  elsif hrms.has_perm(p_actor, 'reports.team') then
    select array_agg(distinct m.employee_id) into v_ids
    from hrms.team_managers tm
    join hrms.team_memberships m on m.team_id = tm.team_id
     and daterange(m.effective_from, m.effective_to, '[)') @> v_today
    join hrms.employees e on e.id = m.employee_id and e.status = 'active'
    where tm.manager_id = p_actor.employee_id
      and daterange(tm.effective_from, tm.effective_to, '[)') @> v_today
      and m.employee_id <> p_actor.employee_id;
  else
    return null;
  end if;
  if v_ids is null then
    return jsonb_build_object('total', 0, 'on_time', 0, 'late', 0, 'not_yet_in', 0, 'out_of_office', 0);
  end if;
  perform hrms.ensure_schedule_instances(p_actor.org_id, v_ids, v_today, v_today);
  select jsonb_build_object(
    'total', count(*),
    'on_time', count(*) filter (where r.session_id is not null and not (r.calc).is_late),
    'late', count(*) filter (where r.session_id is not null and (r.calc).is_late),
    'not_yet_in', count(*) filter (where r.session_id is null and r.status in ('not_yet_in', 'upcoming', 'absent')),
    'out_of_office', count(*) filter (where r.status in ('leave', 'holiday', 'weekly_off', 'day_off')))
    into v_counts
  from hrms.attendance_rows(p_actor.org_id, v_ids, v_today, v_today, p_now) r;
  return v_counts;
end;
$$;

create or replace function public.get_home_summary() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_now timestamptz := clock_timestamp();
  v_emp hrms.employees;
  v_org hrms.organizations;
  v_today date;
  v_result jsonb;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_today := hrms.org_today(v_org.id);

  v_result := jsonb_build_object(
    'server_time', v_now,
    'org', jsonb_build_object('name', v_org.name, 'code', v_org.code, 'timezone', v_org.timezone,
                              'support_contact', v_org.support_contact, 'holiday_target', v_org.holiday_target,
                              'require_biometric_punch', v_org.require_biometric_punch),
    'me', jsonb_build_object('id', v_emp.id, 'code', v_emp.employee_code, 'name', v_emp.full_name,
                             'designation', v_emp.designation, 'roles', to_jsonb(v_actor.roles),
                             'permissions', to_jsonb(v_actor.permissions),
                             'has_avatar', v_emp.avatar_file_version_id is not null),
    'today', v_today,
    'shift', hrms.current_shift(v_actor, v_now),
    'device', (select jsonb_build_object('device_id', d.id, 'installation_id', d.installation_id,
                                         'attestation_level', d.attestation_level,
                                         'biometric_bound', d.biometric_bound)
               from hrms.devices d where d.employee_id = v_actor.employee_id and d.revoked_at is null),
    'last_punch', (select jsonb_build_object('action', ev.action, 'at', ev.server_timestamp)
                   from hrms.attendance_events ev where ev.employee_id = v_actor.employee_id
                   order by ev.server_timestamp desc, ev.id desc limit 1),
    'exception_days', (select count(*) from hrms.attendance_sessions s
                       where s.employee_id = v_actor.employee_id and s.state = 'needs_correction'
                         and s.shift_date >= v_today - 45
                         and not exists (select 1 from hrms.requests r where r.employee_id = s.employee_id
                                         and r.kind = 'correction' and r.target_shift_date = s.shift_date
                                         and r.state in ('submitted', 'under_review', 'approved'))),
    'upcoming_holidays', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'date', h.holiday_date,
                                                                       'name', h.name) order by h.holiday_date), '[]'::jsonb)
                          from (select h.* from hrms.holidays h
                                where h.org_id = v_org.id and h.state = 'published' and h.holiday_date >= v_today
                                  and (h.office_id is null or h.office_id = (
                                        select a.office_id from hrms.office_assignments a
                                        where a.employee_id = v_actor.employee_id
                                          and daterange(a.effective_from, a.effective_to, '[)') @> v_today))
                                order by h.holiday_date limit 4) h),
    'team', hrms.team_today(v_actor, v_now),
    'pending_reviews', case when hrms.has_perm(v_actor, 'approvals.review') or hrms.is_admin(v_actor)
                              or exists (select 1 from hrms.requests r where r.assigned_reviewer_id = v_actor.employee_id)
                            then (select count(*) from hrms.requests r
                                  where r.assigned_reviewer_id = v_actor.employee_id
                                    and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending'))
                            end,
    'unassigned_reviews', case when hrms.is_admin(v_actor) then
                            (select count(*) from hrms.requests r where r.org_id = v_org.id
                               and r.assigned_reviewer_id is null
                               and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending'))
                          end,
    'unread_notifications', (select count(*) from hrms.notifications n
                             where n.recipient_id = v_actor.employee_id and n.read_at is null)
  );
  return hrms.ok(v_result || jsonb_build_object('extras', hrms.home_extras(v_actor, v_today)));
end;
$$;

-- Extension point filled by later migrations (payslips, archive tasks).
create or replace function hrms.home_extras(p_actor hrms.actor, p_today date) returns jsonb
language sql
stable
set search_path = ''
as $$ select '{}'::jsonb; $$;

-- -----------------------------------------------------------------------------
-- Own attendance history + day detail
-- -----------------------------------------------------------------------------

create or replace function hrms.attendance_totals(p_rows jsonb) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'required_seconds', coalesce(sum((r ->> 'required_seconds')::integer)
                                   filter (where r ->> 'status' in ('present', 'absent', 'leave')), 0),
    'credited_seconds', coalesce(sum((r ->> 'credited_seconds')::integer)
                                   filter (where r ->> 'status' = 'present'), 0),
    'shortfall_seconds', coalesce(sum((r ->> 'shortfall_seconds')::integer)
                                    filter (where r ->> 'status' in ('present', 'absent')), 0),
    'extra_seconds', coalesce(sum((r ->> 'extra_seconds')::integer) filter (where r ->> 'status' = 'present'), 0),
    'present_days', count(*) filter (where r ->> 'status' = 'present'),
    'absent_days', count(*) filter (where r ->> 'status' = 'absent'),
    'late_days', count(*) filter (where (r ->> 'is_late')::boolean and r ->> 'status' in ('present', 'in_progress', 'needs_correction')),
    'leave_days', count(*) filter (where r ->> 'status' = 'leave'),
    'unresolved_days', count(*) filter (where r ->> 'status' in ('needs_correction', 'in_progress')),
    'is_partial', coalesce(bool_or(r ->> 'status' in ('needs_correction', 'in_progress')), false))
  from jsonb_array_elements(p_rows) r;
$$;

create or replace function public.list_my_attendance(p_from date, p_to date) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_now timestamptz := clock_timestamp();
  v_emp hrms.employees;
  v_from date;
  v_to date;
  v_rows jsonb;
begin
  if p_from is null or p_to is null or p_to < p_from then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a valid date range.', '{"range":"Invalid range"}'::jsonb);
  end if;
  if p_to - p_from > 365 then
    perform hrms.raise_error('RANGE_TOO_LARGE', 'Choose at most 366 days. Use export for longer periods.');
  end if;
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  v_from := greatest(p_from, v_emp.join_date);
  v_to := least(p_to, hrms.org_today(v_actor.org_id) + 31, coalesce(v_emp.end_date, p_to));
  if v_to >= v_from then
    perform hrms.ensure_schedule_instances(v_actor.org_id, array[v_actor.employee_id], v_from, v_to);
    perform hrms.rollover_stale_sessions(v_actor.employee_id, v_now);
  end if;
  select coalesce(jsonb_agg(hrms.attendance_row_json(r) order by r.shift_date desc), '[]'::jsonb) into v_rows
  from hrms.attendance_rows(v_actor.org_id, array[v_actor.employee_id], v_from, v_to, v_now) r;
  return hrms.ok(jsonb_build_object('from', p_from, 'to', p_to, 'server_time', v_now, 'rows', v_rows,
                                    'totals', hrms.attendance_totals(v_rows)));
end;
$$;

-- Day detail for the owner, or for a manager/HR/Admin with report scope over
-- the employee ON THAT WORK DATE (manager: team membership on the date AND
-- current authority over that team).
create or replace function hrms.can_view_attendance(p_actor hrms.actor, p_employee uuid, p_day date) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_employee = p_actor.employee_id
      or (hrms.has_perm(p_actor, 'reports.org')
          and exists (select 1 from hrms.employees e where e.id = p_employee and e.org_id = p_actor.org_id))
      or (hrms.has_perm(p_actor, 'reports.team') and exists (
            select 1
            from hrms.team_memberships m
            join hrms.team_managers tm on tm.team_id = m.team_id
            where m.employee_id = p_employee
              and daterange(m.effective_from, m.effective_to, '[)') @> p_day
              and tm.manager_id = p_actor.employee_id
              and daterange(tm.effective_from, tm.effective_to, '[)') @> hrms.org_today(p_actor.org_id)));
$$;

create or replace function public.get_attendance_day(p_employee_id uuid, p_shift_date date) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp uuid := coalesce(p_employee_id, v_actor.employee_id);
  v_now timestamptz := clock_timestamp();
  v_row hrms.attendance_row;
  v_own boolean;
  v_detail jsonb;
begin
  if not hrms.can_view_attendance(v_actor, v_emp, p_shift_date) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  v_own := v_emp = v_actor.employee_id;
  select * into v_row from hrms.attendance_rows(v_actor.org_id, array[v_emp], p_shift_date, p_shift_date, v_now) r;
  if not found then
    return hrms.ok(jsonb_build_object('shift_date', p_shift_date, 'scheduled', false));
  end if;

  v_detail := hrms.attendance_row_json(v_row) || jsonb_build_object(
    'scheduled', true,
    'employee', (select jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name)
                 from hrms.employees e where e.id = v_emp),
    'shift', (select jsonb_build_object('name', sh.name, 'version_no', sv.version_no,
                                        'effective_from', sv.effective_from, 'start_local', sv.start_local,
                                        'end_local', sv.end_local, 'grace_seconds', sv.grace_seconds,
                                        'lunch_paid', sv.lunch_paid,
                                        'checkout_extension_seconds',
                                          case when sv.checkout_extension_enabled then sv.checkout_extension_seconds else 0 end)
              from hrms.work_schedule_instances w
              join hrms.shift_versions sv on sv.id = w.shift_version_id
              join hrms.shifts sh on sh.id = sv.shift_id
              where w.id = v_row.instance_id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', ev.id, 'action', ev.action, 'at', ev.server_timestamp,
                 'distance_m', round(ev.distance_m::numeric, 1), 'accuracy_m', round(ev.accuracy_m::numeric, 1),
                 'integrity_level', ev.integrity ->> 'level',
                 'office_config_version', ev.office_config_version,
                 -- Coordinates only on the owner's own view.
                 'latitude', case when v_own then ev.latitude end,
                 'longitude', case when v_own then ev.longitude end) order by ev.server_timestamp), '[]'::jsonb)
               from hrms.attendance_events ev where ev.session_id = v_row.session_id),
    'adjustments', (select coalesce(jsonb_agg(jsonb_build_object(
                      'revision', a.revision, 'effective_in_at', a.effective_in_at,
                      'effective_out_at', a.effective_out_at, 'reason', a.reason, 'created_at', a.created_at,
                      'approved_by', (select e.full_name from hrms.employees e where e.id = a.approved_by))
                      order by a.revision), '[]'::jsonb)
                    from hrms.attendance_adjustments a where a.session_id = v_row.session_id),
    'correction_requests', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'state', r.state,
                              'submitted_at', r.submitted_at) order by r.created_at desc), '[]'::jsonb)
                            from hrms.requests r where r.employee_id = v_emp and r.kind = 'correction'
                              and r.target_shift_date = p_shift_date and (v_own or hrms.has_perm(v_actor, 'reports.org')))
  );
  if not v_own then
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'attendance.viewed', 'attendance_day', v_row.instance_id,
      jsonb_build_object('shift_date', p_shift_date), 'access', v_emp);
  end if;
  return hrms.ok(v_detail);
end;
$$;

select hrms.apply_api_grants();
