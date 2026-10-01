-- Fix: Home picked YESTERDAY's closed shift the next morning, so Check in was
-- unavailable. In the ordering, "no session yet" made (session_state = 'open')
-- NULL, and NULLS LAST sorted today's row after yesterday's closed one (false).
-- Both preference keys now treat NULL as false. Body otherwise unchanged.

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
