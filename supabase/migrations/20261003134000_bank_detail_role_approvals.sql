-- Bank-detail routing follows the maker's effective role, just like every
-- other employee-data change. Admin self-service applies immediately.

create or replace function hrms.review_authority(
  p_actor hrms.actor, p_req hrms.requests
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_assigned_valid boolean;
begin
  if p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then
    return null;
  end if;
  if hrms.is_employee_change_kind(p_req.kind)
     or (p_req.kind = 'bank_details'
         and p_req.route_snapshot ->> 'initiator_class' in ('employee', 'hr')) then
    return hrms.change_review_authority(p_actor, p_req);
  end if;
  if p_req.kind = 'leave' then
    if not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then return null; end if;
    if p_req.assigned_reviewer_id = p_actor.employee_id then return 'assigned'; end if;
    if hrms.is_admin(p_actor) then return 'admin'; end if;
    v_assigned_valid := hrms.is_hr_admin_reviewer(
      p_req.assigned_reviewer_id, p_req.employee_id);
    if not coalesce(v_assigned_valid, false) then return 'pool'; end if;
    return null;
  end if;
  if p_req.kind = 'bank_details'
     and p_req.route_snapshot ->> 'mode' = 'change'
     and not hrms.is_admin(p_actor) then return null; end if;
  if p_req.assigned_reviewer_id = p_actor.employee_id then return 'assigned'; end if;
  if hrms.is_admin(p_actor) then return 'admin'; end if;
  return null;
end;
$$;

create or replace function hrms.apply_bank_values(
  p_actor hrms.actor,
  p_employee_id uuid,
  p_payload jsonb,
  p_request_id uuid default null
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_previous_guard text := coalesce(current_setting('hrms.bank_approval_apply', true), '');
  v_version integer;
  v_proof uuid;
begin
  begin
    v_proof := (p_payload ->> 'attachment_file_version_id')::uuid;
  exception when others then
    v_proof := null;
  end;
  if v_proof is null or not exists (
    select 1
    from hrms.file_versions fv
    join hrms.file_records fr on fr.id = fv.file_record_id
    where fv.id = v_proof
      and fr.org_id = p_actor.org_id
      and fr.owner_employee_id = p_employee_id
      and fr.class = 'correction_attachment'
      and fr.current_version_id = fv.id
      and fv.state in ('validated', 'published')) then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'The bank proof is no longer valid.',
      '{"attachment":"Upload the proof again"}'::jsonb);
  end if;

  perform set_config('hrms.bank_approval_apply', 'on', true);
  insert into hrms.salary_profiles (employee_id, org_id, updated_by)
  values (p_employee_id, p_actor.org_id, p_actor.employee_id)
  on conflict (employee_id) do nothing;
  update hrms.salary_profiles set
    bank_name = p_payload ->> 'bank_name',
    account_holder = p_payload ->> 'account_holder',
    account_last4 = p_payload ->> 'account_last4',
    ifsc = p_payload ->> 'ifsc',
    bank_status = 'approved',
    bank_proof_file_version_id = v_proof,
    bank_approved_at = now(),
    bank_approved_by = p_actor.employee_id,
    updated_by = p_actor.employee_id,
    version = version + 1
  where employee_id = p_employee_id and org_id = p_actor.org_id
  returning version into v_version;
  perform set_config('hrms.bank_approval_apply', v_previous_guard, true);

  update hrms.sheet_sync set sync_requested_at = now()
  where org_id = p_actor.org_id and enabled;
  perform hrms.audit(
    p_actor.org_id, p_actor.employee_id,
    case when p_request_id is null
      then 'salary.bank_details_updated'
      else 'salary.bank_details_approved' end,
    'employee', p_employee_id,
    jsonb_build_object(
      'request_id', p_request_id,
      'mode', p_payload ->> 'mode',
      'fields', jsonb_build_array(
        'bank_name', 'account_holder', 'account_last4', 'ifsc', 'bank_proof')),
    'business', p_employee_id);
  return v_version;
end;
$$;

create or replace function hrms.apply_bank_details(
  p_req hrms.requests, p_payload jsonb, p_actor hrms.actor
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_class text := p_req.route_snapshot ->> 'initiator_class';
  v_expected integer;
  v_actual integer;
begin
  if v_class = 'hr' and not hrms.is_admin(p_actor) then
    perform hrms.raise_error(
      'ACCESS_DENIED', 'HR-originated bank details require Admin approval.');
  elsif v_class = 'employee'
        and not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then
    perform hrms.raise_error(
      'ACCESS_DENIED', 'Only HR or Admin can approve employee bank details.');
  elsif v_class not in ('employee', 'hr') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Invalid bank approval route.');
  end if;

  begin
    v_expected := (p_payload ->> 'target_version')::integer;
  exception when others then
    v_expected := null;
  end;
  if v_expected is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'The proposal has no target version.');
  end if;
  insert into hrms.salary_profiles (employee_id, org_id, updated_by)
  values (p_req.employee_id, p_req.org_id, p_actor.employee_id)
  on conflict (employee_id) do nothing;
  select version into v_actual
  from hrms.salary_profiles
  where employee_id = p_req.employee_id and org_id = p_req.org_id
  for update;
  if v_actual <> v_expected then
    perform hrms.raise_error(
      'STALE_VERSION', 'Bank details changed after this request was submitted.', null, true);
  end if;
  perform hrms.apply_bank_values(
    p_actor, p_req.employee_id, p_payload, p_req.id);
end;
$$;

create or replace function public.save_bank_details_request(
  p_request_id uuid, p_bank_name text, p_account_holder text, p_account_number text,
  p_ifsc text, p_reason text, p_attachment_file_version_id uuid,
  p_expected_version integer, p_operation_key uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_class text := hrms.change_initiator_class(v_actor);
  v_req hrms.requests;
  v_profile hrms.salary_profiles;
  v_bank text := hrms.clean_text(p_bank_name, 120);
  v_holder text := hrms.clean_text(p_account_holder, 200);
  v_digits text := regexp_replace(coalesce(p_account_number, ''), '\D', '', 'g');
  v_last4 text;
  v_ifsc text := nullif(upper(regexp_replace(coalesce(p_ifsc, ''), '\s', '', 'g')), '');
  v_reason text := hrms.clean_text(p_reason, 500);
  v_errors jsonb := '{}'::jsonb;
  v_change boolean;
  v_mode text;
  v_target_version integer;
  v_route jsonb;
  v_reviewer uuid;
  v_payload jsonb;
  v_previous jsonb;
  v_result jsonb;
  v_hash text;
  v_replay jsonb;
  v_from text;
  v_applied_version integer;
begin
  v_hash := hrms.sha256_hex(concat_ws(
    '|', p_request_id, v_bank, v_holder, v_digits, v_ifsc,
    v_reason, p_attachment_file_version_id, p_expected_version));
  v_replay := hrms.idem_claim(
    v_actor.employee_id, v_actor.org_id, 'bank-details.save',
    p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;

  perform pg_advisory_xact_lock(
    hashtext('bank-details'), hashtext(v_actor.employee_id::text));
  select * into v_profile
  from hrms.salary_profiles where employee_id = v_actor.employee_id;
  v_target_version := coalesce(v_profile.version, 1);
  v_change := found and v_profile.bank_status = 'approved';
  v_mode := case when v_change then 'change' else 'initial' end;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id
       or v_req.kind <> 'bank_details' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state not in ('submitted', 'returned') then
      perform hrms.raise_error(
        'REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error(
        'STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
    select payload into v_previous from hrms.request_revisions
    where request_id = v_req.id and revision_no = v_req.current_revision;
    v_mode := coalesce(v_previous ->> 'mode', v_mode);
    v_change := v_mode = 'change';
    p_attachment_file_version_id := coalesce(
      p_attachment_file_version_id,
      (v_previous ->> 'attachment_file_version_id')::uuid);
  elsif v_class <> 'admin' and exists (
    select 1 from hrms.requests
    where employee_id = v_actor.employee_id and kind = 'bank_details'
      and state in ('submitted', 'under_review', 'returned')) then
    perform hrms.raise_error(
      'REQUEST_LOCKED', 'A bank-details request is already pending.');
  end if;

  if v_bank is null then v_errors := v_errors || '{"bank_name":"Required"}'::jsonb; end if;
  if v_holder is null then v_errors := v_errors || '{"account_holder":"Required"}'::jsonb; end if;
  if length(v_digits) < 4 or length(v_digits) > 18 then
    v_errors := v_errors || '{"account_number":"Enter 4 to 18 digits"}'::jsonb;
  else
    v_last4 := right(v_digits, 4);
  end if;
  if v_ifsc is null or v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
    v_errors := v_errors || '{"ifsc":"Use an IFSC like HDFC0001234"}'::jsonb;
  end if;
  if v_change and v_reason is null then
    v_errors := v_errors || '{"reason":"Explain why the approved account must change"}'::jsonb;
  end if;
  if p_attachment_file_version_id is null then
    v_errors := v_errors || '{"attachment":"Upload bank proof"}'::jsonb;
  elsif not exists (
    select 1
    from hrms.file_versions fv
    join hrms.file_records fr on fr.id = fv.file_record_id
    where fv.id = p_attachment_file_version_id
      and fr.org_id = v_actor.org_id
      and fr.owner_employee_id = v_actor.employee_id
      and fr.class = 'correction_attachment'
      and fr.current_version_id = fv.id
      and fv.state in ('validated', 'published')) then
    v_errors := v_errors || '{"attachment":"Upload the proof again"}'::jsonb;
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Please check the bank details.', v_errors);
  end if;

  v_payload := jsonb_build_object(
    'mode', v_mode,
    'target_version', v_target_version,
    'bank_name', v_bank,
    'account_holder', v_holder,
    'account_last4', v_last4,
    'ifsc', v_ifsc,
    'reason', v_reason,
    'attachment_file_version_id', p_attachment_file_version_id);

  if v_class = 'admin' then
    if p_request_id is not null then
      perform hrms.raise_error(
        'REQUEST_LOCKED', 'Admin bank changes are applied immediately.');
    end if;
    v_applied_version := hrms.apply_bank_values(
      v_actor, v_actor.employee_id, v_payload, null);
    v_result := hrms.ok(
      jsonb_build_object(
        'applied', true, 'approval_required', false,
        'bank_status', 'approved', 'account_last4', v_last4),
      v_applied_version);
    perform hrms.idem_complete(
      v_actor.employee_id, 'bank-details.save', p_operation_key, v_result);
    return v_result;
  end if;

  v_route := hrms.change_reviewer(v_actor.org_id, v_actor.employee_id, v_class);
  v_reviewer := nullif(v_route ->> 'reviewer_id', '')::uuid;
  if p_request_id is null then
    insert into hrms.requests (
      org_id, employee_id, target_employee_id, kind, state,
      assigned_reviewer_id, route_snapshot, submitted_at
    ) values (
      v_actor.org_id, v_actor.employee_id, v_actor.employee_id,
      'bank_details', 'submitted', v_reviewer,
      v_route || jsonb_build_object(
        'mode', v_mode,
        'initiator_id', v_actor.employee_id,
        'target_employee_id', v_actor.employee_id,
        'change_category', 'bank_details'),
      now())
    returning * into v_req;
    insert into hrms.request_revisions (
      request_id, revision_no, payload, created_by
    ) values (v_req.id, 1, v_payload, v_actor.employee_id);
    perform hrms.request_event(
      v_req, 'submitted', v_actor.employee_id, null, null, 'submitted');
  else
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
        'mode', v_mode,
        'initiator_id', v_actor.employee_id,
        'target_employee_id', v_actor.employee_id,
        'change_category', 'bank_details')
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
      'Bank details to review',
      'An employee submitted bank details for approval.', true);
  end if;
  perform hrms.audit(
    v_actor.org_id, v_actor.employee_id,
    'salary.bank_details_submitted', 'request', v_req.id,
    jsonb_build_object(
      'mode', v_mode,
      'revision', v_req.current_revision,
      'initiator_class', v_class),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(
    v_actor.employee_id, 'bank-details.save', p_operation_key, v_result);
  return v_result;
end;
$$;

create or replace function hrms.salary_json(p_employee uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'profile', (select jsonb_build_object(
                  'monthly_salary', sp.monthly_salary, 'currency', sp.currency,
                  'effective_from', sp.effective_from, 'bank_name', sp.bank_name,
                  'account_holder', sp.account_holder, 'account_last4', sp.account_last4,
                  'ifsc', sp.ifsc, 'bank_status', sp.bank_status,
                  'bank_approved_at', sp.bank_approved_at, 'updated_at', sp.updated_at,
                  'version', sp.version)
                from hrms.salary_profiles sp where sp.employee_id = p_employee),
    'bank_request', (select jsonb_build_object(
                       'id', r.id, 'state', r.state, 'version', r.version,
                       'mode', r.route_snapshot ->> 'mode',
                       'initiator_class', r.route_snapshot ->> 'initiator_class',
                       'submitted_at', r.submitted_at)
                     from hrms.requests r
                     where r.employee_id = p_employee and r.kind = 'bank_details'
                       and r.state in ('submitted', 'under_review', 'returned')
                     order by r.created_at desc limit 1),
    'lifetime_paid', (select coalesce(sum(p.net_amount), 0) from hrms.payslips p
                      where p.employee_id = p_employee and p.published_at is not null),
    'paid_months', (select count(*) from hrms.payslips p
                    where p.employee_id = p_employee and p.published_at is not null
                      and p.net_amount is not null),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                  'salary_month', x.salary_month, 'net_amount', x.net_amount)
                  order by x.salary_month desc), '[]'::jsonb)
               from (select p.salary_month, p.net_amount from hrms.payslips p
                     where p.employee_id = p_employee and p.published_at is not null
                     order by p.salary_month desc limit 12) x)
  );
$$;

create or replace function public.reassign_request(
  p_request_id uuid, p_new_reviewer_id uuid, p_reason text,
  p_expected_version integer
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
  if not hrms.is_eligible_reviewer(p_new_reviewer_id, v_req.employee_id) then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Choose an eligible approver other than the requester.',
      '{"reviewer_id":"Not an eligible approver"}'::jsonb);
  end if;

  v_roles := hrms.employee_roles(p_new_reviewer_id);
  if v_req.kind = 'leave' then
    if not (v_roles && array['hr', 'admin']) then
      perform hrms.raise_error(
        'VALIDATION_FAILED', 'Leave can be assigned only to HR or Admin.',
        '{"reviewer_id":"HR/Admin required"}'::jsonb);
    end if;
  elsif hrms.is_employee_change_kind(v_req.kind)
        or (v_req.kind = 'bank_details'
            and v_req.route_snapshot ->> 'initiator_class' in ('employee', 'hr')) then
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
    if (v_req.route_snapshot ->> 'mode' = 'change'
        and not ('admin' = any(v_roles)))
       or (v_req.route_snapshot ->> 'mode' <> 'change'
           and not (v_roles && array['hr', 'admin'])) then
      perform hrms.raise_error(
        'VALIDATION_FAILED', 'Choose an eligible bank-details approver.',
        '{"reviewer_id":"Not allowed for this bank request"}'::jsonb);
    end if;
  end if;

  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if v_req.state not in (
    'submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending') then
    perform hrms.raise_error(
      'REQUEST_LOCKED', 'Only pending requests can be reassigned.');
  end if;

  v_old := v_req.assigned_reviewer_id;
  update hrms.requests set
    assigned_reviewer_id = p_new_reviewer_id,
    version = version + 1,
    route_snapshot = coalesce(route_snapshot, '{}'::jsonb)
      || jsonb_build_object(
        'reassigned_from', v_old, 'reassigned_by', v_actor.employee_id)
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(
    v_req, 'reassigned', v_actor.employee_id, v_reason,
    v_req.state, v_req.state);
  perform hrms.notify_request(
    v_req, p_new_reviewer_id, 'request.reassigned',
    'Request assigned to you',
    'A request was assigned to you for review.', true);
  perform hrms.audit(
    v_actor.org_id, v_actor.employee_id,
    'request.reassigned', 'request', v_req.id,
    jsonb_build_object(
      'from', v_old, 'to', p_new_reviewer_id,
      'reason', v_reason, 'category', v_req.kind),
    'business', hrms.change_target_employee(v_req));
  return hrms.ok(hrms.request_summary(v_req), v_req.version);
end;
$$;

select hrms.apply_api_grants();
