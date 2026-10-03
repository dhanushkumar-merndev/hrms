-- Company Saturday rule. Sunday stays the weekly off from each shift; Saturday
-- is a working day unless its week of the month is ticked here (bit n-1 = nth
-- Saturday, 31 = every Saturday). Default 0: only Sunday is off.

alter table hrms.organizations
  add column saturday_off_weeks smallint not null default 0 check (saturday_off_weeks between 0 and 31);

create or replace function hrms.ensure_schedule_instances(
  p_org uuid, p_employee_ids uuid[], p_from date, p_to date
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to < p_from then
    return;
  end if;
  if p_to - p_from > 400 then
    perform hrms.raise_error('RANGE_TOO_LARGE', 'Date range is too large.');
  end if;

  with org as (
    select o.id, o.timezone, o.saturday_off_weeks from hrms.organizations o where o.id = p_org
  ),
  emps as (
    select e.id, e.join_date, e.end_date
    from hrms.employees e
    where e.org_id = p_org and e.id = any(p_employee_ids)
  ),
  days as (
    select e.id as employee_id, d::date as day
    from emps e
    cross join lateral generate_series(
      greatest(p_from, e.join_date),
      least(p_to, coalesce(e.end_date, p_to)),
      interval '1 day'
    ) d
  ),
  -- Published version validity ranges, computed once for all shifts.
  versions as (
    select sv.*,
           daterange(sv.effective_from,
                     lead(sv.effective_from) over (partition by sv.shift_id
                                                   order by sv.effective_from, sv.version_no),
                     '[)') as valid
    from hrms.shift_versions sv
    where sv.org_id = p_org and sv.state = 'published'
  ),
  base as (
    select dd.employee_id, dd.day,
           coalesce(ex.shift_id, sa.shift_id) as shift_id,
           ex.kind as exception_kind,
           oa.office_id
    from days dd
    left join hrms.shift_assignments sa
      on sa.employee_id = dd.employee_id
     and daterange(sa.effective_from, sa.effective_to, '[)') @> dd.day
    left join hrms.schedule_exceptions ex
      on ex.employee_id = dd.employee_id and ex.work_date = dd.day
    left join hrms.office_assignments oa
      on oa.employee_id = dd.employee_id
     and daterange(oa.effective_from, oa.effective_to, '[)') @> dd.day
  ),
  hol as (
    select distinct on (b.employee_id, b.day) b.employee_id, b.day, h.id as holiday_id
    from base b
    join hrms.holidays h
      on h.org_id = p_org and h.state = 'published' and h.holiday_date = b.day
     and (h.office_id is null or h.office_id = b.office_id)
    order by b.employee_id, b.day, h.office_id nulls last
  ),
  resolved as (
    select b.employee_id, b.day, b.office_id, b.exception_kind, hol.holiday_id,
           v.id as shift_version_id, v.start_local, v.end_local, v.crosses_midnight,
           v.weekly_mask, v.grace_seconds, v.lunch_start_local, v.lunch_end_local, v.lunch_paid,
           v.early_entry_seconds, v.early_credit,
           case when v.checkout_extension_enabled then v.checkout_extension_seconds else 0 end as ext,
           coalesce(ofc.timezone, org.timezone) as tz,
           (v.weekly_mask & (1 << (extract(isodow from b.day)::integer - 1))) <> 0
             -- Company Saturday rule: bit n-1 set => the nth Saturday of the month is off.
             and not (extract(isodow from b.day) = 6
                      and (org.saturday_off_weeks & (1 << ((extract(day from b.day)::integer - 1) / 7))) <> 0)
             as on_weekly_day
    from base b
    cross join org
    join versions v on v.shift_id = b.shift_id and v.valid @> b.day
    left join hol on hol.employee_id = b.employee_id and hol.day = b.day
    left join hrms.offices ofc on ofc.id = b.office_id
  ),
  timed as (
    select r.*,
           ((r.day + r.start_local) at time zone r.tz) as s_at,
           (((r.day + case when r.crosses_midnight then 1 else 0 end) + r.end_local) at time zone r.tz) as e_at,
           case when r.lunch_start_local is null then null else
             (((r.day + case when r.crosses_midnight and r.lunch_start_local < r.start_local then 1 else 0 end)
               + r.lunch_start_local) at time zone r.tz) end as ls_at,
           case when r.lunch_end_local is null then null else
             (((r.day + case when r.crosses_midnight and r.lunch_end_local <= r.start_local then 1 else 0 end)
               + r.lunch_end_local) at time zone r.tz) end as le_at,
           case
             when r.exception_kind = 'day_off' then 'day_off'
             when r.exception_kind = 'extra_workday' then 'extra_workday'
             when r.holiday_id is not null then 'holiday'
             when not r.on_weekly_day then 'weekly_off'
             else 'workday'
           end as kind
    from resolved r
  )
  insert into hrms.work_schedule_instances (
    org_id, employee_id, shift_date, kind, is_required, office_id, shift_version_id, holiday_id,
    timezone, start_at, end_at, lunch_start_at, lunch_end_at, lunch_paid, grace_seconds,
    early_entry_seconds, early_credit, checkout_extension_seconds, expected_seconds, half_split_at
  )
  select p_org, t.employee_id, t.day, t.kind, t.kind in ('workday', 'extra_workday'), t.office_id,
         t.shift_version_id, t.holiday_id, t.tz, t.s_at, t.e_at, t.ls_at, t.le_at, t.lunch_paid,
         t.grace_seconds, t.early_entry_seconds, t.early_credit, t.ext,
         (extract(epoch from (t.e_at - t.s_at))
           - case when t.lunch_paid or t.ls_at is null then 0
                  else extract(epoch from (t.le_at - t.ls_at)) end)::integer,
         -- Half-day split at the midpoint of the paid timeline (10:00–19:00
         -- with paid lunch -> 14:30). With an unpaid lunch the split skips it.
         case
           when t.lunch_paid or t.ls_at is null then t.s_at + (t.e_at - t.s_at) / 2
           else (
             select case when t.s_at + make_interval(secs => half) <= t.ls_at
                         then t.s_at + make_interval(secs => half)
                         else t.s_at + make_interval(secs => half) + (t.le_at - t.ls_at) end
             from (select (extract(epoch from (t.e_at - t.s_at))
                           - extract(epoch from (t.le_at - t.ls_at))) / 2 as half) h
           )
         end
  from timed t
  on conflict (employee_id, shift_date) do nothing;
end;
$$;


create or replace function public.list_holidays(p_year integer, p_office_id uuid default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_manage boolean := hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor);
  v_year integer := coalesce(p_year, extract(year from hrms.org_today(v_actor.org_id))::integer);
  v_org hrms.organizations;
begin
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  return hrms.ok(jsonb_build_object(
    'year', v_year, 'target', v_org.holiday_target, 'can_manage', v_manage,
    'saturday_off_weeks', v_org.saturday_off_weeks, 'can_set_weekly_off', hrms.is_admin(v_actor),
    'published_count', (select count(*) from hrms.holidays h where h.org_id = v_org.id and h.state = 'published'
                          and extract(year from h.holiday_date) = v_year),
    'holidays', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', h.id, 'date', h.holiday_date, 'name', h.name, 'state', h.state, 'version', h.version,
                    'office_id', h.office_id, 'office_name', o.name, 'source', h.source)
                    order by h.holiday_date), '[]'::jsonb)
                 from hrms.holidays h left join hrms.offices o on o.id = h.office_id
                 where h.org_id = v_org.id and extract(year from h.holiday_date) = v_year
                   and (h.state = 'published' or (v_manage and h.state = 'draft'))
                   and (p_office_id is null or h.office_id is null or h.office_id = p_office_id))));
end;
$$;


-- Admin sets which Saturdays are off. Future schedule days (from tomorrow) are
-- rebuilt in one set-based pass; days with attendance are never touched. Leave
-- that falls on a Saturday that is now off is released / credited back, like a
-- newly published holiday.
create or replace function public.set_saturday_off_weeks(p_weeks integer[]) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
  v_mask integer := 0;
  v_old integer;
  v_to date;
  v_week integer;
  v_slot record;
  v_reconciled integer := 0;
begin
  perform hrms.require_admin(v_actor);
  foreach v_week in array coalesce(p_weeks, '{}'::integer[]) loop
    if v_week not between 1 and 5 then
      perform hrms.raise_error('VALIDATION_FAILED', 'Pick Saturdays 1 to 5.', '{"weeks":"Pick Saturdays 1 to 5"}'::jsonb);
    end if;
    v_mask := v_mask | (1 << (v_week - 1));
  end loop;

  select saturday_off_weeks into v_old from hrms.organizations where id = v_actor.org_id for update;
  if v_old = v_mask then
    return hrms.ok(jsonb_build_object('saturday_off_weeks', v_mask, 'leave_days_reconciled', 0));
  end if;
  update hrms.organizations set saturday_off_weeks = v_mask, version = version + 1 where id = v_actor.org_id;

  -- Rebuild already-generated future days (bounded by the 400-day engine cap).
  select least(max(shift_date), v_today + 400) into v_to
  from hrms.work_schedule_instances where org_id = v_actor.org_id;
  if v_to is not null and v_to > v_today then
    perform hrms.refresh_future_instances(v_actor.org_id, hrms.active_employee_ids(v_actor.org_id),
                                          v_today + 1, v_to);
  end if;

  for v_slot in
    select s.*, r.org_id as req_org
    from hrms.leave_day_slots s
    join hrms.requests r on r.id = s.request_id
    join hrms.work_schedule_instances w on w.employee_id = s.employee_id and w.shift_date = s.day
    where r.org_id = v_actor.org_id and s.day > v_today and s.state in ('reserved', 'approved')
      and w.kind = 'weekly_off'
  loop
    if v_slot.state = 'reserved' then
      update hrms.leave_reservations set state = 'released', released_at = now()
      where request_id = v_slot.request_id and day = v_slot.day and state = 'active';
    else
      insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id,
                                     request_id, created_by)
      select v_slot.org_id, lr.account_id, lr.allocation_id, 'credit_back', sum(lr.units)::integer,
             md5(v_slot.request_id::text || ':weekly_off:' || v_slot.day::text)::uuid, v_slot.request_id,
             v_actor.employee_id
      from hrms.leave_reservations lr
      where lr.request_id = v_slot.request_id and lr.day = v_slot.day and lr.state = 'converted'
      group by lr.account_id, lr.allocation_id
      on conflict (account_id, source_operation_id, entry_kind, allocation_id) do nothing;
      update hrms.leave_reservations set state = 'credited'
      where request_id = v_slot.request_id and day = v_slot.day and state = 'converted';
    end if;
    update hrms.leave_day_slots set state = 'released', released_at = now() where id = v_slot.id;
    update hrms.requests set units = greatest(0, units - case when v_slot.slot = 'FULL' then 2 else 1 end),
                             version = version + 1
    where id = v_slot.request_id;
    insert into hrms.approval_events (org_id, request_id, action, actor_id, reason)
    values (v_slot.org_id, v_slot.request_id, 'holiday_reconciled', v_actor.employee_id,
            format('%s became a weekly off; leave for that day was released.', v_slot.day));
    perform hrms.notify(v_slot.org_id, v_slot.employee_id, 'leave.holiday_reconciled', 'Leave balance adjusted',
      'A Saturday in your leave is now a weekly off. Your balance was updated.', '/requests/' || v_slot.request_id,
      null, md5(v_slot.id::text || ':weekly_off')::uuid);
    v_reconciled := v_reconciled + 1;
  end loop;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'org.saturday_off_changed', 'organization', v_actor.org_id,
    jsonb_build_object('from', v_old, 'to', v_mask, 'leave_days_reconciled', v_reconciled));
  return hrms.ok(jsonb_build_object('saturday_off_weeks', v_mask, 'leave_days_reconciled', v_reconciled));
end;
$$;

select hrms.apply_api_grants();
