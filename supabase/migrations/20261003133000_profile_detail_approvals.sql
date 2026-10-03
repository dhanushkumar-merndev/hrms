-- Maker-checker workflow for an employee's own private profile details.
-- Approved values remain authoritative until the locked revision is approved.

create unique index requests_one_active_profile_details
  on hrms.requests (employee_id)
  where kind = 'profile_details' and state in ('submitted', 'under_review', 'returned');

create or replace function hrms.normalize_private_details_patch(p_patch jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_allowed constant text[] := array[
    'personal_email', 'personal_phone', 'address', 'emergency_contact_name',
    'emergency_contact_phone', 'date_of_birth'
  ];
  v_key text;
  v_value text;
  v_date date;
  v_result jsonb := '{}'::jsonb;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Enter at least one personal detail.');
  end if;

  for v_key in select jsonb_object_keys(p_patch) loop
    if not (v_key = any(v_allowed)) then
      perform hrms.raise_error(
        'ACCESS_DENIED', 'This field is managed by HR.',
        jsonb_build_object(v_key, 'Managed by HR'));
    end if;

    if v_key = 'date_of_birth' then
      begin
        v_date := nullif(btrim(p_patch ->> v_key), '')::date;
      exception when others then
        perform hrms.raise_error(
          'VALIDATION_FAILED', 'Invalid date of birth.',
          '{"date_of_birth":"Invalid date"}'::jsonb);
      end;
      if v_date is not null and (v_date > current_date or v_date < date '1900-01-01') then
        perform hrms.raise_error(
          'VALIDATION_FAILED', 'Invalid date of birth.',
          '{"date_of_birth":"Invalid date"}'::jsonb);
      end if;
      v_result := v_result || jsonb_build_object(v_key, v_date);
    else
      v_value := hrms.clean_text(
        p_patch ->> v_key,
        case v_key
          when 'personal_email' then 200
          when 'personal_phone' then 40
          when 'address' then 500
          when 'emergency_contact_name' then 120
          else 40
        end);
      v_result := v_result || jsonb_build_object(v_key, v_value);
    end if;
  end loop;
  return v_result;
end;
$$;

create or replace function hrms.apply_profile_details(
  p_req hrms.requests, p_payload jsonb, p_actor hrms.actor
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_target uuid := hrms.change_target_employee(p_req);
  v_expected integer;
  v_actual integer;
  v_patch jsonb;
begin
  if p_req.kind <> 'profile_details' or v_target <> p_req.employee_id then
    perform hrms.raise_error('VALIDATION_FAILED', 'Invalid profile-details request.');
  end if;
  begin
    v_expected := (p_payload ->> 'target_version')::integer;
  exception when others then
    v_expected := null;
  end;
  if v_expected is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'The proposal has no target version.');
  end if;
  v_patch := hrms.normalize_private_details_patch(p_payload -> 'patch');

  insert into hrms.employee_private_details (employee_id, org_id)
  values (v_target, p_req.org_id) on conflict (employee_id) do nothing;
  select version into v_actual
  from hrms.employee_private_details
  where employee_id = v_target and org_id = p_req.org_id
  for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_actual <> v_expected then
    perform hrms.raise_error(
      'STALE_VERSION', 'Profile details changed after this proposal was submitted.', null, true);
  end if;

  perform hrms.save_private_details(p_actor, v_target, v_patch, v_expected);
end;
$$;

create or replace function hrms.apply_employee_change(
  p_req hrms.requests, p_payload jsonb, p_actor hrms.actor
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not hrms.is_employee_change_kind(p_req.kind) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Not an employee-data request.');
  end if;
  if p_req.kind = 'profile_details' then
    perform hrms.apply_profile_details(p_req, p_payload, p_actor);
    return;
  end if;
  perform hrms.assert_change_target_version(p_req, p_payload);
  perform hrms.raise_error(
    'CHANGE_NOT_IMPLEMENTED', 'This employee-data category is not available in this app version.');
end;
$$;

create or replace function public.save_profile_details_request(
  p_request_id uuid,
  p_patch jsonb,
  p_expected_private_version integer,
  p_expected_request_version integer,
  p_operation_key uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_class text := hrms.change_initiator_class(v_actor);
  v_patch jsonb := hrms.normalize_private_details_patch(p_patch);
  v_req hrms.requests;
  v_current_version integer;
  v_route jsonb;
  v_reviewer uuid;
  v_from text;
  v_payload jsonb;
  v_hash text;
  v_replay jsonb;
  v_result jsonb;
begin
  v_hash := hrms.sha256_hex(concat_ws(
    '|', p_request_id, v_patch::text, p_expected_private_version,
    p_expected_request_version));
  v_replay := hrms.idem_claim(
    v_actor.employee_id, v_actor.org_id, 'profile-details.save',
    p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;

  perform pg_advisory_xact_lock(
    hashtext('profile-details'), hashtext(v_actor.employee_id::text));
  select version into v_current_version
  from hrms.employee_private_details
  where employee_id = v_actor.employee_id;
  v_current_version := coalesce(v_current_version, 1);
  if p_expected_private_version is null or v_current_version <> p_expected_private_version then
    perform hrms.raise_error(
      'STALE_VERSION', 'These details changed. Reload and try again.', null, true);
  end if;

  if v_class = 'admin' then
    if p_request_id is not null then
      perform hrms.raise_error('REQUEST_LOCKED', 'Admin profile changes are applied immediately.');
    end if;
    perform hrms.save_private_details(
      v_actor, v_actor.employee_id, v_patch, p_expected_private_version);
    v_result := hrms.ok(
      jsonb_build_object('applied', true, 'approval_required', false),
      p_expected_private_version + 1);
    perform hrms.idem_complete(
      v_actor.employee_id, 'profile-details.save', p_operation_key, v_result);
    return v_result;
  end if;

  v_route := hrms.change_reviewer(v_actor.org_id, v_actor.employee_id, v_class);
  v_reviewer := nullif(v_route ->> 'reviewer_id', '')::uuid;
  v_payload := jsonb_build_object(
    'target_version', v_current_version,
    'patch', v_patch);

  if p_request_id is null then
    if exists (
      select 1 from hrms.requests
      where employee_id = v_actor.employee_id and kind = 'profile_details'
        and state in ('submitted', 'under_review', 'returned')) then
      perform hrms.raise_error(
        'REQUEST_LOCKED', 'A profile-details request is already pending.');
    end if;
    insert into hrms.requests (
      org_id, employee_id, target_employee_id, kind, state,
      assigned_reviewer_id, route_snapshot, submitted_at
    ) values (
      v_actor.org_id, v_actor.employee_id, v_actor.employee_id,
      'profile_details', 'submitted', v_reviewer,
      v_route || jsonb_build_object(
        'initiator_id', v_actor.employee_id,
        'target_employee_id', v_actor.employee_id,
        'change_category', 'profile_details'),
      now())
    returning * into v_req;
    insert into hrms.request_revisions (
      request_id, revision_no, payload, created_by
    ) values (v_req.id, 1, v_payload, v_actor.employee_id);
    perform hrms.request_event(
      v_req, 'submitted', v_actor.employee_id, null, null, 'submitted');
  else
    select * into v_req
    from hrms.requests where id = p_request_id for update;
    if not found or v_req.org_id <> v_actor.org_id
       or v_req.employee_id <> v_actor.employee_id
       or v_req.kind <> 'profile_details' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state not in ('submitted', 'returned') then
      perform hrms.raise_error(
        'REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if p_expected_request_version is null
       or v_req.version <> p_expected_request_version then
      perform hrms.raise_error(
        'STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
    v_from := v_req.state;
    update hrms.requests set
      current_revision = current_revision + 1,
      version = version + 1,
      state = 'submitted',
      edited = true,
      assigned_reviewer_id = v_reviewer,
      locked_revision = null,
      submitted_at = now(),
      route_snapshot = v_route || jsonb_build_object(
        'initiator_id', v_actor.employee_id,
        'target_employee_id', v_actor.employee_id,
        'change_category', 'profile_details')
    where id = v_req.id returning * into v_req;
    insert into hrms.request_revisions (
      request_id, revision_no, payload, created_by
    ) values (
      v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
    perform hrms.request_event(
      v_req,
      case when v_from = 'returned' then 'resubmitted' else 'edited' end,
      v_actor.employee_id, null, v_from, 'submitted');
  end if;

  if v_reviewer is null then
    perform hrms.alert_missing_reviewer(v_req);
  else
    perform hrms.notify_request(
      v_req, v_reviewer, 'request.submitted',
      'Profile details to review',
      'An employee submitted profile details for approval.', true);
  end if;
  perform hrms.audit(
    v_actor.org_id, v_actor.employee_id,
    'employee.profile_details_submitted', 'request', v_req.id,
    jsonb_build_object(
      'revision', v_req.current_revision,
      'initiator_class', v_class,
      'fields', (select jsonb_agg(k order by k) from jsonb_object_keys(v_patch) k)),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(
    v_actor.employee_id, 'profile-details.save', p_operation_key, v_result);
  return v_result;
end;
$$;

-- Add only safe pending metadata; proposed values remain in authorized request
-- detail and never replace the approved profile projection.
create or replace function public.get_my_profile() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_today date := hrms.org_today(v_actor.org_id);
  v_private hrms.employee_private_details;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  select * into v_private from hrms.employee_private_details where employee_id = v_emp.id;
  return hrms.ok(hrms.employee_card(v_emp, v_today) || jsonb_build_object(
    'join_date', v_emp.join_date, 'end_date', v_emp.end_date, 'status', v_emp.status,
    'roles', to_jsonb(v_actor.roles),
    'manager', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                from hrms.employees e
                where e.id = hrms.manager_of_team_on(hrms.team_on(v_emp.id, v_today), v_today)),
    'office', (select jsonb_build_object('id', o.id, 'name', o.name) from hrms.office_assignments a
               join hrms.offices o on o.id = a.office_id
               where a.employee_id = v_emp.id and daterange(a.effective_from, a.effective_to, '[)') @> v_today),
    'shift', (select jsonb_build_object('id', s.id, 'name', s.name, 'start_local', v.start_local, 'end_local', v.end_local,
                                        'lunch_paid', v.lunch_paid, 'lunch_start_local', v.lunch_start_local,
                                        'lunch_end_local', v.lunch_end_local, 'grace_seconds', v.grace_seconds,
                                        'weekly_mask', v.weekly_mask)
              from hrms.shift_assignments a join hrms.shifts s on s.id = a.shift_id
              join lateral (select * from hrms.shift_versions sv where sv.shift_id = s.id and sv.state = 'published'
                            and sv.effective_from <= v_today order by sv.effective_from desc limit 1) v on true
              where a.employee_id = v_emp.id and daterange(a.effective_from, a.effective_to, '[)') @> v_today),
    'private', jsonb_build_object(
      'personal_email', v_private.personal_email,
      'personal_phone', v_private.personal_phone,
      'address', v_private.address,
      'emergency_contact_name', v_private.emergency_contact_name,
      'emergency_contact_phone', v_private.emergency_contact_phone,
      'date_of_birth', v_private.date_of_birth,
      'version', coalesce(v_private.version, 1)),
    'profile_request', (
      select jsonb_build_object(
        'id', r.id, 'state', r.state, 'version', r.version,
        'submitted_at', r.submitted_at,
        'reviewer_assigned', r.assigned_reviewer_id is not null)
      from hrms.requests r
      where r.employee_id = v_emp.id and r.kind = 'profile_details'
        and r.state in ('submitted', 'under_review', 'returned')
      order by r.created_at desc limit 1),
    'version', v_emp.version));
end;
$$;

select hrms.apply_api_grants();
