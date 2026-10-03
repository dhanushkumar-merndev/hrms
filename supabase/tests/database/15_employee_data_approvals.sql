-- CHANGE-001..012: employee-data requests route by the initiator's role,
-- preserve the reviewed revision, and enforce maker-checker boundaries.
begin;
select test.standard_org();

select test.as_admin_db();

create or replace function pg_temp.actor(p_code text) returns hrms.actor
language plpgsql security definer set search_path = '' as $$
declare
  p test.people;
begin
  select * into p from test.people where code = p_code;
  return hrms.resolve_actor(p.auth_user_id, p.session_id, p.alias, 'business');
end;
$$;

-- Multi-role precedence must be deterministic: Admin > HR > everyone else.
insert into hrms.role_grants (org_id, employee_id, role, effective_from)
values
  (test.org('TEST_ORG'), test.emp('MGR02'), 'hr', now() - interval '1 day'),
  (test.org('TEST_ORG'), test.emp('HR02'), 'admin', now() - interval '1 day');

select test.eq(hrms.change_initiator_class(pg_temp.actor('EMP01')), 'employee',
  'CHANGE-001 Member initiator uses employee approval routing');
select test.eq(hrms.change_initiator_class(pg_temp.actor('MGR01')), 'employee',
  'CHANGE-001 Manager initiator uses employee approval routing');
select test.eq(hrms.change_initiator_class(pg_temp.actor('MGR02')), 'hr',
  'CHANGE-001 HR plus Manager is treated as HR');
select test.eq(hrms.change_initiator_class(pg_temp.actor('HR02')), 'admin',
  'CHANGE-001 Admin plus HR is treated as Admin');

create temporary table change_test (
  name text primary key,
  request_id uuid,
  reviewer_id uuid,
  version integer
);
grant select, update on change_test to authenticated, service_role;

insert into change_test (name, reviewer_id)
values
  ('employee_route', (hrms.change_reviewer(test.org('TEST_ORG'), test.emp('EMP01'), 'employee') ->> 'reviewer_id')::uuid),
  ('hr_route', (hrms.change_reviewer(test.org('TEST_ORG'), test.emp('HR01'), 'hr') ->> 'reviewer_id')::uuid);

select test.eq((select reviewer_id from change_test where name = 'employee_route'), test.emp('HR01'),
  'CHANGE-002 Member and Manager changes prefer an active HR');
select test.eq((select reviewer_id from change_test where name = 'hr_route'), test.emp('ADMIN01'),
  'CHANGE-002 HR changes route to an active Admin only');

-- The six new kinds are valid without weakening leave/correction constraints.
insert into hrms.requests (org_id, employee_id, kind, state, assigned_reviewer_id, route_snapshot, submitted_at)
select test.org('TEST_ORG'), test.emp('EMP01'), kind, 'submitted',
       (select reviewer_id from change_test where name = 'employee_route'),
       jsonb_build_object(
         'initiator_id', test.emp('EMP01'), 'initiator_class', 'employee',
         'reviewer_rule', 'hr_or_admin', 'target_employee_id', test.emp('EMP01'),
         'change_category', kind), now()
from unnest(array[
  'profile_details', 'employee_details', 'employee_assignment',
  'employee_status', 'salary_change', 'payslip_publish'
]) kind;
select test.eq((select count(*)::integer from hrms.requests
                where kind in ('profile_details', 'employee_details', 'employee_assignment',
                               'employee_status', 'salary_change', 'payslip_publish')), 6,
  'CHANGE-003 every employee-data request kind is accepted');

-- Seed lifecycle requests with opaque sensitive payloads. List projections,
-- notifications and audits must never echo these values.
with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id, route_snapshot, submitted_at
  ) values (
    test.org('TEST_ORG'), test.emp('EMP01'), 'profile_details', 'submitted', test.emp('HR01'),
    jsonb_build_object(
      'initiator_id', test.emp('EMP01'), 'initiator_class', 'employee',
      'reviewer_rule', 'hr_or_admin', 'target_employee_id', test.emp('EMP01'),
      'change_category', 'profile_details'), now()
  ) returning id, version
)
insert into change_test (name, request_id, reviewer_id, version)
select 'member_lifecycle', id, test.emp('HR01'), version from inserted;

insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
values ((select request_id from change_test where name = 'member_lifecycle'), 1,
  jsonb_build_object('target_version', 1, 'personal_phone', '+91 90000 12345',
                     'address', 'secret-test-address'), test.emp('EMP01'));

with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id, route_snapshot, submitted_at
  ) values (
    test.org('TEST_ORG'), test.emp('HR01'), 'employee_details', 'submitted', test.emp('ADMIN01'),
    jsonb_build_object(
      'initiator_id', test.emp('HR01'), 'initiator_class', 'hr',
      'reviewer_rule', 'admin_only', 'target_employee_id', test.emp('EMP02'),
      'change_category', 'employee_details'), now()
  ) returning id, version
)
insert into change_test (name, request_id, reviewer_id, version)
select 'hr_lifecycle', id, test.emp('ADMIN01'), version from inserted;

insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
values ((select request_id from change_test where name = 'hr_lifecycle'), 1,
  jsonb_build_object('target_version', 1, 'business_phone', '+91 95555 11111'), test.emp('HR01'));

select test.eq(hrms.change_review_authority(
    pg_temp.actor('HR01'),
    (select r from hrms.requests r where id = (select request_id from change_test where name = 'member_lifecycle'))),
  'assigned', 'CHANGE-004 assigned HR may review a Member request');
select test.eq(hrms.change_review_authority(
    pg_temp.actor('HR01'),
    (select r from hrms.requests r where id = (select request_id from change_test where name = 'hr_lifecycle'))),
  null::text, 'CHANGE-004 HR cannot review an HR-initiated request');
select test.eq(hrms.change_review_authority(
    pg_temp.actor('ADMIN01'),
    (select r from hrms.requests r where id = (select request_id from change_test where name = 'member_lifecycle'))),
  'admin', 'CHANGE-004 Admin may override a Member request');

-- A requester never becomes their own reviewer, including via a deep link.
select test.login('EMP01');
select test.throws(format('select public.open_request_for_review(%L, null)',
  (select request_id from change_test where name = 'member_lifecycle')),
  'ACCESS_DENIED', 'CHANGE-005 requester cannot open their own change for review');

-- Opening atomically locks the current revision. Return, withdrawal and stale
-- decisions retain the existing immutable request/event lifecycle.
select test.login('HR01');
select test.eq((public.open_request_for_review(
    (select request_id from change_test where name = 'member_lifecycle'), null)
    -> 'data' ->> 'locked_revision')::integer, 1,
  'CHANGE-006 first reviewer open locks exactly the current revision');
select test.throws(format($q$select public.decide_request(%L, 'approve', null, 1, %L)$q$,
  (select request_id from change_test where name = 'member_lifecycle'), gen_random_uuid()),
  'STALE_VERSION', 'CHANGE-006 stale decisions cannot apply an older revision');
select public.decide_request(
  (select request_id from change_test where name = 'member_lifecycle'),
  'return', 'Please correct it', 2, gen_random_uuid());

select test.login('EMP01');
select public.withdraw_request(
  (select request_id from change_test where name = 'member_lifecycle'), 3, 'No longer needed');
select test.eq(public.get_my_request(
    (select request_id from change_test where name = 'member_lifecycle')) -> 'data' ->> 'state', 'cancelled',
  'CHANGE-007 returned employee-data request can be withdrawn');

-- HR-originated requests are Admin-only even if an HR is assigned manually.
select test.login('MGR02');
select test.throws(format('select public.open_request_for_review(%L, null)',
  (select request_id from change_test where name = 'hr_lifecycle')),
  'ACCESS_DENIED', 'CHANGE-008 HR cannot open another HR-originated request');
select test.login('ADMIN01');
select test.eq((public.open_request_for_review(
    (select request_id from change_test where name = 'hr_lifecycle'), null)
    -> 'data' ->> 'locked_revision')::integer, 1,
  'CHANGE-008 Admin opens and locks an HR-originated request');

-- Reassignment preserves the initiator rule and forbids the requester.
select test.as_admin_db();
with inserted as (
  insert into hrms.requests (
    org_id, employee_id, kind, state, assigned_reviewer_id, route_snapshot, submitted_at
  ) values (
    test.org('TEST_ORG'), test.emp('EMP02'), 'profile_details', 'submitted', test.emp('HR01'),
    jsonb_build_object(
      'initiator_id', test.emp('EMP02'), 'initiator_class', 'employee',
      'reviewer_rule', 'hr_or_admin', 'target_employee_id', test.emp('EMP02'),
      'change_category', 'profile_details'), now()
  ) returning id, version
)
insert into change_test (name, request_id, reviewer_id, version)
select 'reassign', id, test.emp('HR01'), version from inserted;
insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
values ((select request_id from change_test where name = 'reassign'), 1,
        '{"target_version":1}'::jsonb, test.emp('EMP02'));

select test.login('ADMIN01');
select public.reassign_request((select request_id from change_test where name = 'reassign'),
  test.emp('HR02'), 'Workload', 1);
select test.as_admin_db();
select test.eq((select assigned_reviewer_id from hrms.requests
                where id = (select request_id from change_test where name = 'reassign')), test.emp('HR02'),
  'CHANGE-009 Admin can reassign a Member request to another HR');
select test.login('ADMIN01');
select test.throws(format($q$select public.reassign_request(%L, %L, 'bad', 2)$q$,
  (select request_id from change_test where name = 'reassign'), test.emp('EMP02')),
  'VALIDATION_FAILED', 'CHANGE-009 request cannot be reassigned to its initiator');
select test.throws(format($q$select public.reassign_request(%L, %L, 'bad', 2)$q$,
  (select request_id from change_test where name = 'hr_lifecycle'), test.emp('MGR02')),
  'VALIDATION_FAILED', 'CHANGE-009 HR-originated request cannot be reassigned to HR');

-- Target versions are rechecked immediately before apply.
select test.as_admin_db();
select hrms.assert_change_target_version(
  (select r from hrms.requests r where id = (select request_id from change_test where name = 'hr_lifecycle')),
  '{"target_version":1}'::jsonb);
update hrms.employees set version = version + 1 where id = test.emp('EMP02');
select test.throws(format($q$select hrms.assert_change_target_version(
  (select r from hrms.requests r where id = %L), '{"target_version":1}'::jsonb)$q$,
  (select request_id from change_test where name = 'hr_lifecycle')),
  'STALE_VERSION', 'CHANGE-010 target changes are detected at approval time');

-- Queue and notification projections reveal categories, never proposed values.
select test.login('HR02');
select test.ok(public.list_review_queue()::text not like '%secret-test-address%'
               and public.list_review_queue()::text not like '%90000 12345%',
  'CHANGE-011 review lists do not expose sensitive proposed values');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.notifications
                where concat_ws(' ', title, body, data::text) like '%secret-test-address%'
                   or concat_ws(' ', title, body, data::text) like '%90000 12345%'), 0,
  'CHANGE-011 notification payloads contain no personal values');
select test.eq((select count(*)::integer from hrms.audit_logs
                where changes::text like '%secret-test-address%'
                   or changes::text like '%90000 12345%'), 0,
  'CHANGE-011 audit metadata contains no personal values');

-- Remove every eligible reviewer: routing remains submitted/unassigned and
-- never applies automatically.
update hrms.role_grants set revoked_at = now()
where employee_id in (test.emp('HR01'), test.emp('MGR02'), test.emp('ADMIN01'), test.emp('HR02'))
  and revoked_at is null;
select test.eq(hrms.change_reviewer(test.org('TEST_ORG'), test.emp('EMP03'), 'employee') ->> 'reviewer_id',
  null::text, 'CHANGE-012 missing reviewers produce an explicit unassigned route');

rollback;
