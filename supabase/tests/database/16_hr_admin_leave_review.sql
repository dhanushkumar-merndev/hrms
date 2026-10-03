-- LEAVE-AUTH-001..007: only HR/Admin decide leave, and eligible reviewer
-- pools can recover requests that have no usable individual assignee.
begin;
select test.standard_org();
select test.as_admin_db();

insert into hrms.leave_types (
  org_id, code, name, paid, half_day_allowed, backdate_days
) values (
  test.org('TEST_ORG'), 'QA', 'QA Leave', false, true, 30
);

create or replace function pg_temp.actor(p_code text) returns hrms.actor
language plpgsql security definer set search_path = '' as $$
declare p test.people;
begin
  select * into p from test.people where code = p_code;
  return hrms.resolve_actor(p.auth_user_id, p.session_id, p.alias, 'business');
end;
$$;

create or replace function pg_temp.team() returns uuid
language sql security definer set search_path = '' as $$
  select id from hrms.teams
  where org_id = test.org('TEST_ORG')
  order by name limit 1
$$;

create temporary table pool_test (name text primary key, request_id uuid);
grant select on pool_test to authenticated, service_role;

select test.eq(
  hrms.resolve_reviewer(
    test.org('TEST_ORG'), test.emp('EMP01'), 'leave', current_date
  ) ->> 'reviewer_id',
  test.emp('HR01')::text,
  'LEAVE-AUTH-001 Member leave routes to active HR, never Manager');

with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id,
    route_snapshot, submitted_at, leave_type_id, start_date, end_date, units
  ) values (
    test.org('TEST_ORG'), test.emp('EMP01'), 'leave', 'submitted',
    test.emp('MGR01'), '{"mode":"manager"}'::jsonb, now(),
    (select id from hrms.leave_types where code = 'QA'),
    current_date + 10, current_date + 10, 2
  ) returning id
)
insert into pool_test select 'legacy_manager_leave', id from inserted;
insert into hrms.request_revisions (
  request_id, revision_no, payload, created_by
)
values (
  (select request_id from pool_test where name = 'legacy_manager_leave'),
  1, '{"reason":"Synthetic test"}'::jsonb, test.emp('EMP01'));

select test.eq(
  hrms.review_authority(
    pg_temp.actor('MGR01'),
    (select r from hrms.requests r where id = (
      select request_id from pool_test where name = 'legacy_manager_leave'))
  ), null::text,
  'LEAVE-AUTH-002 Manager cannot review leave even when historically assigned');
select test.eq(
  hrms.review_authority(
    pg_temp.actor('HR01'),
    (select r from hrms.requests r where id = (
      select request_id from pool_test where name = 'legacy_manager_leave'))
  ), 'pool',
  'LEAVE-AUTH-003 HR can recover leave with an ineligible assignee');

select test.login('MGR01');
select test.throws(format(
  'select public.open_request_for_review(%L)',
  (select request_id from pool_test where name = 'legacy_manager_leave')),
  'ACCESS_DENIED',
  'LEAVE-AUTH-002 Manager direct-link review is denied');

select test.login('HR01');
select test.ok(
  public.list_review_queue(null, 'unassigned')::text like
    '%' || (select request_id::text from pool_test where name = 'legacy_manager_leave') || '%',
  'LEAVE-AUTH-003 HR unassigned queue exposes recoverable leave');
create temporary table opened_leave as
select public.open_request_for_review(
  (select request_id from pool_test where name = 'legacy_manager_leave')) as res;
select test.eq(
  public.decide_request(
    (select request_id from pool_test where name = 'legacy_manager_leave'),
    'reject', 'Synthetic rejection',
    (select (res ->> 'version')::integer from opened_leave)
  ) -> 'data' ->> 'state',
  'rejected',
  'LEAVE-AUTH-004 HR can reject recovered leave');

select test.as_admin_db();
with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id,
    target_employee_id, route_snapshot, submitted_at
  ) values (
    test.org('TEST_ORG'), test.emp('EMP02'), 'profile_details', 'submitted', null,
    test.emp('EMP02'), jsonb_build_object(
      'initiator_class', 'employee', 'reviewer_rule', 'hr_or_admin',
      'target_employee_id', test.emp('EMP02')), now()
  ) returning id
)
insert into pool_test select 'unassigned_employee_change', id from inserted;
insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
values (
  (select request_id from pool_test where name = 'unassigned_employee_change'),
  1, '{"target_version":1}'::jsonb, test.emp('EMP02'));
select test.eq(
  hrms.change_review_authority(
    pg_temp.actor('HR01'),
    (select r from hrms.requests r where id = (
      select request_id from pool_test where name = 'unassigned_employee_change'))
  ), 'pool',
  'LEAVE-AUTH-005 HR can recover unassigned Member employee-data changes');

with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id,
    target_employee_id, route_snapshot, submitted_at
  ) values (
    test.org('TEST_ORG'), test.emp('HR01'), 'employee_details', 'submitted', null,
    test.emp('EMP03'), jsonb_build_object(
      'initiator_class', 'hr', 'reviewer_rule', 'admin_only',
      'target_employee_id', test.emp('EMP03')), now()
  ) returning id
)
insert into pool_test select 'unassigned_hr_change', id from inserted;
select test.eq(
  hrms.change_review_authority(
    pg_temp.actor('HR02'),
    (select r from hrms.requests r where id = (
      select request_id from pool_test where name = 'unassigned_hr_change'))
  ), null::text,
  'LEAVE-AUTH-006 HR cannot recover an HR-originated change');
select test.eq(
  hrms.change_review_authority(
    pg_temp.actor('ADMIN01'),
    (select r from hrms.requests r where id = (
      select request_id from pool_test where name = 'unassigned_hr_change'))
  ), 'admin',
  'LEAVE-AUTH-006 Admin can recover an HR-originated change');

select test.login('ADMIN01');
select test.throws(format(
  $q$select public.reassign_request(%L, %L, 'Not allowed', 1)$q$,
  (select request_id from pool_test where name = 'legacy_manager_leave'),
  test.emp('MGR01')),
  'VALIDATION_FAILED',
  'LEAVE-AUTH-007 leave cannot be reassigned to a Manager');
select test.throws(format(
  $q$select public.set_approval_route(%L, 'leave', 'manager', null, null, 'Not allowed')$q$,
  pg_temp.team()),
  'VALIDATION_FAILED',
  'LEAVE-AUTH-007 Admin cannot configure Manager leave approval');

rollback;
