-- Admins do not need an approver for their own requests. Their leave and
-- attendance corrections are approved the moment they submit, and they can
-- revoke their own approved leave immediately with a reason (credited back).
-- Everyone else keeps the normal approver route.

create or replace function public.save_leave_request(
  p_request_id uuid,
  p_leave_type_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_slot text,
  p_end_slot text,
  p_reason text,
  p_attachment_file_version_id uuid,
  p_submit boolean,
  p_expected_version integer,
  p_operation_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_type hrms.leave_types;
  v_req hrms.requests;
  v_calc jsonb;
  v_today date := hrms.org_today(v_actor.org_id);
  v_replay jsonb;
  v_hash text;
  v_route jsonb;
  v_prev_state text;
  v_payload jsonb;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_result jsonb;
begin
  v_hash := hrms.sha256_hex(concat_ws('|', p_request_id, p_leave_type_id, p_start_date, p_end_date,
    p_start_slot, p_end_slot, v_reason, p_attachment_file_version_id, p_submit, p_expected_version));
  v_replay := hrms.idem_claim(v_actor.employee_id, v_actor.org_id, 'leave.save', p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;

  select * into v_type from hrms.leave_types
  where id = p_leave_type_id and org_id = v_actor.org_id and active;
  if not found then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a leave type.',
      '{"leave_type_id":"Choose an active leave type"}'::jsonb);
  end if;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'leave' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state in ('under_review', 'withdrawal_pending') then
      perform hrms.raise_error('REQUEST_LOCKED',
        'Your approver has opened this request. Contact them for changes.');
    end if;
    if v_req.state not in ('draft', 'submitted', 'returned') then
      perform hrms.raise_error('REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
  end if;

  -- Backdating window applies to past start dates, advance notice to future
  -- ones (both inclusive, server-configured).
  if p_start_date is not null and p_start_date < v_today then
    if p_start_date < v_today - v_type.backdate_days then
      perform hrms.raise_error('VALIDATION_FAILED', 'Too far in the past.', jsonb_build_object('start_date',
        format('Leave can be backdated at most %s days', v_type.backdate_days)));
    end if;
  elsif p_start_date is not null and v_type.advance_notice_days > 0
        and p_start_date < v_today + v_type.advance_notice_days then
    perform hrms.raise_error('VALIDATION_FAILED', 'Needs more notice.', jsonb_build_object('start_date',
      format('Apply at least %s days in advance', v_type.advance_notice_days)));
  end if;

  v_calc := hrms.compute_leave_days(v_actor.org_id, v_actor.employee_id, v_type, p_start_date, p_end_date,
                                    coalesce(p_start_slot, 'FULL'), coalesce(p_end_slot, 'FULL'));
  if v_calc -> 'errors' <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the dates.', v_calc -> 'errors');
  end if;

  if p_submit and v_type.requires_attachment and p_attachment_file_version_id is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Attach the required document.',
      '{"attachment":"This leave type needs a supporting document"}'::jsonb);
  end if;
  if p_attachment_file_version_id is not null and not exists (
       select 1 from hrms.file_versions fv join hrms.file_records fr on fr.id = fv.file_record_id
       where fv.id = p_attachment_file_version_id and fr.owner_employee_id = v_actor.employee_id
         and fr.class in ('leave_attachment', 'medical_attachment') and fv.state in ('validated', 'published')) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Attachment not found.',
      '{"attachment":"Upload the document again"}'::jsonb);
  end if;

  if hrms.leave_attendance_conflicts(v_actor.employee_id, v_calc -> 'days') > 0 then
    perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
      'You have recorded attendance during this leave. Request a correction or change the dates.');
  end if;

  v_payload := jsonb_build_object(
    'leave_type_id', v_type.id, 'leave_type_code', v_type.code, 'leave_type_name', v_type.name,
    'start_date', p_start_date, 'end_date', p_end_date,
    'start_slot', coalesce(p_start_slot, 'FULL'), 'end_slot', coalesce(p_end_slot, 'FULL'),
    'reason', v_reason, 'attachment_file_version_id', p_attachment_file_version_id,
    'units', (v_calc ->> 'units')::integer, 'days', v_calc -> 'days');

  if p_request_id is null then
    insert into hrms.requests (org_id, employee_id, kind, state, leave_type_id, start_date, end_date, units)
    values (v_actor.org_id, v_actor.employee_id, 'leave', 'draft', v_type.id, p_start_date, p_end_date,
            (v_calc ->> 'units')::integer)
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, 1, v_payload, v_actor.employee_id);
    v_prev_state := 'draft';
  else
    v_prev_state := v_req.state;
    -- Swap: release the old revision's holds, then reserve the new one below.
    if v_req.state = 'submitted' then
      perform hrms.release_request_holds(v_req.id);
    end if;
    update hrms.requests
       set current_revision = current_revision + 1,
           version = version + 1,
           edited = (v_req.state <> 'draft'),
           leave_type_id = v_type.id, start_date = p_start_date, end_date = p_end_date,
           units = (v_calc ->> 'units')::integer
     where id = v_req.id
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
  end if;

  if p_submit then
    perform hrms.reserve_leave(v_actor.org_id, v_actor.employee_id, v_req.id, v_req.current_revision, v_type,
                               v_calc -> 'days');
    if v_prev_state in ('draft', 'returned') and hrms.is_admin(v_actor) then
      -- Admin's own leave needs no approver: approve at once (revocable).
      perform hrms.debit_request(v_req.id, v_req.current_revision, v_actor.employee_id);
      update hrms.requests
         set state = 'approved', submitted_at = now(), decided_at = now(), decided_by = v_actor.employee_id,
             approved_revision = current_revision, assigned_reviewer_id = null,
             route_snapshot = jsonb_build_object('mode', 'self_admin'), version = version + 1
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, 'auto_approved', v_actor.employee_id, null, v_prev_state, 'approved');
    elsif v_prev_state in ('draft', 'returned') then
      v_route := hrms.resolve_reviewer(v_actor.org_id, v_actor.employee_id, 'leave', p_start_date);
      update hrms.requests
         set state = 'submitted', submitted_at = now(), version = version + 1,
             assigned_reviewer_id = case when v_prev_state = 'returned' then assigned_reviewer_id
                                         else (v_route ->> 'reviewer_id')::uuid end,
             route_snapshot = case when v_prev_state = 'returned' then route_snapshot else v_route end
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, case when v_prev_state = 'returned' then 'resubmitted' else 'submitted' end,
                                 v_actor.employee_id, null, v_prev_state, 'submitted');
      if v_req.assigned_reviewer_id is null then
        perform hrms.alert_missing_reviewer(v_req);
      else
        perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.submitted',
          'New leave request to review', 'A team member submitted a leave request.', true);
      end if;
    else
      perform hrms.request_event(v_req, 'edited', v_actor.employee_id, null, v_prev_state, v_req.state);
    end if;
  elsif v_prev_state = 'submitted' then
    perform hrms.raise_error('VALIDATION_FAILED', 'A submitted request can only be saved by submitting it.');
  end if;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_request_id is null then 'leave.created' else 'leave.edited' end, 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'state', v_req.state,
                       'units', v_req.units, 'start_date', p_start_date, 'end_date', p_end_date),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(v_actor.employee_id, 'leave.save', p_operation_key, v_result);
  return v_result;
end;
$$;


create or replace function public.save_correction_request(
  p_request_id uuid,
  p_shift_date date,
  p_proposed_in_at timestamptz,
  p_proposed_out_at timestamptz,
  p_reason text,
  p_submit boolean,
  p_expected_version integer,
  p_operation_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_check jsonb;
  v_replay jsonb;
  v_route jsonb;
  v_prev_state text;
  v_payload jsonb;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_result jsonb;
begin
  v_replay := hrms.idem_claim(v_actor.employee_id, v_actor.org_id, 'correction.save', p_operation_key,
    hrms.sha256_hex(concat_ws('|', p_request_id, p_shift_date, p_proposed_in_at, p_proposed_out_at, v_reason,
                              p_submit, p_expected_version)));
  if v_replay is not null then return v_replay; end if;

  if v_reason is null or char_length(v_reason) < 3 then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Explain the correction"}'::jsonb);
  end if;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'correction' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state in ('under_review', 'withdrawal_pending') then
      perform hrms.raise_error('REQUEST_LOCKED', 'Your approver has opened this request. Contact them for changes.');
    end if;
    if v_req.state not in ('draft', 'submitted', 'returned') then
      perform hrms.raise_error('REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
  end if;

  v_check := hrms.validate_correction(v_actor, p_shift_date, p_proposed_in_at, p_proposed_out_at);
  if v_check -> 'errors' <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the correction.', v_check -> 'errors');
  end if;

  v_payload := jsonb_build_object(
    'shift_date', p_shift_date, 'schedule_instance_id', v_check -> 'instance_id',
    'session_id', v_check -> 'session_id', 'based_on_revision', (v_check ->> 'based_on_revision')::integer,
    'proposed_in_at', p_proposed_in_at, 'proposed_out_at', p_proposed_out_at, 'reason', v_reason,
    'shift_start_at', v_check -> 'start_at', 'shift_end_at', v_check -> 'end_at');

  if p_request_id is null then
    insert into hrms.requests (org_id, employee_id, kind, state, target_shift_date)
    values (v_actor.org_id, v_actor.employee_id, 'correction', 'draft', p_shift_date)
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, 1, v_payload, v_actor.employee_id);
    v_prev_state := 'draft';
  else
    v_prev_state := v_req.state;
    update hrms.requests
       set current_revision = current_revision + 1, version = version + 1,
           edited = (v_req.state <> 'draft'), target_shift_date = p_shift_date
     where id = v_req.id
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
  end if;

  if p_submit then
    if v_prev_state in ('draft', 'returned') and hrms.is_admin(v_actor) then
      -- Admin's own correction needs no approver: apply it at once.
      perform hrms.apply_correction(v_req, v_payload, v_actor.employee_id, v_reason);
      update hrms.requests
         set state = 'approved', submitted_at = now(), decided_at = now(), decided_by = v_actor.employee_id,
             approved_revision = current_revision, assigned_reviewer_id = null,
             route_snapshot = jsonb_build_object('mode', 'self_admin'), version = version + 1
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, 'auto_approved', v_actor.employee_id, null, v_prev_state, 'approved');
    elsif v_prev_state in ('draft', 'returned') then
      v_route := hrms.resolve_reviewer(v_actor.org_id, v_actor.employee_id, 'correction', p_shift_date);
      update hrms.requests
         set state = 'submitted', submitted_at = now(), version = version + 1,
             assigned_reviewer_id = case when v_prev_state = 'returned' then assigned_reviewer_id
                                         else (v_route ->> 'reviewer_id')::uuid end,
             route_snapshot = case when v_prev_state = 'returned' then route_snapshot else v_route end
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, case when v_prev_state = 'returned' then 'resubmitted' else 'submitted' end,
                                 v_actor.employee_id, null, v_prev_state, 'submitted');
      if v_req.assigned_reviewer_id is null then
        perform hrms.alert_missing_reviewer(v_req);
      else
        perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.submitted',
          'New attendance correction to review', 'A team member submitted an attendance correction.', true);
      end if;
    else
      perform hrms.request_event(v_req, 'edited', v_actor.employee_id, null, v_prev_state, v_req.state);
    end if;
  elsif v_prev_state = 'submitted' then
    perform hrms.raise_error('VALIDATION_FAILED', 'A submitted request can only be saved by submitting it.');
  end if;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_request_id is null then 'correction.created' else 'correction.edited' end, 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'state', v_req.state, 'shift_date', p_shift_date),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(v_actor.employee_id, 'correction.save', p_operation_key, v_result);
  return v_result;
end;
$$;


create or replace function public.request_leave_cancellation(
  p_request_id uuid, p_expected_version integer, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_reason text := hrms.clean_text(p_reason, 1000);
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'leave' then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_req.state <> 'approved' then
    perform hrms.raise_error('REQUEST_LOCKED', 'Only approved leave can be cancelled this way.');
  end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
  end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if hrms.is_admin(v_actor) then
    -- Admin revokes their own approved leave directly; the reason is kept.
    perform hrms.credit_back_request(v_req.id, v_req.approved_revision, v_actor.employee_id);
    update hrms.requests set state = 'cancelled', version = version + 1, decided_at = now(),
                             decided_by = v_actor.employee_id
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'revoked', v_actor.employee_id, v_reason, 'approved', 'cancelled');
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave.revoked', 'request', v_req.id,
      jsonb_build_object('reason', v_reason), 'business', v_actor.employee_id);
    return hrms.ok(hrms.request_detail(v_req), v_req.version);
  end if;
  update hrms.requests set state = 'cancellation_pending', version = version + 1
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req, 'cancellation_requested', v_actor.employee_id, v_reason, 'approved',
                             'cancellation_pending');
  perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.cancellation_requested',
    'Leave cancellation requested', 'A team member asked to cancel approved leave.', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave.cancellation_requested', 'request', v_req.id,
    null, 'business', v_actor.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;


select hrms.apply_api_grants();
