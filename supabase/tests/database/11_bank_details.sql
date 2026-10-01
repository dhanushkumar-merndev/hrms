-- BANK-001..008: employees submit private bank proof; initial setup is
-- HR/Admin approved, later changes are Admin-only, immutable and audited.
begin;
select test.standard_org();

create or replace function pg_temp.bank_proof(p_code text, p_name text default 'cancelled-cheque.pdf') returns uuid
language plpgsql security definer as $$
declare
  v_rec uuid;
  v_ver uuid;
  v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, title, created_by)
  values (v_org, test.emp(p_code), 'correction_attachment', 'Bank proof', test.emp(p_code))
  returning id into v_rec;
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
create temporary table bank_test as
select pg_temp.bank_proof('EMP01') as proof1,
       pg_temp.bank_proof('EMP01', 'new-passbook.pdf') as proof2,
       pg_temp.bank_proof('EMP02', 'wrong-owner.pdf') as wrong_proof,
       null::uuid as initial_request,
       null::uuid as change_request;
grant select, update on bank_test to authenticated, service_role;

-- BANK-001 validation requires proof owned by the employee and valid fields.
select test.login('EMP01');
select test.throws(format($q$select public.save_bank_details_request(
  null, 'HDFC Bank', 'Employee E1', '12345678', 'HDFC0001234', null, %L, null, %L)$q$,
  (select wrong_proof from bank_test), gen_random_uuid()), 'VALIDATION_FAILED',
  'BANK-001 another employee proof is rejected');
select test.throws(format($q$select public.save_bank_details_request(
  null, 'HDFC Bank', 'Employee E1', '123', 'BAD', null, null, null, %L)$q$,
  gen_random_uuid()), 'VALIDATION_FAILED', 'BANK-001 invalid fields and missing proof are rejected');

-- BANK-002 initial details are stored only as last four and assigned to HR.
update bank_test set initial_request = (
  public.save_bank_details_request(null, ' HDFC Bank ', ' Employee E1 ', '000012345678',
    'hdfc0001234', null, (select proof1 from bank_test), null, gen_random_uuid())
  -> 'data' ->> 'id')::uuid;
select test.eq(public.get_my_salary() -> 'data' -> 'bank_request' ->> 'state', 'submitted',
  'BANK-002 pending request is visible on My salary');
select test.eq(public.get_my_request((select initial_request from bank_test))
                 -> 'data' -> 'revisions' -> 0 -> 'payload' ->> 'account_last4', '5678',
  'BANK-002 only last four account digits are stored');
select test.ok(public.get_my_request((select initial_request from bank_test))::text not like '%000012345678%',
  'BANK-002 full account number is never persisted');
select test.eq(public.get_my_request((select initial_request from bank_test))
                 -> 'data' -> 'reviewer' ->> 'id', test.emp('HR01')::text,
  'BANK-002 initial setup routes to HR');
select test.throws(format($q$select public.save_bank_details_request(
  null, 'Other', 'Employee E1', '99998888', 'HDFC0001234', null, %L, null, %L)$q$,
  (select proof2 from bank_test), gen_random_uuid()), 'REQUEST_LOCKED',
  'BANK-002 only one active bank request is allowed');

-- BANK-003 HR approves initial setup and approved data/proof become locked.
select test.login('HR01');
select test.eq((public.open_request_for_review((select initial_request from bank_test), null)
                ->> 'version')::integer, 2, 'BANK-003 HR opens initial request');
select public.decide_request((select initial_request from bank_test), 'approve', null, 2);
select test.login('EMP01');
select test.eq(public.get_my_salary() -> 'data' -> 'profile' ->> 'bank_status', 'approved',
  'BANK-003 approved status shown to employee');
select test.eq(public.get_my_salary() -> 'data' -> 'profile' ->> 'account_last4', '5678',
  'BANK-003 approved last four shown');
select test.eq(public.get_my_salary() -> 'data' -> 'bank_request', 'null'::jsonb,
  'BANK-003 completed request no longer appears pending');
select test.throws(format($q$select public.save_bank_details_request(
  %L, 'Changed', 'Employee E1', '9999', 'HDFC0001234', 'edit old', %L, 3, %L)$q$,
  (select initial_request from bank_test), (select proof2 from bank_test), gen_random_uuid()),
  'REQUEST_LOCKED', 'BANK-003 approved request cannot be edited');

-- BANK-004 payroll managers cannot bypass requests by editing bank fields.
select test.login('HR01');
select test.throws(format($q$select public.set_employee_salary(
  %L, '{"bank_name":"Bypass Bank"}', 'bypass', 2)$q$, test.emp('EMP01')),
  'REQUEST_REQUIRED', 'BANK-004 direct HR bank update is blocked');

-- BANK-005 a later change needs a reason and routes only to Admin.
select test.login('EMP01');
select test.throws(format($q$select public.save_bank_details_request(
  null, 'ICICI Bank', 'Employee E1', '99998888', 'ICIC0004321', null, %L, null, %L)$q$,
  (select proof2 from bank_test), gen_random_uuid()), 'VALIDATION_FAILED',
  'BANK-005 approved account change requires a reason');
update bank_test set change_request = (
  public.save_bank_details_request(null, 'ICICI Bank', 'Employee E1', '99998888',
    'ICIC0004321', 'Changed salary account', (select proof2 from bank_test), null, gen_random_uuid())
  -> 'data' ->> 'id')::uuid;
select test.eq(public.get_my_request((select change_request from bank_test))
                 -> 'data' ->> 'request_mode', 'change',
  'BANK-005 change records the Admin-only approval rule');
select test.eq(public.get_my_request((select change_request from bank_test))
                 -> 'data' -> 'reviewer' ->> 'id', test.emp('ADMIN01')::text,
  'BANK-005 approved-account change routes to Admin');

-- BANK-006 HR cannot open or decide the change; Admin can approve it.
select test.login('HR01');
select test.throws(format('select public.open_request_for_review(%L, null)',
  (select change_request from bank_test)), 'ACCESS_DENIED', 'BANK-006 HR cannot review a bank change');
select test.login('ADMIN01');
select public.open_request_for_review((select change_request from bank_test), null);
select public.decide_request((select change_request from bank_test), 'approve', null, 2);
select test.login('EMP01');
select test.eq(public.get_my_salary() -> 'data' -> 'profile' ->> 'bank_name', 'ICICI Bank',
  'BANK-006 Admin-approved change is applied');
select test.eq(public.get_my_salary() -> 'data' -> 'profile' ->> 'account_last4', '8888',
  'BANK-006 new account remains masked to last four');

-- BANK-007 proof bytes and approval history remain immutable and auditable.
select test.as_admin_db();
select test.throws(format($q$update hrms.file_versions set object_key = 'changed'
  where id = %L$q$, (select proof2 from bank_test)), '42501',
  'BANK-007 validated proof bytes cannot change');
select test.eq((select count(*)::integer from hrms.approval_events
                where request_id in ((select initial_request from bank_test), (select change_request from bank_test))
                  and action = 'approved'), 2, 'BANK-007 both approvals have immutable events');
select test.eq((select count(*)::integer from hrms.audit_logs
                where action = 'salary.bank_details_approved' and target_employee_id = test.emp('EMP01')), 2,
  'BANK-007 bank approvals are audited');

-- BANK-008 the new RPC follows the API permission boundary.
select test.as_anon();
select test.throws($q$select public.save_bank_details_request(
  null, 'x', 'x', '1234', 'HDFC0001234', null, null, null, gen_random_uuid())$q$,
  '42501', 'BANK-008 anon cannot submit bank details');

rollback;
