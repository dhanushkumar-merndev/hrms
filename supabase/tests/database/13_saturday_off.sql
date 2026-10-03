-- SAT-001..005: the company Saturday rule. Sunday stays the shift's weekly
-- off; ticked Saturdays (nth of the month) become weekly offs prospectively.
begin;
select test.standard_org();

select test.as_admin_db();
-- First day of the month after next: always in the future.
create or replace function pg_temp.m() returns date language sql as $$
  select (date_trunc('month', current_date) + interval '2 months')::date;
$$;
-- General shift works Mon–Sat from that month (published versions are immutable).
insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local, weekly_mask,
  state, published_at)
select org_id, shift_id, 2, pg_temp.m(), start_local, end_local, 63, 'published', now()
from hrms.shift_versions where shift_id = (select id from hrms.shifts where name = 'General') and version_no = 1;
-- The nth Saturday of that month.
create or replace function pg_temp.sat(n integer) returns date language sql as $$
  select pg_temp.m() + ((6 - extract(isodow from pg_temp.m())::integer + 7) % 7) + 7 * (n - 1);
$$;
create or replace function pg_temp.kind(p_code text, p_day date) returns text language sql security definer as $$
  select kind from hrms.work_schedule_instances where employee_id = test.emp(p_code) and shift_date = p_day;
$$;
insert into hrms.leave_types (org_id, code, name, paid, half_day_allowed, backdate_days)
values (test.org('TEST_ORG'), 'CL', 'Casual Leave', true, true, 7);
select test.grant_leave('ADMIN01', (select id from hrms.leave_types where code = 'CL'),
                        extract(year from pg_temp.sat(2))::integer);
create or replace function pg_temp.cl() returns uuid language sql security definer as $$
  select id from hrms.leave_types where code = 'CL'
$$;
create or replace function pg_temp.avail() returns integer language sql security definer as $$
  select coalesce(sum(av.available), 0)::integer
  from hrms.leave_accounts a cross join lateral hrms.allocation_availability(array[a.id]) av
  where a.employee_id = test.emp('ADMIN01') and a.leave_year = extract(year from pg_temp.sat(2))::integer;
$$;

select hrms.ensure_schedule_instances(test.org('TEST_ORG'), hrms.active_employee_ids(test.org('TEST_ORG')),
                                      pg_temp.m(), (pg_temp.m() + interval '1 month')::date - 1);
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(2)), 'workday', 'SAT-001 Saturdays work by default');
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(2) + 1), 'weekly_off', 'SAT-001 Sunday is the weekly off');

-- Admin books leave on the 2nd Saturday (approved at once).
select test.login('ADMIN01');
create temporary table l1 as select public.save_leave_request(null, pg_temp.cl(),
  pg_temp.sat(2), pg_temp.sat(2), 'FULL', 'FULL', 'Family function', null, true, null, gen_random_uuid()) as res;
select test.eq((select res -> 'data' ->> 'state' from l1), 'approved', 'SAT-002 leave on a working Saturday');
select test.as_admin_db();
create temporary table b1 as select pg_temp.avail() as v;

-- Only Admin may change the rule; weeks must be 1..5.
select test.login('HR01');
select test.throws('select public.set_saturday_off_weeks(array[2,4])', 'ACCESS_DENIED', 'SAT-003 HR cannot change it');
select test.login('ADMIN01');
select test.throws('select public.set_saturday_off_weeks(array[6])', 'VALIDATION_FAILED', 'SAT-003 week must be 1..5');

create temporary table s1 as select public.set_saturday_off_weeks(array[2, 4]) as res;
select test.eq((select (res -> 'data' ->> 'saturday_off_weeks')::integer from s1), 10, 'SAT-004 2nd + 4th stored as bits');
select test.eq((select (public.list_holidays(null) -> 'data' ->> 'saturday_off_weeks')::integer), 10,
  'SAT-004 holiday page sees the rule');
select test.as_admin_db();
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(1)), 'workday', 'SAT-004 1st Saturday still works');
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(2)), 'weekly_off', 'SAT-004 2nd Saturday off');
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(3)), 'workday', 'SAT-004 3rd Saturday still works');
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(4)), 'weekly_off', 'SAT-004 4th Saturday off');
select test.eq(pg_temp.avail(), (select v from b1) + 2, 'SAT-005 leave on a now-off Saturday credited back');
select test.eq((select (res -> 'data' ->> 'leave_days_reconciled')::integer from s1), 1, 'SAT-005 one leave day reconciled');

-- All Saturdays off, then back to none.
select test.login('ADMIN01');
select public.set_saturday_off_weeks(array[1, 2, 3, 4, 5]);
select test.as_admin_db();
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(1)), 'weekly_off', 'SAT-004 every Saturday off');
select test.login('ADMIN01');
select public.set_saturday_off_weeks(array[]::integer[]);
select test.as_admin_db();
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(2)), 'workday', 'SAT-004 cleared: Saturdays work again');
select test.eq(pg_temp.kind('EMP01', pg_temp.sat(2) + 1), 'weekly_off', 'SAT-004 Sunday still off');

rollback;
