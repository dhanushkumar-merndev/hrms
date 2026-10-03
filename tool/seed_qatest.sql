-- One year of realistic dummy data for the QATEST company ONLY (never MAIN).
-- Run by tool/seed_qatest.dart. Idempotent: re-running skips what exists.
--   * 15 extra staff QAD001..QAD015 (no login) + the 5 QA accounts
--   * shift/office/team cover from 1 Oct 2025
--   * a year of schedule days, ~90% punched (closed sessions with
--     realistic times), some late, some absent, ~1 leave day a month
--   * monthly salary for everyone
-- Set-based throughout: one statement per table, no per-day loops.
do $seed$
declare
  v_org uuid := (select id from hrms.organizations where code = 'QATEST');
  v_from date := date '2025-10-01';
  v_to date := hrms.org_today((select id from hrms.organizations where code = 'QATEST')) - 1;
  v_team uuid;
  v_office uuid;
  v_shift uuid;
  v_admin uuid;
  v_ids uuid[];
  v_pl uuid;
begin
  if v_org is null then raise exception 'QATEST company not found'; end if;
  select id into v_team from hrms.teams where org_id = v_org and name = 'QA Team';
  select id into v_office from hrms.offices where org_id = v_org order by created_at limit 1;
  select id into v_shift from hrms.shifts where org_id = v_org and name = 'General';
  select id into v_admin from hrms.employees where org_id = v_org and employee_code = 'QADMIN01';
  select id into v_pl from hrms.leave_types where org_id = v_org and code = 'PL';

  -- Staff without logins (directory, reports and payroll only).
  insert into hrms.employees (org_id, employee_code, full_name, designation, join_date, status,
                              provisioning_state, must_change_password, created_by)
  select v_org, 'QAD' || lpad(n::text, 3, '0'),
         (array['Arun', 'Bhavya', 'Charan', 'Divya', 'Ezhil', 'Farah', 'Gokul', 'Harini', 'Imran', 'Janani',
                'Karthik', 'Lavanya', 'Mani', 'Nila', 'Oviya'])[n] || ' ' ||
         (array['Kumar', 'Raj', 'S', 'Priya', 'M', 'Khan', 'R', 'V', 'Ali', 'K', 'Subramani', 'T', 'P', 'D', 'N'])[n],
         (array['Video Editor', 'Videographer', 'Designer', 'Social Media Exec', 'Photographer'])[1 + n % 5],
         v_from, 'active', 'complete', false, v_admin
  from generate_series(1, 15) n
  on conflict (org_id, employee_code) do nothing;

  update hrms.employees set join_date = v_from
  where org_id = v_org and join_date > v_from and employee_code like 'QA%';
  select array_agg(id) into v_ids from hrms.employees where org_id = v_org and status = 'active';

  -- Shift version covering the year before the existing one (published versions are immutable).
  insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local, weekly_mask,
                                   grace_seconds, lunch_start_local, lunch_end_local, lunch_paid, early_entry_seconds,
                                   checkout_extension_enabled, checkout_extension_seconds, state, published_at)
  select org_id, shift_id, (select max(version_no) + 1 from hrms.shift_versions where shift_id = v_shift), v_from,
         start_local, end_local, weekly_mask, grace_seconds, lunch_start_local, lunch_end_local, lunch_paid,
         early_entry_seconds, checkout_extension_enabled, checkout_extension_seconds, 'published', now()
  from hrms.shift_versions
  where shift_id = v_shift and effective_from > v_from
    and not exists (select 1 from hrms.shift_versions where shift_id = v_shift and effective_from <= v_from)
  order by effective_from limit 1;

  -- Assignments from v_from up to each person's first existing one (or open-ended).
  insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from, effective_to)
  select v_org, e, v_shift, v_from, (select min(effective_from) from hrms.shift_assignments a where a.employee_id = e)
  from unnest(v_ids) e
  where not exists (select 1 from hrms.shift_assignments a where a.employee_id = e and a.effective_from <= v_from);
  insert into hrms.office_assignments (org_id, employee_id, office_id, effective_from, effective_to)
  select v_org, e, v_office, v_from, (select min(effective_from) from hrms.office_assignments a where a.employee_id = e)
  from unnest(v_ids) e
  where not exists (select 1 from hrms.office_assignments a where a.employee_id = e and a.effective_from <= v_from);
  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from, effective_to, created_by, reason)
  select v_org, e, v_team, v_from, (select min(effective_from) from hrms.team_memberships a where a.employee_id = e),
         v_admin, 'Dummy data'
  from unnest(v_ids) e
  where not exists (select 1 from hrms.team_memberships a where a.employee_id = e and a.effective_from <= v_from);

  -- A year of schedule days (engine caps a call at 400 days).
  perform hrms.ensure_schedule_instances(v_org, v_ids, v_from, v_to);

  -- ~1 approved paid-leave day a month per person (request + revision + day slot).
  with picks as (
    select w.employee_id, w.shift_date
    from hrms.work_schedule_instances w
    where w.org_id = v_org and w.shift_date between v_from and v_to and w.kind = 'workday'
      and abs(hashtext(w.employee_id::text || w.shift_date::text)) % 24 = 0
      and not exists (select 1 from hrms.attendance_sessions s where s.schedule_instance_id = w.id)
      and not exists (select 1 from hrms.leave_day_slots d where d.employee_id = w.employee_id
                      and d.day = w.shift_date and d.state in ('reserved', 'approved'))
  ), reqs as (
    insert into hrms.requests (org_id, employee_id, kind, state, leave_type_id, start_date, end_date, units,
                               submitted_at, decided_at, decided_by, approved_revision)
    select v_org, p.employee_id, 'leave', 'approved', v_pl, p.shift_date, p.shift_date, 2,
           p.shift_date - 7, p.shift_date - 6, v_admin, 1
    from picks p
    returning id, employee_id, start_date
  ), revs as (
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    select r.id, 1, jsonb_build_object('leave_type_id', v_pl, 'leave_type_code', 'PL', 'leave_type_name', 'Paid Leave',
             'start_date', r.start_date, 'end_date', r.start_date, 'start_slot', 'FULL', 'end_slot', 'FULL',
             'reason', 'Personal work', 'units', 2), r.employee_id
    from reqs r
    returning request_id
  )
  insert into hrms.leave_day_slots (org_id, employee_id, request_id, revision_no, day, slot, slot_range, state)
  select v_org, r.employee_id, r.id, 1, r.start_date, 'FULL', int4range(0, 2), 'approved'
  from reqs r;

  -- Punched days: ~93% of remaining past workdays; arrivals spread -20..+45 min
  -- (some late), departures -15..+75 min around shift end.
  insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state,
                                        effective_in_at, effective_out_at, effective_source, effective_revision)
  select v_org, w.employee_id, w.id, w.shift_date, 'closed',
         w.start_at + make_interval(mins => (abs(hashtext(w.id::text || 'in')) % 66) - 20),
         w.end_at + make_interval(mins => (abs(hashtext(w.id::text || 'out')) % 91) - 15),
         'gps', 0
  from hrms.work_schedule_instances w
  where w.org_id = v_org and w.shift_date between v_from and v_to and w.kind = 'workday'
    and abs(hashtext(w.employee_id::text || w.shift_date::text)) % 100 >= 7
    and not exists (select 1 from hrms.attendance_sessions s where s.schedule_instance_id = w.id)
    and not exists (select 1 from hrms.leave_day_slots d where d.employee_id = w.employee_id
                    and d.day = w.shift_date and d.state = 'approved');

  -- Monthly salary.
  insert into hrms.salary_profiles (employee_id, org_id, monthly_salary, effective_from, updated_by)
  select e, v_org, 18000 + (abs(hashtext(e::text)) % 43) * 1000, v_from, v_admin
  from unnest(v_ids) e
  on conflict (employee_id) do update set monthly_salary = coalesce(hrms.salary_profiles.monthly_salary,
                                                                     excluded.monthly_salary);
end $seed$;

select (select count(*) from hrms.employees e where e.org_id = o.id and e.status = 'active') as employees,
       (select count(*) from hrms.work_schedule_instances w where w.org_id = o.id) as schedule_days,
       (select count(*) from hrms.attendance_sessions s where s.org_id = o.id) as punched_days,
       (select count(*) from hrms.leave_day_slots d where d.org_id = o.id and d.state = 'approved') as leave_days
from hrms.organizations o where o.code = 'QATEST';
