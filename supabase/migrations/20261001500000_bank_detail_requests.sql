-- Employee-owned bank details with immutable proof and approval.
-- Initial setup may be approved by HR or Admin. Once approved, every change
-- requires Admin approval. Approved bank fields cannot be edited directly.

alter table hrms.requests drop constraint requests_kind_check;
alter table hrms.requests add constraint requests_kind_check
  check (kind in ('leave', 'correction', 'bank_details'));

create unique index requests_one_active_bank_details
  on hrms.requests (employee_id)
  where kind = 'bank_details' and state in ('submitted', 'under_review', 'returned');

alter table hrms.salary_profiles
  add column bank_status text not null default 'not_set'
    check (bank_status in ('not_set', 'approved')),
  add column bank_proof_file_version_id uuid references hrms.file_versions(id) on delete restrict,
  add column bank_approved_at timestamptz,
  add column bank_approved_by uuid;

update hrms.salary_profiles
set bank_status = 'approved', bank_approved_at = coalesce(updated_at, created_at), bank_approved_by = updated_by
where bank_name is not null or account_last4 is not null or ifsc is not null;

create or replace function hrms.salary_bank_approval_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.bank_name, new.account_holder, new.account_last4, new.ifsc, new.bank_status,
      new.bank_proof_file_version_id, new.bank_approved_at, new.bank_approved_by)
     is distinct from
     (old.bank_name, old.account_holder, old.account_last4, old.ifsc, old.bank_status,
      old.bank_proof_file_version_id, old.bank_approved_at, old.bank_approved_by)
     and coalesce(current_setting('hrms.bank_approval_apply', true), '') <> 'on' then
    perform hrms.raise_error('REQUEST_REQUIRED',
      'Approved bank details can only change through an approved employee request.');
  end if;
  return new;
end;
$$;

create trigger salary_bank_approval_guard before update on hrms.salary_profiles
  for each row execute function hrms.salary_bank_approval_guard();

create or replace function hrms.bank_request_reviewer(p_org uuid, p_employee uuid, p_change boolean)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.id
  from hrms.employees e
  where e.org_id = p_org and e.status = 'active' and e.id <> p_employee
    and case when p_change
      then 'admin' = any(hrms.employee_roles(e.id))
      else hrms.employee_roles(e.id) && array['hr', 'admin'] end
  order by case when not p_change and 'hr' = any(hrms.employee_roles(e.id)) then 0 else 1 end,
           e.employee_code
  limit 1;
$$;

create or replace function hrms.review_authority(p_actor hrms.actor, p_req hrms.requests) returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then null
    when p_req.kind = 'bank_details' and p_req.route_snapshot ->> 'mode' = 'change'
         and not hrms.is_admin(p_actor) then null
    when p_req.assigned_reviewer_id = p_actor.employee_id then 'assigned'
    when hrms.is_admin(p_actor) then 'admin'
    else null end;
$$;

create or replace function hrms.apply_bank_details(
  p_req hrms.requests, p_payload jsonb, p_actor hrms.actor
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_change boolean := p_payload ->> 'mode' = 'change';
  v_previous_guard text := coalesce(current_setting('hrms.bank_approval_apply', true), '');
begin
  if v_change and not hrms.is_admin(p_actor) then
    perform hrms.raise_error('ACCESS_DENIED', 'Only an Admin can approve changes to existing bank details.');
  end if;
  if not v_change and not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then
    perform hrms.raise_error('ACCESS_DENIED', 'Only HR or Admin can approve bank details.');
  end if;

  insert into hrms.salary_profiles (employee_id, org_id, updated_by)
  values (p_req.employee_id, p_req.org_id, p_actor.employee_id)
  on conflict (employee_id) do nothing;

  perform set_config('hrms.bank_approval_apply', 'on', true);
  update hrms.salary_profiles set
    bank_name = p_payload ->> 'bank_name',
    account_holder = p_payload ->> 'account_holder',
    account_last4 = p_payload ->> 'account_last4',
    ifsc = p_payload ->> 'ifsc',
    bank_status = 'approved',
    bank_proof_file_version_id = (p_payload ->> 'attachment_file_version_id')::uuid,
    bank_approved_at = now(),
    bank_approved_by = p_actor.employee_id,
    updated_by = p_actor.employee_id,
    version = version + 1
  where employee_id = p_req.employee_id;
  perform set_config('hrms.bank_approval_apply', v_previous_guard, true);

  update hrms.sheet_sync set sync_requested_at = now()
  where org_id = p_req.org_id and enabled;
  perform hrms.audit(p_req.org_id, p_actor.employee_id, 'salary.bank_details_approved',
    'employee', p_req.employee_id,
    jsonb_build_object('request_id', p_req.id, 'mode', p_payload ->> 'mode'),
    'business', p_req.employee_id);
end;
$$;

create or replace function public.save_bank_details_request(
  p_request_id uuid, p_bank_name text, p_account_holder text, p_account_number text,
  p_ifsc text, p_reason text, p_attachment_file_version_id uuid,
  p_expected_version integer, p_operation_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
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
  v_reviewer uuid;
  v_payload jsonb;
  v_previous jsonb;
  v_result jsonb;
  v_hash text;
  v_replay jsonb;
  v_from text;
begin
  v_hash := hrms.sha256_hex(concat_ws('|', p_request_id, v_bank, v_holder, v_digits, v_ifsc,
    v_reason, p_attachment_file_version_id, p_expected_version));
  v_replay := hrms.idem_claim(v_actor.employee_id, v_actor.org_id, 'bank-details.save',
                              p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;

  perform pg_advisory_xact_lock(hashtext('bank-details'), hashtext(v_actor.employee_id::text));
  select * into v_profile from hrms.salary_profiles where employee_id = v_actor.employee_id;
  v_change := found and v_profile.bank_status = 'approved';
  v_mode := case when v_change then 'change' else 'initial' end;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'bank_details' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state not in ('submitted', 'returned') then
      perform hrms.raise_error('REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
    select payload into v_previous from hrms.request_revisions
    where request_id = v_req.id and revision_no = v_req.current_revision;
    v_mode := coalesce(v_previous ->> 'mode', v_mode);
    v_change := v_mode = 'change';
    p_attachment_file_version_id := coalesce(p_attachment_file_version_id,
      (v_previous ->> 'attachment_file_version_id')::uuid);
  elsif exists (select 1 from hrms.requests where employee_id = v_actor.employee_id
                 and kind = 'bank_details' and state in ('submitted', 'under_review', 'returned')) then
    perform hrms.raise_error('REQUEST_LOCKED', 'A bank-details request is already pending.');
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
    select 1 from hrms.file_versions fv
    join hrms.file_records fr on fr.id = fv.file_record_id
    where fv.id = p_attachment_file_version_id
      and fr.owner_employee_id = v_actor.employee_id
      and fr.class = 'correction_attachment'
      and fv.state in ('validated', 'published')) then
    v_errors := v_errors || '{"attachment":"Upload the proof again"}'::jsonb;
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the bank details.', v_errors);
  end if;

  v_payload := jsonb_build_object(
    'mode', v_mode, 'bank_name', v_bank, 'account_holder', v_holder,
    'account_last4', v_last4, 'ifsc', v_ifsc, 'reason', v_reason,
    'attachment_file_version_id', p_attachment_file_version_id);
  v_reviewer := hrms.bank_request_reviewer(v_actor.org_id, v_actor.employee_id, v_change);

  if p_request_id is null then
    insert into hrms.requests (org_id, employee_id, kind, state, assigned_reviewer_id,
      route_snapshot, submitted_at)
    values (v_actor.org_id, v_actor.employee_id, 'bank_details', 'submitted', v_reviewer,
      jsonb_build_object('mode', v_mode, 'reviewer_rule',
        case when v_change then 'admin_only' else 'hr_or_admin' end), now())
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, 1, v_payload, v_actor.employee_id);
    perform hrms.request_event(v_req, 'submitted', v_actor.employee_id, null, null, 'submitted');
  else
    v_from := v_req.state;
    update hrms.requests set current_revision = current_revision + 1, version = version + 1,
      state = 'submitted', edited = true, assigned_reviewer_id = v_reviewer,
      locked_revision = null, submitted_at = now(),
      route_snapshot = jsonb_build_object('mode', v_mode, 'reviewer_rule',
        case when v_change then 'admin_only' else 'hr_or_admin' end)
    where id = v_req.id returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
    perform hrms.request_event(v_req, case when v_from = 'returned' then 'resubmitted' else 'edited' end,
      v_actor.employee_id, null, v_from, 'submitted');
  end if;

  if v_reviewer is null then
    perform hrms.alert_missing_reviewer(v_req);
  else
    perform hrms.notify_request(v_req, v_reviewer, 'request.submitted',
      'Bank details to review', 'An employee submitted bank details for approval.', true);
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'salary.bank_details_submitted',
    'request', v_req.id, jsonb_build_object('mode', v_mode, 'revision', v_req.current_revision),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(v_actor.employee_id, 'bank-details.save', p_operation_key, v_result);
  return v_result;
end;
$$;

create or replace function hrms.request_summary(p_req hrms.requests) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_req.id, 'kind', p_req.kind, 'state', p_req.state, 'version', p_req.version,
    'current_revision', p_req.current_revision, 'edited', p_req.edited,
    'request_mode', p_req.route_snapshot ->> 'mode',
    'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name),
    'leave_type', case when lt.id is null then null else jsonb_build_object('id', lt.id, 'code', lt.code, 'name', lt.name) end,
    'start_date', p_req.start_date, 'end_date', p_req.end_date, 'units', p_req.units,
    'target_shift_date', p_req.target_shift_date,
    'submitted_at', p_req.submitted_at, 'first_opened_at', p_req.first_opened_at,
    'reviewer_assigned', p_req.assigned_reviewer_id is not null,
    'created_at', p_req.created_at, 'updated_at', p_req.updated_at
  )
  from hrms.employees e
  left join hrms.leave_types lt on lt.id = p_req.leave_type_id
  where e.id = p_req.employee_id;
$$;

create or replace function hrms.salary_json(p_employee uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile', (select jsonb_build_object(
                  'monthly_salary', sp.monthly_salary, 'currency', sp.currency,
                  'effective_from', sp.effective_from, 'bank_name', sp.bank_name,
                  'account_holder', sp.account_holder, 'account_last4', sp.account_last4,
                  'ifsc', sp.ifsc, 'bank_status', sp.bank_status,
                  'bank_approved_at', sp.bank_approved_at, 'updated_at', sp.updated_at)
                from hrms.salary_profiles sp where sp.employee_id = p_employee),
    'bank_request', (select jsonb_build_object(
                       'id', r.id, 'state', r.state, 'version', r.version,
                       'mode', r.route_snapshot ->> 'mode', 'submitted_at', r.submitted_at)
                     from hrms.requests r where r.employee_id = p_employee and r.kind = 'bank_details'
                       and r.state in ('submitted', 'under_review', 'returned')
                     order by r.created_at desc limit 1),
    'lifetime_paid', (select coalesce(sum(p.net_amount), 0) from hrms.payslips p
                      where p.employee_id = p_employee and p.published_at is not null),
    'paid_months', (select count(*) from hrms.payslips p
                    where p.employee_id = p_employee and p.published_at is not null and p.net_amount is not null),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('salary_month', x.salary_month,
                                                             'net_amount', x.net_amount)
                                         order by x.salary_month desc), '[]'::jsonb)
               from (select p.salary_month, p.net_amount from hrms.payslips p
                     where p.employee_id = p_employee and p.published_at is not null
                     order by p.salary_month desc limit 12) x)
  );
$$;

create or replace function public.decide_request(
  p_request_id uuid, p_decision text, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
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
  if v_req.employee_id = v_actor.employee_id then
    perform hrms.raise_error('SELF_APPROVAL_FORBIDDEN', 'You cannot decide your own request.');
  end if;
  v_authority := hrms.review_authority(v_actor, v_req);
  if v_authority is null then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.state <> 'under_review' or v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it before deciding.', null, true);
  end if;
  if (p_decision in ('reject', 'return') or v_authority = 'admin') and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;

  select payload into v_payload from hrms.request_revisions
  where request_id = v_req.id and revision_no = v_req.current_revision;

  if p_decision = 'approve' then
    if v_req.kind = 'leave' then
      if hrms.leave_attendance_conflicts(v_req.employee_id, v_payload -> 'days') > 0 then
        perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
          'Attendance was recorded during this leave. Return it for correction instead.');
      end if;
      perform hrms.debit_request(v_req.id, v_req.current_revision, v_actor.employee_id);
    elsif v_req.kind = 'correction' then
      perform hrms.apply_correction(v_req, v_payload, v_actor.employee_id, v_reason);
    else
      perform hrms.apply_bank_details(v_req, v_payload, v_actor);
    end if;
    v_to := 'approved';
  elsif p_decision = 'reject' then
    perform hrms.release_request_holds(v_req.id);
    v_to := 'rejected';
  else
    perform hrms.release_request_holds(v_req.id);
    v_to := 'returned';
  end if;

  update hrms.requests set state = v_to, version = version + 1, decided_at = now(),
    decided_by = v_actor.employee_id,
    approved_revision = case when v_to = 'approved' then current_revision else approved_revision end
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req,
    case p_decision when 'approve' then 'approved' when 'reject' then 'rejected' else 'returned' end,
    v_actor.employee_id, v_reason, 'under_review', v_to);
  perform hrms.notify_request(v_req, v_req.employee_id, 'request.' || v_to,
    case when v_req.kind = 'bank_details' and v_to = 'approved' then 'Bank details approved'
         when v_to = 'approved' then 'Request approved'
         when v_to = 'rejected' then 'Request not approved' else 'Request returned for changes' end,
    case when v_to = 'returned' then 'Your approver asked for changes. Open the request to update it.'
         else 'Open the app to see the details.' end, false);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.' || p_decision,
    'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'authority', v_authority, 'reason', v_reason),
    'business', v_req.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

create or replace function public.reassign_request(
  p_request_id uuid, p_new_reviewer_id uuid, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_old uuid;
  v_roles text[];
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_req from hrms.requests where id = p_request_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if v_req.state not in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending') then
    perform hrms.raise_error('REQUEST_LOCKED', 'Only pending requests can be reassigned.');
  end if;
  if not hrms.is_eligible_reviewer(p_new_reviewer_id, v_req.employee_id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose an eligible approver other than the requester.',
      '{"reviewer_id":"Not an eligible approver"}'::jsonb);
  end if;
  if v_req.kind = 'bank_details' then
    v_roles := hrms.employee_roles(p_new_reviewer_id);
    if (v_req.route_snapshot ->> 'mode' = 'change' and not ('admin' = any(v_roles)))
       or (v_req.route_snapshot ->> 'mode' <> 'change' and not (v_roles && array['hr', 'admin'])) then
      perform hrms.raise_error('VALIDATION_FAILED',
        case when v_req.route_snapshot ->> 'mode' = 'change'
          then 'Bank-detail changes must be assigned to an Admin.'
          else 'Initial bank details must be assigned to HR or Admin.' end,
        '{"reviewer_id":"Not allowed for this bank request"}'::jsonb);
    end if;
  end if;
  v_old := v_req.assigned_reviewer_id;
  update hrms.requests set assigned_reviewer_id = p_new_reviewer_id, version = version + 1,
    route_snapshot = coalesce(route_snapshot, '{}'::jsonb)
      || jsonb_build_object('reassigned_from', v_old, 'reassigned_by', v_actor.employee_id)
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req, 'reassigned', v_actor.employee_id, v_reason, v_req.state, v_req.state);
  perform hrms.notify_request(v_req, p_new_reviewer_id, 'request.reassigned', 'Request assigned to you',
    'A request was assigned to you for review.', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.reassigned', 'request', v_req.id,
    jsonb_build_object('from', v_old, 'to', p_new_reviewer_id, 'reason', v_reason),
    'business', v_req.employee_id);
  return hrms.ok(hrms.request_summary(v_req), v_req.version);
end;
$$;

select hrms.apply_api_grants();
