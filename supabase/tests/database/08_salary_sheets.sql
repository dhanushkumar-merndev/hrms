-- SAL-001..006: salary details are payroll-only, own-only for employees,
-- audited without amounts; SHEET-001..004: the Google Sheet mirror is
-- Admin-only and the salary tab needs a password confirmation.
begin;
select test.standard_org();

create or replace function pg_temp.reauth(p_code text, p_action text) returns void
language sql security definer as $$
  insert into hrms.reauthentication_grants (org_id, employee_id, session_id, action, issued_at, expires_at)
  select p.org_id, p.employee_id, p.session_id, p_action, now(), now() + interval '4 minutes'
  from test.people p where p.code = p_code;
$$;
create or replace function pg_temp.audit_changes(p_action text) returns text language sql security definer as $$
  select coalesce(string_agg(coalesce(changes::text, ''), '|'), '') from hrms.audit_logs where action = p_action $$;
-- A published payslip for EMP01 (metadata only).
create or replace function pg_temp.payslip(p_code text, p_month date) returns void
language plpgsql security definer as $$
declare v_rec uuid; v_ver uuid; v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, period_start, period_end)
  values (v_org, test.emp(p_code), 'payslip', p_month, (p_month + interval '1 month - 1 day')::date) returning id into v_rec;
  insert into hrms.file_versions (org_id, file_record_id, version_no, state, object_key, original_filename, declared_mime,
                                  detected_mime, declared_size_bytes, size_bytes, sha256, validated_at, published_at)
  values (v_org, v_rec, 1, 'published', v_org || '/' || gen_random_uuid(), 'slip.pdf', 'application/pdf', 'application/pdf',
          1000, 1000, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now(), now())
  returning id into v_ver;
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  insert into hrms.payslips (org_id, employee_id, salary_month, file_record_id, current_file_version_id, published_at)
  values (v_org, test.emp(p_code), p_month, v_rec, v_ver, now());
end $$;
select pg_temp.payslip('EMP01', date '2026-08-01');
select pg_temp.payslip('EMP01', date '2026-09-01');

-- SAL-001 members and managers cannot read or write anyone's salary.
select test.login('EMP01');
select test.throws(format('select public.get_employee_salary(%L)', test.emp('EMP02')), 'ACCESS_DENIED',
  'SAL-001 member cannot read another salary');
select test.throws(format($q$select public.set_employee_salary(%L, '{"monthly_salary": 1}', null, 0)$q$, test.emp('EMP01')),
  'ACCESS_DENIED', 'SAL-001 member cannot set own salary');
select test.login('MGR01');
select test.throws(format('select public.get_employee_salary(%L)', test.emp('EMP01')), 'ACCESS_DENIED',
  'SAL-001 manager has no team salary access');
select test.throws(format('select public.set_payslip_amount(%L, %L, 100)', test.emp('EMP01'), date '2026-09-01'),
  'ACCESS_DENIED', 'SAL-001 manager cannot set paid amounts');

-- SAL-002 HR with the payroll grant sets salary. Bank details are employee
-- submitted and approved through the separate proof-backed request flow.
select test.login('HR01');
select test.throws(format($q$select public.set_employee_salary(%L, '{"monthly_salary": "abc"}', null, 0)$q$, test.emp('EMP01')),
  'VALIDATION_FAILED', 'SAL-002 non-numeric salary rejected');
create temporary table s1 as select public.set_employee_salary(test.emp('EMP01'),
  '{"monthly_salary": 45000, "effective_from": "2026-04-01"}'::jsonb, null, 0) as r;
grant select on s1 to authenticated, service_role;
select test.eq((select (r -> 'data' -> 'profile' ->> 'monthly_salary')::numeric from s1), 45000::numeric,
  'SAL-002 salary saved');
select test.throws(format($q$select public.set_employee_salary(%L, '{"bank_name":"HDFC Bank","account_last4":"5678","ifsc":"HDFC0001234"}', null, 2)$q$,
  test.emp('EMP01')), 'REQUEST_REQUIRED', 'SAL-002 direct bank edit is blocked');
select test.throws(format($q$select public.set_employee_salary(%L, '{"monthly_salary": 50000}', null, 1)$q$, test.emp('EMP01')),
  'STALE_VERSION', 'SAL-002 stale version rejected');
select test.throws(format($q$select public.set_employee_salary(%L, '{"monthly_salary": 50000}', null, 2)$q$, test.emp('EMP01')),
  'VALIDATION_FAILED', 'SAL-002 changing an existing amount needs a reason');
select test.eq((public.set_employee_salary(test.emp('EMP01'), '{"monthly_salary": 50000}', 'Annual revision', 2)
                -> 'data' -> 'profile' ->> 'monthly_salary')::numeric, 50000::numeric, 'SAL-002 revision with reason');
select test.eq((public.set_employee_salary(test.emp('EMP01'), '{"monthly_salary": 50000}', null, 3)
                -> 'data' ->> 'unchanged')::boolean, true, 'SAL-002 re-import of identical values is a no-op');
select test.eq((public.get_employee_salary(test.emp('EMP01')) ->> 'version')::integer, 3, 'SAL-002 no-op keeps the version');
select test.throws(format($q$select public.set_employee_salary(%L, '{"monthly_salary": 99}', 'x', 0)$q$, test.emp('HR01')),
  'ACCESS_DENIED', 'SAL-002 payroll HR cannot change their own salary');
select test.eq((public.set_payslip_amount(test.emp('EMP01'), date '2026-09-15', 49500.5) -> 'data' ->> 'net_amount')::numeric,
  49500.50::numeric, 'SAL-003 paid amount stored on the payslip month');
select public.set_payslip_amount(test.emp('EMP01'), date '2026-08-01', 45000);
select test.throws(format('select public.set_payslip_amount(%L, %L, 1)', test.emp('EMP02'), date '2026-09-01'),
  'NOT_FOUND', 'SAL-003 no payslip for the month -> clear error');
select test.eq(jsonb_array_length(public.get_employee_salary(test.emp('EMP01')) -> 'data' -> 'revisions'), 2,
  'SAL-002 revision history kept');

-- SAL-004 the employee sees only their own figures, including the lifetime total.
select test.login('EMP01');
select test.eq((public.get_my_salary() -> 'data' ->> 'lifetime_paid')::numeric, 94500.50::numeric,
  'SAL-004 lifetime paid = sum of published payslip amounts');
select test.eq((public.get_my_salary() -> 'data' -> 'profile' ->> 'bank_status'), 'not_set',
  'SAL-004 bank remains unset until employee approval');
select test.login('EMP02');
select test.eq((public.get_my_salary() -> 'data' -> 'profile'), 'null'::jsonb, 'SAL-004 others see nothing of EMP01');
select test.eq((public.get_my_salary() -> 'data' ->> 'lifetime_paid')::numeric, 0::numeric, 'SAL-004 zero when nothing paid');

-- SAL-005 audit rows never carry amounts or bank details.
select test.as_admin_db();
select test.ok(pg_temp.audit_changes('salary.updated') not like '%45000%'
               and pg_temp.audit_changes('salary.updated') not like '%HDFC%'
               and pg_temp.audit_changes('payslip.amount_set') not like '%49500%', 'SAL-005 audit has no amounts');
select test.ok((select count(*) from hrms.audit_logs where action = 'salary.viewed_own') >= 2, 'SAL-005 reveals audited');

-- SAL-006 the employee is notified without amounts.
select test.ok((select bool_and(body not like '%5%') from hrms.notifications where kind = 'salary.updated'),
  'SAL-006 notification text has no amount');

-- SHEET-001 only Admin configures the sheet.
select test.login('HR01');
select test.throws('select public.get_sheet_sync()', 'ACCESS_DENIED', 'SHEET-001 HR cannot see sheet settings');
select test.login('ADMIN01');
select test.throws($q$select public.set_sheet_sync('not a link', true, false, 0)$q$, 'VALIDATION_FAILED',
  'SHEET-002 malformed sheet id rejected');
select test.eq((public.set_sheet_sync('https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit#gid=0',
                                      true, false, 0) -> 'data' ->> 'spreadsheet_id'),
  '1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789', 'SHEET-002 pasted link accepted');
-- SHEET-003 turning on the salary tab needs a fresh password confirmation.
select test.throws($q$select public.set_sheet_sync('1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789', true, true, 2)$q$,
  'REAUTH_REQUIRED', 'SHEET-003 salary tab needs reauthentication');
select pg_temp.reauth('ADMIN01', 'export.bulk_salary');
select test.eq((public.set_sheet_sync('1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789', true, true, 2)
                -> 'data' ->> 'include_salary')::boolean, true, 'SHEET-003 salary tab on after reauthentication');

-- Approved bank data is exported masked. The dedicated bank-request suite
-- tests the workflow; this is a focused export fixture.
select test.as_admin_db();
select set_config('hrms.bank_approval_apply', 'on', true);
update hrms.salary_profiles set bank_name = 'HDFC Bank', account_holder = 'Employee E1',
  account_last4 = '5678', ifsc = 'HDFC0001234', bank_status = 'approved'
where employee_id = test.emp('EMP01');
select set_config('hrms.bank_approval_apply', 'off', true);
select test.login('ADMIN01');

-- SHEET-004 export: service only; tabs present; salary masked; no formulas.
select test.throws(format('select public.internal_sheet_export(%L)', test.org('TEST_ORG')), 'permission denied',
  'SHEET-004 clients cannot call the export');
select test.as_service();
select test.ok(jsonb_array_length(public.internal_sheet_sync_due()) = 1, 'SHEET-004 enabled sheet is due');
create temporary table ex as select public.internal_sheet_export(test.org('TEST_ORG')) as x;
grant select on ex to authenticated, service_role;
select test.eq((select string_agg(t ->> 'name', ',') from ex, jsonb_array_elements(x -> 'tabs') t),
  'Overview,Employees,Attendance,Leave & Requests,Approvals,Leave Balances,Roles & Access,Teams,Salary',
  'SHEET-004 every tab built');
select test.eq((select jsonb_array_length(t -> 'rows') from ex, jsonb_array_elements(x -> 'tabs') t
                where t ->> 'name' = 'Employees'), 8, 'SHEET-004 employees of this org only');
select test.ok((select x::text not like '%000012345678%' and x::text like '%XXXX5678%' from ex),
  'SHEET-004 account number masked');
select public.internal_sheet_sync_result(test.org('TEST_ORG'), true, null, 42);
select test.ok(jsonb_array_length(public.internal_sheet_sync_due()) = 0, 'SHEET-004 not due right after a sync');

rollback;
