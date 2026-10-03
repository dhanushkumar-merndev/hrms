-- PROFILE-001..010: own private details follow initiator-based maker-checker.
begin;
select test.standard_org();

create temporary table profile_test (
  name text primary key,
  request_id uuid,
  request_version integer,
  private_version integer
);
grant select, insert, update on profile_test to authenticated, service_role;

-- Member proposal: approved data remains unchanged and the request routes to HR.
select test.login('EMP01');
insert into profile_test (name, private_version)
select 'member', coalesce((public.get_my_profile() -> 'data' -> 'private' ->> 'version')::integer, 1);

with submitted as (
  select public.save_profile_details_request(
    null,
    '{"personal_phone":"+91 90000 12345","address":"synthetic-profile-secret"}'::jsonb,
    (select private_version from profile_test where name = 'member'),
    null,
    gen_random_uuid()) as result
)
update profile_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted),
  request_version = (select (result ->> 'version')::integer from submitted)
where name = 'member';

select test.eq(public.get_my_profile() -> 'data' -> 'private' ->> 'personal_phone', null::text,
  'PROFILE-001 pending values do not replace approved profile data');
select test.eq(public.get_my_profile() -> 'data' -> 'profile_request' ->> 'state', 'submitted',
  'PROFILE-001 own profile exposes safe pending status');
select test.as_admin_db();
select test.eq((select assigned_reviewer_id from hrms.requests
                where id = (select request_id from profile_test where name = 'member')),
               test.emp('HR01'),
  'PROFILE-002 Member profile changes prefer HR review');
select test.eq((select route_snapshot ->> 'initiator_class' from hrms.requests
                where id = (select request_id from profile_test where name = 'member')),
               'employee',
  'PROFILE-002 route records employee initiator class');
select test.eq((select count(*)::integer from hrms.audit_logs
                where changes::text like '%synthetic-profile-secret%'
                   or changes::text like '%90000 12345%'), 0,
  'PROFILE-003 audit metadata does not contain private values');
select test.eq((select count(*)::integer from hrms.notifications
                where concat_ws(' ', title, body, data::text) like '%synthetic-profile-secret%'
                   or concat_ws(' ', title, body, data::text) like '%90000 12345%'), 0,
  'PROFILE-003 notifications do not contain private values');

-- The assigned HR locks and approves exactly the reviewed revision.
select test.login('HR01');
update profile_test set request_version =
  (public.open_request_for_review(
    (select request_id from profile_test where name = 'member'), null) ->> 'version')::integer
where name = 'member';
select public.decide_request(
  (select request_id from profile_test where name = 'member'),
  'approve', null,
  (select request_version from profile_test where name = 'member'),
  gen_random_uuid());
select test.as_admin_db();
select test.eq((select personal_phone from hrms.employee_private_details
                where employee_id = test.emp('EMP01')), '+91 90000 12345',
  'PROFILE-004 approval transactionally applies the locked profile revision');
select test.eq((select address from hrms.employee_private_details
                where employee_id = test.emp('EMP01')), 'synthetic-profile-secret',
  'PROFILE-004 all validated fields in the approved patch are applied');

-- HR's own proposal is Admin-only.
select test.login('HR01');
insert into profile_test (name, private_version)
select 'hr', (public.get_my_profile() -> 'data' -> 'private' ->> 'version')::integer;
with submitted as (
  select public.save_profile_details_request(
    null, '{"personal_email":"qa-hr-profile@example.invalid"}'::jsonb,
    (select private_version from profile_test where name = 'hr'), null,
    gen_random_uuid()) as result
)
update profile_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted),
  request_version = (select (result ->> 'version')::integer from submitted)
where name = 'hr';
select test.as_admin_db();
select test.eq((select assigned_reviewer_id from hrms.requests
                where id = (select request_id from profile_test where name = 'hr')),
               test.emp('ADMIN01'),
  'PROFILE-005 HR profile changes route to Admin');
select test.eq((select route_snapshot ->> 'initiator_class' from hrms.requests
                where id = (select request_id from profile_test where name = 'hr')),
               'hr',
  'PROFILE-005 HR initiator class is immutable in the route snapshot');
select test.login('HR02');
select test.throws(format('select public.open_request_for_review(%L, null)',
  (select request_id from profile_test where name = 'hr')),
  'ACCESS_DENIED', 'PROFILE-005 another HR cannot review an HR-originated profile request');

-- Admin's own profile applies immediately, without a fake self-approval request.
select test.login('ADMIN01');
insert into profile_test (name, private_version)
select 'admin', (public.get_my_profile() -> 'data' -> 'private' ->> 'version')::integer;
select test.eq(
  public.save_profile_details_request(
    null, '{"personal_phone":"+91 98888 00001"}'::jsonb,
    (select private_version from profile_test where name = 'admin'), null,
    gen_random_uuid()) -> 'data' ->> 'applied',
  'true', 'PROFILE-006 Admin profile changes apply immediately');
select test.as_admin_db();
select test.eq((select personal_phone from hrms.employee_private_details
                where employee_id = test.emp('ADMIN01')), '+91 98888 00001',
  'PROFILE-006 Admin direct apply uses the shared profile validator');
select test.eq((select count(*)::integer from hrms.requests
                where employee_id = test.emp('ADMIN01') and kind = 'profile_details'), 0,
  'PROFILE-006 Admin direct apply does not create a fake self-approval request');

-- A target version change after submission makes approval fail stale.
select test.login('EMP02');
insert into profile_test (name, private_version)
select 'stale', (public.get_my_profile() -> 'data' -> 'private' ->> 'version')::integer;
with submitted as (
  select public.save_profile_details_request(
    null, '{"address":"stale proposal"}'::jsonb,
    (select private_version from profile_test where name = 'stale'), null,
    gen_random_uuid()) as result
)
update profile_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted),
  request_version = (select (result ->> 'version')::integer from submitted)
where name = 'stale';
select test.as_admin_db();
insert into hrms.employee_private_details (employee_id, org_id, address, version)
values (test.emp('EMP02'), test.org('TEST_ORG'), 'newer approved data', 2)
on conflict (employee_id) do update set address = excluded.address, version = 2;
select test.login('HR01');
update profile_test set request_version =
  (public.open_request_for_review(
    (select request_id from profile_test where name = 'stale'), null) ->> 'version')::integer
where name = 'stale';
select test.throws(format(
  'select public.decide_request(%L, %L, null, %s, %L)',
  (select request_id from profile_test where name = 'stale'), 'approve',
  (select request_version from profile_test where name = 'stale'), gen_random_uuid()),
  'STALE_VERSION', 'PROFILE-007 approval cannot overwrite newer approved profile data');

-- Duplicate active requests and unapproved fields are rejected.
select test.login('EMP02');
select test.throws(format(
  'select public.save_profile_details_request(null, %L::jsonb, 2, null, %L)',
  '{"personal_phone":"+91 90000 22222"}', gen_random_uuid()),
  'REQUEST_LOCKED', 'PROFILE-008 only one active profile request is allowed');
select test.throws(format(
  'select public.save_profile_details_request(null, %L::jsonb, 2, null, %L)',
  '{"business_phone":"private bypass"}', gen_random_uuid()),
  'ACCESS_DENIED', 'PROFILE-009 own profile cannot propose HR-managed fields');

rollback;
