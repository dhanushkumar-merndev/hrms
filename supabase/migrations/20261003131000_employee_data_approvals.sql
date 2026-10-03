-- Shared maker-checker routing and lifecycle for employee-data changes.
-- Domain-specific proposal/apply functions are layered on this engine by the
-- following migrations; this file owns role routing, reviewer authority,
-- immutable revision locking, idempotent decisions, and safe list metadata.

alter table hrms.requests drop constraint requests_kind_check;
alter table hrms.requests add constraint requests_kind_check check (kind in (
  'leave', 'correction', 'bank_details', 'profile_details', 'employee_details',
  'employee_assignment', 'employee_status', 'salary_change', 'payslip_publish'
));

alter table hrms.requests add column target_employee_id uuid;
alter table hrms.requests add constraint requests_target_employee_fk
  foreign key (org_id, target_employee_id) references hrms.employees(org_id, id) on delete restrict;
create index requests_target_employee_idx
  on hrms.requests (target_employee_id, created_at desc, id)
  where target_employee_id is not null;

create or replace function hrms.is_employee_change_kind(p_kind text) returns boolean
language sql immutable set search_path = '' as $$
  select p_kind in (
    'profile_details', 'employee_details', 'employee_assignment',
    'employee_status', 'salary_change', 'payslip_publish'
  );
$$;

create or replace function hrms.change_initiator_class(p_actor hrms.actor) returns text
language sql immutable set search_path = '' as $$
  select case
    when 'admin' = any(p_actor.roles) then 'admin'
    when 'hr' = any(p_actor.roles) then 'hr'
    else 'employee'
  end;
$$;

-- Route from the maker's role snapshot, not from the target employee or the
-- maker's permissions. Member/Manager prefer HR then Admin; HR is Admin-only.
create or replace function hrms.change_reviewer(
  p_org uuid, p_initiator uuid, p_initiator_class text
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_reviewer uuid;
  v_rule text;
begin
  if p_initiator_class = 'admin' then
    return jsonb_build_object(
      'reviewer_id', null, 'reviewer_rule', 'direct',
      'initiator_class', 'admin', 'reason', 'admin_direct');
  elsif p_initiator_class = 'hr' then
    v_rule := 'admin_only';
    select e.id into v_reviewer
    from hrms.employees e
    where e.org_id = p_org and e.id <> p_initiator
      and e.status = 'active' and e.provisioning_state = 'complete'
      and 'admin' = any(hrms.employee_roles(e.id))
    order by e.employee_code, e.id
    limit 1;
  elsif p_initiator_class = 'employee' then
    v_rule := 'hr_or_admin';
    select e.id into v_reviewer
    from hrms.employees e
    where e.org_id = p_org and e.id <> p_initiator
      and e.status = 'active' and e.provisioning_state = 'complete'
      and hrms.employee_roles(e.id) && array['hr', 'admin']
    order by case when 'hr' = any(hrms.employee_roles(e.id))
                       and not ('admin' = any(hrms.employee_roles(e.id))) then 0
                  when 'hr' = any(hrms.employee_roles(e.id)) then 1 else 2 end,
             e.employee_code, e.id
    limit 1;
  else
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown employee-change initiator class.');
  end if;

  return jsonb_build_object(
    'reviewer_id', v_reviewer,
    'reviewer_rule', v_rule,
    'initiator_class', p_initiator_class,
    'reason', case when v_reviewer is null then 'no_eligible_reviewer' end);
end;
$$;

create or replace function hrms.change_review_authority(
  p_actor hrms.actor, p_req hrms.requests
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_class text := p_req.route_snapshot ->> 'initiator_class';
begin
  if p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then
    return null;
  end if;
  if v_class not in ('employee', 'hr') then
    return null;
  end if;

  if v_class = 'hr' then
    if not hrms.is_admin(p_actor) then return null; end if;
  elsif not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then
    return null;
  end if;

  if p_req.assigned_reviewer_id = p_actor.employee_id then
    return 'assigned';
  end if;
  if hrms.is_admin(p_actor) then
    return 'admin';
  end if;
  return null;
end;
$$;

-- Preserve the purpose-built leave/correction/bank rules while delegating the
-- new request kinds to the initiator-based authority matrix.
create or replace function hrms.review_authority(p_actor hrms.actor, p_req hrms.requests) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when hrms.is_employee_change_kind(p_req.kind)
      then hrms.change_review_authority(p_actor, p_req)
    when p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then null
    when p_req.kind = 'bank_details' and p_req.route_snapshot ->> 'mode' = 'change'
         and not hrms.is_admin(p_actor) then null
    when p_req.assigned_reviewer_id = p_actor.employee_id then 'assigned'
    when hrms.is_admin(p_actor) then 'admin'
    else null
  end;
$$;

create or replace function hrms.change_target_employee(p_req hrms.requests) returns uuid
language sql stable set search_path = '' as $$
  select coalesce(
    p_req.target_employee_id,
    case when coalesce(p_req.route_snapshot ->> 'target_employee_id', '')
                   ~ '^[0-9a-fA-F-]{36}$'
         then (p_req.route_snapshot ->> 'target_employee_id')::uuid end,
    p_req.employee_id);
$$;

-- Locks and compares the approved target immediately before any domain apply.
create or replace function hrms.assert_change_target_version(
  p_req hrms.requests, p_payload jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_target uuid := hrms.change_target_employee(p_req);
  v_expected integer;
  v_actual integer;
begin
  begin
    v_expected := (p_payload ->> 'target_version')::integer;
  exception when others then
    v_expected := null;
  end;
  if v_expected is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'The proposal has no target version.');
  end if;
  select e.version into v_actual
  from hrms.employees e
  where e.id = v_target and e.org_id = p_req.org_id
  for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_actual <> v_expected then
    perform hrms.raise_error(
      'STALE_VERSION', 'Employee data changed after this proposal was submitted.', null, true);
  end if;
end;
$$;

-- One dispatch point keeps request approval and domain application in the
-- same transaction. Following domain migrations replace the unsupported
-- branches with their fully validated application logic.
create or replace function hrms.apply_employee_change(
  p_req hrms.requests, p_payload jsonb, p_actor hrms.actor
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not hrms.is_employee_change_kind(p_req.kind) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Not an employee-data request.');
  end if;
  perform hrms.assert_change_target_version(p_req, p_payload);
  perform hrms.raise_error(
    'CHANGE_NOT_IMPLEMENTED', 'This employee-data category is not available in this app version.');
end;
$$;

create or replace function hrms.change_category_label(p_kind text) returns text
language sql immutable set search_path = '' as $$
  select case p_kind
    when 'profile_details' then 'Profile details'
    when 'employee_details' then 'Employee details'
    when 'employee_assignment' then 'Employee assignment'
    when 'employee_status' then 'Employee status'
    when 'salary_change' then 'Salary change'
    when 'payslip_publish' then 'Payslip publication'
    when 'bank_details' then 'Bank details'
    else 'Request' end;
$$;

-- Safe queue/list projection: category and target identity only; never the
-- revision payload, reason, salary, phone, bank value, or file reference.
create or replace function hrms.request_summary(p_req hrms.requests) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p_req.id, 'kind', p_req.kind, 'state', p_req.state, 'version', p_req.version,
    'current_revision', p_req.current_revision, 'edited', p_req.edited,
    'request_mode', p_req.route_snapshot ->> 'mode',
    'initiator_class', p_req.route_snapshot ->> 'initiator_class',
    'change_category', case when hrms.is_employee_change_kind(p_req.kind)
                            then hrms.change_category_label(p_req.kind) end,
    'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name),
    'target_employee', case when t.id is null then null else
      jsonb_build_object('id', t.id, 'code', t.employee_code, 'name', t.full_name) end,
    'leave_type', case when lt.id is null then null else
      jsonb_build_object('id', lt.id, 'code', lt.code, 'name', lt.name) end,
    'start_date', p_req.start_date, 'end_date', p_req.end_date, 'units', p_req.units,
    'target_shift_date', p_req.target_shift_date,
    'submitted_at', p_req.submitted_at, 'first_opened_at', p_req.first_opened_at,
    'reviewer_assigned', p_req.assigned_reviewer_id is not null,
    'created_at', p_req.created_at, 'updated_at', p_req.updated_at
  )
  from hrms.employees e
  left join hrms.employees t on t.id = hrms.change_target_employee(p_req)
  left join hrms.leave_types lt on lt.id = p_req.leave_type_id
  where e.id = p_req.employee_id;
$$;

-- Shared decision implementation. Request row lock + target lock + apply +
-- state transition are one PostgreSQL transaction.
create or replace function hrms.decide_request_core(
  p_actor hrms.actor, p_request_id uuid, p_decision text,
  p_reason text, p_expected_version integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_req hrms.requests;
  v_authority text;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_payload jsonb;
  v_to text;
begin
  if p_decision not in ('approve', 'reject', 'return') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown decision');
  end if;
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.employee_id = p_actor.employee_id then
    perform hrms.raise_error('SELF_APPROVAL_FORBIDDEN', 'You cannot decide your own request.');
  end if;
  v_authority := hrms.review_authority(p_actor, v_req);
  if v_authority is null then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.state <> 'under_review' or v_req.version <> p_expected_version
     or v_req.locked_revision is distinct from v_req.current_revision then
    perform hrms.raise_error(
      'STALE_VERSION', 'This request changed. Reload it before deciding.', null, true);
  end if;
  if (p_decision in ('reject', 'return') or v_authority = 'admin') and v_reason is null then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;

  select payload into v_payload from hrms.request_revisions
  where request_id = v_req.id and revision_no = v_req.locked_revision;
  if not found then perform hrms.raise_error('STALE_VERSION', 'The reviewed revision is unavailable.'); end if;

  if p_decision = 'approve' then
    if v_req.kind = 'leave' then
      if hrms.leave_attendance_conflicts(v_req.employee_id, v_payload -> 'days') > 0 then
        perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
          'Attendance was recorded during this leave. Return it for correction instead.');
      end if;
      perform hrms.debit_request(v_req.id, v_req.current_revision, p_actor.employee_id);
    elsif v_req.kind = 'correction' then
      perform hrms.apply_correction(v_req, v_payload, p_actor.employee_id, v_reason);
    elsif v_req.kind = 'bank_details' then
      perform hrms.apply_bank_details(v_req, v_payload, p_actor);
    else
      perform hrms.apply_employee_change(v_req, v_payload, p_actor);
    end if;
    v_to := 'approved';
  elsif p_decision = 'reject' then
    perform hrms.release_request_holds(v_req.id);
    v_to := 'rejected';
  else
    perform hrms.release_request_holds(v_req.id);
    v_to := 'returned';
  end if;

  update hrms.requests set
    state = v_to, version = version + 1, decided_at = now(),
    decided_by = p_actor.employee_id,
    approved_revision = case when v_to = 'approved' then current_revision else approved_revision end
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req,
    case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'returned' end,
    p_actor.employee_id, v_reason, 'under_review', v_to);
  perform hrms.notify_request(v_req, v_req.employee_id, 'request.' || v_to,
    case when v_to = 'approved' then hrms.change_category_label(v_req.kind) || ' approved'
         when v_to = 'rejected' then 'Request not approved'
         else 'Request returned for changes' end,
    case when v_to = 'returned'
      then 'Your approver asked for changes. Open the request to update it.'
      else 'Open the app to see the details.' end, false);
  perform hrms.audit(p_actor.org_id, p_actor.employee_id, 'request.' || p_decision,
    'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'authority', v_authority,
                       'reason', v_reason, 'category', v_req.kind,
                       'target_employee_id', hrms.change_target_employee(v_req)),
    'business', hrms.change_target_employee(v_req));
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

create or replace function public.decide_request(
  p_request_id uuid, p_decision text, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return hrms.decide_request_core(
    hrms.current_actor(), p_request_id, p_decision, p_reason, p_expected_version);
end;
$$;

create or replace function public.decide_request(
  p_request_id uuid, p_decision text, p_reason text,
  p_expected_version integer, p_operation_key uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_hash text;
  v_replay jsonb;
  v_result jsonb;
begin
  v_hash := hrms.sha256_hex(concat_ws(
    '|', p_request_id, p_decision, hrms.clean_text(p_reason, 1000), p_expected_version));
  v_replay := hrms.idem_claim(
    v_actor.employee_id, v_actor.org_id, 'request.decide', p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;
  v_result := hrms.decide_request_core(
    v_actor, p_request_id, p_decision, p_reason, p_expected_version);
  perform hrms.idem_complete(v_actor.employee_id, 'request.decide', p_operation_key, v_result);
  return v_result;
end;
$$;

create or replace function public.reassign_request(
  p_request_id uuid, p_new_reviewer_id uuid, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_old uuid;
  v_roles text[];
  v_class text;
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_reason is null then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_req from hrms.requests
  where id = p_request_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if v_req.state not in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending') then
    perform hrms.raise_error('REQUEST_LOCKED', 'Only pending requests can be reassigned.');
  end if;
  if not hrms.is_eligible_reviewer(p_new_reviewer_id, v_req.employee_id) then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Choose an eligible approver other than the requester.',
      '{"reviewer_id":"Not an eligible approver"}'::jsonb);
  end if;

  v_roles := hrms.employee_roles(p_new_reviewer_id);
  if hrms.is_employee_change_kind(v_req.kind) then
    v_class := v_req.route_snapshot ->> 'initiator_class';
    if (v_class = 'hr' and not ('admin' = any(v_roles)))
       or (v_class = 'employee' and not (v_roles && array['hr', 'admin']))
       or v_class not in ('employee', 'hr') then
      perform hrms.raise_error(
        'VALIDATION_FAILED',
        case when v_class = 'hr'
          then 'HR-originated changes must be assigned to an Admin.'
          else 'Employee changes must be assigned to HR or Admin.' end,
        '{"reviewer_id":"Not allowed for this employee-data request"}'::jsonb);
    end if;
  elsif v_req.kind = 'bank_details' then
    if (v_req.route_snapshot ->> 'mode' = 'change' and not ('admin' = any(v_roles)))
       or (v_req.route_snapshot ->> 'mode' <> 'change'
           and not (v_roles && array['hr', 'admin'])) then
      perform hrms.raise_error(
        'VALIDATION_FAILED', 'Choose an eligible bank-details approver.',
        '{"reviewer_id":"Not allowed for this bank request"}'::jsonb);
    end if;
  end if;

  v_old := v_req.assigned_reviewer_id;
  update hrms.requests set
    assigned_reviewer_id = p_new_reviewer_id,
    version = version + 1,
    route_snapshot = coalesce(route_snapshot, '{}'::jsonb)
      || jsonb_build_object('reassigned_from', v_old, 'reassigned_by', v_actor.employee_id)
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(
    v_req, 'reassigned', v_actor.employee_id, v_reason, v_req.state, v_req.state);
  perform hrms.notify_request(
    v_req, p_new_reviewer_id, 'request.reassigned', 'Request assigned to you',
    'A request was assigned to you for review.', true);
  perform hrms.audit(
    v_actor.org_id, v_actor.employee_id, 'request.reassigned', 'request', v_req.id,
    jsonb_build_object('from', v_old, 'to', p_new_reviewer_id,
                       'reason', v_reason, 'category', v_req.kind),
    'business', hrms.change_target_employee(v_req));
  return hrms.ok(hrms.request_summary(v_req), v_req.version);
end;
$$;

select hrms.apply_api_grants();
