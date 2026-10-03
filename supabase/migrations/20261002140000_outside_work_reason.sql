-- Outside-work days carry their reason (Videography, Work from home, Meeting,
-- Client visit or a custom one) so Home and Attendance can show it.

create or replace function hrms.attendance_row_json(r hrms.attendance_row) returns jsonb
language sql
stable
security definer
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
    'early_seconds', (r.calc).early_seconds, 'leave_conflict_seconds', (r.calc).leave_conflict_seconds,
    -- Indexed point lookup, only on outside-work days.
    'outside_reason', case when r.effective_source = 'outside' then
      (select o.reason from hrms.outside_work o
       where o.employee_id = r.employee_id and o.work_date = r.shift_date and o.revoked_at is null) end
  );
$$;

