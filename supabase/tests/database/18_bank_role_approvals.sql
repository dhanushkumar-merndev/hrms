-- BANK-ROLE-001..007: bank changes route by initiator role and Admin applies directly.
begin;
select test.standard_org();

create or replace function pg_temp.bank_proof(
  p_code text, p_name text default 'synthetic-bank-proof.pdf'
) returns uuid
language plpgsql security definer as $$
declare
  v_rec uuid;
  v_ver uuid;
  v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (
    org_id, owner_employee_id, class, title, created_by
  ) values (
    v_org, test.emp(p_code), 'correction_attachment', 'QA bank proof', test.emp(p_code)
  ) returning id into v_rec;
  insert into hrms.file_versions (
    org_id, file_record_id, version_no, state, object_key, original_filename,
    declared_mime, detected_mime, declared_size_bytes, size_bytes, sha256,
    uploaded_by, validated_at
  ) values (
    v_org, v_rec, 1, 'validated', v_org || '/' || gen_random_uuid(), p_name,
    'application/pdf', 'application/pdf', 1000, 1000,
    encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
    test.emp(p_code), now()
  ) returning id into v_ver;
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  return v_ver;
end $$;

select test.as_admin_db();
create temporary table bank_role_test (
  name text primary key,
  proof uuid,
  request_id uuid,
  request_version integer
);
insert into bank_role_test (name, proof) values
  ('hr', pg_temp.bank_proof('HR01')),
  ('admin', pg_temp.bank_proof('ADMIN01')),
  ('manager', pg_temp.bank_proof('MGR01')),
  ('stale', pg_temp.bank_proof('EMP02'));
grant select, insert, update on bank_role_test to authenticated, service_role;

-- HR's own bank request is Admin-only.
select test.login('HR01');
with submitted as (
  select public.save_bank_details_request(
    null, 'QA Bank', 'HR H', '12345678', 'HDFC0001234', null,
    (select proof from bank_role_test where name = 'hr'), null,
    gen_random_uuid()) as result
)
update bank_role_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted),
  request_version = (select (result ->> 'version')::integer from submitted)
where name = 'hr';
select test.as_admin_db();
select test.eq((select route_snapshot ->> 'initiator_class' from hrms.requests
                where id = (select request_id from bank_role_test where name = 'hr')),
  'hr', 'BANK-ROLE-001 HR bank request records HR initiator class');
select test.eq((select assigned_reviewer_id from hrms.requests
                where id = (select request_id from bank_role_test where name = 'hr')),
  test.emp('ADMIN01'), 'BANK-ROLE-001 HR bank request routes to Admin');
select test.login('HR02');
select test.throws(format('select public.open_request_for_review(%L, null)',
  (select request_id from bank_role_test where name = 'hr')),
  'ACCESS_DENIED', 'BANK-ROLE-002 HR cannot review another HR-originated bank request');

-- Admin changes apply now, use the same proof validator, and create no request.
select test.login('ADMIN01');
select test.eq(public.save_bank_details_request(
    null, 'Admin QA Bank', 'Admin A', '99990001', 'ICIC0004321', null,
    (select proof from bank_role_test where name = 'admin'), null,
    gen_random_uuid()) -> 'data' ->> 'applied',
  'true', 'BANK-ROLE-003 Admin bank details apply immediately');
select test.as_admin_db();
select test.eq((select account_last4 from hrms.salary_profiles
                where employee_id = test.emp('ADMIN01')), '0001',
  'BANK-ROLE-003 Admin direct apply persists only the last four digits');
select test.eq((select count(*)::integer from hrms.requests
                where employee_id = test.emp('ADMIN01') and kind = 'bank_details'), 0,
  'BANK-ROLE-003 Admin direct apply creates no fake approval request');
select test.eq((select count(*)::integer from hrms.audit_logs
                where action = 'salary.bank_details_updated'
                  and actor_employee_id = test.emp('ADMIN01')
                  and target_employee_id = test.emp('ADMIN01')), 1,
  'BANK-ROLE-003 Admin direct apply is attributed in audit history');

-- A Manager uses employee routing and prefers HR.
select test.login('MGR01');
with submitted as (
  select public.save_bank_details_request(
    null, 'Manager QA Bank', 'Manager M1', '55556666', 'SBIN0001234', null,
    (select proof from bank_role_test where name = 'manager'), null,
    gen_random_uuid()) as result
)
update bank_role_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted)
where name = 'manager';
select test.as_admin_db();
select test.eq((select assigned_reviewer_id from hrms.requests
                where id = (select request_id from bank_role_test where name = 'manager')),
  test.emp('HR01'), 'BANK-ROLE-004 Manager bank request follows employee routing');

-- Current-proof and target-version checks run again inside approval.
select test.login('EMP02');
with submitted as (
  select public.save_bank_details_request(
    null, 'Stale QA Bank', 'Employee E2', '11112222', 'YESB0001234', null,
    (select proof from bank_role_test where name = 'stale'), null,
    gen_random_uuid()) as result
)
update bank_role_test set
  request_id = (select (result -> 'data' ->> 'id')::uuid from submitted)
where name = 'stale';
select test.as_admin_db();
update hrms.file_records set current_version_id = null
where current_version_id = (select proof from bank_role_test where name = 'stale');
select test.login('HR01');
update bank_role_test set request_version =
  (public.open_request_for_review(
    (select request_id from bank_role_test where name = 'stale'), null) ->> 'version')::integer
where name = 'stale';
select test.throws(format(
  'select public.decide_request(%L, %L, null, %s, %L)',
  (select request_id from bank_role_test where name = 'stale'), 'approve',
  (select request_version from bank_role_test where name = 'stale'), gen_random_uuid()),
  'VALIDATION_FAILED', 'BANK-ROLE-005 approval rechecks that proof is still current');

select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.audit_logs
                where changes::text like '%99990001%'
                   or changes::text like '%11112222%'), 0,
  'BANK-ROLE-006 audit metadata never contains full bank account numbers');
select test.eq((select count(*)::integer from hrms.notifications
                where concat_ws(' ', title, body, data::text) like '%99990001%'
                   or concat_ws(' ', title, body, data::text) like '%11112222%'), 0,
  'BANK-ROLE-006 notifications never contain bank account numbers');

rollback;
