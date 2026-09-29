-- AUTH-001/004/005/007/008/013/014, SEC-003, ROLE-002/005, EMP-002/005,
-- directory privacy and login rate limits.
begin;
select test.standard_org();

-- Fresh session helper: simulates a NEW login (new auth.sessions row).
create or replace function pg_temp.new_session(p_code text) returns uuid language plpgsql security definer as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.sessions (id, user_id, created_at) values (v, (select auth_user_id from test.people where code = p_code), clock_timestamp());
  update test.people set session_id = v where code = p_code;
  return v;
end $$;

create or replace function pg_temp.team_id(p_name text) returns uuid language sql security definer as
$$ select id from hrms.teams where name = p_name $$;

-- ================================================================ gates
select test.as_admin_db();
update hrms.employees set must_change_password = true where id = test.emp('EMP01');
select test.login('EMP01');
select test.throws($$select public.get_home_summary()$$, 'PASSWORD_CHANGE_REQUIRED',
  'AUTH-001 temporary-password session cannot use business data');
select test.eq((public.get_session_context() -> 'data' ->> 'must_change_password')::boolean, true,
  'AUTH-001 restricted session context still available');
select test.as_admin_db();
update hrms.employees set must_change_password = false where id = test.emp('EMP01');

-- AUTH-007 / SEC-003: credential barrier kills the ORIGINAL session even if
-- its JWT is refreshed (same session id, new iat).
update hrms.employees set credentials_valid_after = clock_timestamp() where id = test.emp('EMP02');
select test.login('EMP02');
select test.throws($$select public.get_home_summary()$$, 'AUTH_REQUIRED', 'AUTH-007 pre-reset session rejected');
select set_config('request.jwt.claims', (current_setting('request.jwt.claims')::jsonb
  || jsonb_build_object('iat', extract(epoch from now())::bigint + 60))::text, false);
select test.throws($$select public.get_home_summary()$$, 'AUTH_REQUIRED', 'AUTH-007 refreshed JWT of old session still rejected');
select test.as_admin_db();
select pg_temp.new_session('EMP02');
select test.login('EMP02');
select test.ok((public.get_home_summary() -> 'data') ? 'me', 'AUTH-007 fresh login after reset works');

-- Revoked (deleted) Auth session is rejected.
select test.as_admin_db();
delete from auth.sessions where id = (select session_id from test.people where code = 'EMP03');
select test.login('EMP03');
select test.throws($$select public.get_home_summary()$$, 'AUTH_REQUIRED', 'revoked Auth session rejected');
select test.as_admin_db();
select pg_temp.new_session('EMP03');

-- AUTH-015: an Auth alias change cannot relink or grant access.
select test.login('EMP03');
select set_config('request.jwt.claims', (current_setting('request.jwt.claims')::jsonb
  || '{"email":"attacker@example.com"}'::jsonb)::text, false);
select test.throws($$select public.get_home_summary()$$, 'AUTH_REQUIRED', 'AUTH-015 changed alias denied');

-- AUTH-009: anon-role claims and forged roles.
select test.as_admin_db();
select set_config('request.jwt.claims', jsonb_build_object('sub', (select auth_user_id from test.people where code = 'EMP03'),
  'role', 'service_role', 'session_id', (select session_id from test.people where code = 'EMP03'))::text, false);
select set_config('role', 'authenticated', false);
select test.throws($$select public.get_home_summary()$$, 'AUTH_REQUIRED', 'AUTH-009 forged role claim not trusted');

-- Inactive account.
select test.as_admin_db();
update hrms.employees set status = 'inactive', end_date = current_date where id = test.emp('EMP03');
select test.login('EMP03');
select test.throws($$select public.get_home_summary()$$, 'ACCOUNT_INACTIVE', 'inactive employee denied');
select test.as_admin_db();
update hrms.employees set status = 'active', end_date = null where id = test.emp('EMP03');

-- AUTH-014: credential hold blocks business calls; restricted status works.
insert into hrms.credential_operations (org_id, employee_id, operation_id, kind, issued_by)
values (test.org('TEST_ORG'), test.emp('MGR02'), '22222222-2222-2222-2222-222222222222', 'admin_reset', test.emp('ADMIN01'));
update hrms.employees set credential_hold_operation_id = '22222222-2222-2222-2222-222222222222' where id = test.emp('MGR02');
select test.login('MGR02');
select test.throws($$select public.get_home_summary()$$, 'CREDENTIAL_OPERATION_PENDING', 'AUTH-014 hold blocks business access');
select test.eq((public.get_credential_status() -> 'data' ->> 'hold')::boolean, true, 'AUTH-014 restricted recovery status visible');
-- Finalising (after Auth success) sets the barrier and clears the hold last.
select test.as_admin_db();
select public.internal_credential_finalize('22222222-2222-2222-2222-222222222222', test.emp('ADMIN01'));
select test.eq((select credential_hold_operation_id is null from hrms.employees where id = test.emp('MGR02')), true,
  'AUTH-014 hold cleared after finalisation');
select test.eq((select must_change_password from hrms.employees where id = test.emp('MGR02')), true,
  'admin reset leaves must_change_password = true');
select test.login('MGR02');
select test.throws($$select public.get_session_context()$$, 'AUTH_REQUIRED', 'AUTH-014 pre-reset session invalid after finalise');

-- Self-change saga end to end.
select test.as_admin_db();
select pg_temp.new_session('MGR02');
select test.eq((select (public.internal_credential_begin((select auth_user_id from test.people where code = 'MGR02'),
  (select session_id from test.people where code = 'MGR02'), (select alias from test.people where code = 'MGR02'),
  '33333333-3333-3333-3333-333333333333', 'self_change', null) ->> 'stage')), 'started',
  'self change begins from restricted session');
select public.internal_credential_finalize('33333333-3333-3333-3333-333333333333', test.emp('MGR02'));
select test.eq((select must_change_password from hrms.employees where id = test.emp('MGR02')), false,
  'AUTH-002 successful self change clears the first-change gate');
select test.as_admin_db();
select pg_temp.new_session('MGR02');
select test.login('MGR02');
select test.ok((public.get_home_summary() -> 'data') ? 'me', 'AUTH-002 fresh login after self change works');

-- A failed Auth update with unchanged password releases a self-change hold;
-- an uncertain failure keeps it (fail closed).
select test.as_admin_db();
select public.internal_credential_begin((select auth_user_id from test.people where code = 'EMP01'),
  (select session_id from test.people where code = 'EMP01'), (select alias from test.people where code = 'EMP01'),
  '44444444-4444-4444-4444-444444444444', 'self_change', null);
select public.internal_credential_fail('44444444-4444-4444-4444-444444444444', test.emp('EMP01'), false, 'timeout');
select test.eq((select credential_hold_operation_id from hrms.employees where id = test.emp('EMP01')),
  '44444444-4444-4444-4444-444444444444'::uuid, 'AUTH-003 uncertain Auth failure keeps the hold');
-- Reconciliation (Auth confirmed the new password) finalises; fresh login.
select public.internal_credential_finalize('44444444-4444-4444-4444-444444444444', test.emp('EMP01'));
select test.eq((select credential_hold_operation_id is null from hrms.employees where id = test.emp('EMP01')), true,
  'AUTH-003 reconciliation clears the hold last');
select pg_temp.new_session('EMP01');

-- ================================================================ provisioning scope
select test.as_admin_db();
create or replace function pg_temp.fields(p_code text, p_role text default null) returns jsonb language sql security definer as $$
  select jsonb_build_object('employee_code', p_code, 'full_name', 'New ' || p_code, 'join_date', current_date,
    'team_id', (select id from hrms.teams where name = 'Team1'), 'office_id', (select id from hrms.offices where name = 'O1'),
    'shift_id', (select id from hrms.shifts where name = 'General'), 'role', p_role);
$$;
select test.as_admin_db();
create temporary table hr_ids as select auth_user_id, session_id, alias from test.people where code = 'HR01';
select test.ok((public.internal_provision_begin((select auth_user_id from hr_ids), (select session_id from hr_ids),
  (select alias from hr_ids), gen_random_uuid(), pg_temp.fields(' emp100 '), 'staff.hrms.invalid') ->> 'employee_id') is not null,
  'AUTH-004 HR provisions a Member (code normalised)');
select test.eq((select employee_code from hrms.employees where full_name = 'New  emp100 ' or employee_code = 'EMP100'), 'EMP100',
  'AUTH-005 code trimmed + uppercased');
select test.throws(format($f$select public.internal_provision_begin(%L, %L, %L, gen_random_uuid(), pg_temp.fields('Emp100'), 'x')$f$,
  (select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids)),
  'VALIDATION_FAILED', 'AUTH-005 duplicate code in a different case rejected');
select test.throws(format($f$select public.internal_provision_begin(%L, %L, %L, gen_random_uuid(), pg_temp.fields('EMP101', 'admin'), 'x')$f$,
  (select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids)),
  'ACCESS_DENIED', 'AUTH-004 HR cannot create an Admin');
select test.eq((select count(*)::integer from hrms.employees where employee_code = 'EMP101'), 0,
  'AUTH-004 no partial record after denied elevation');
select test.throws(format($f$select public.internal_credential_begin(%L, %L, %L, gen_random_uuid(), 'admin_reset', %L)$f$,
  (select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids), test.emp('ADMIN01')),
  'ACCESS_DENIED', 'AUTH-008 HR cannot reset an Admin');

-- Provision link: identity linked once; replay is idempotent.
create temporary table prov as select id, provisioning_operation_id as op from hrms.employees where employee_code = 'EMP100';
insert into auth.users (id, email) select gen_random_uuid(), (select auth_alias from hrms.employees where employee_code = 'EMP100');
create temporary table prov_user as select id from auth.users where email = (select auth_alias from hrms.employees where employee_code = 'EMP100');
select public.internal_provision_link((select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids),
  (select op from prov), (select id from prov_user));
select test.eq((select status from hrms.employees where employee_code = 'EMP100'), 'active', 'AUTH-012 linked employee activated');
select test.eq((select must_change_password from hrms.employees where employee_code = 'EMP100'), true,
  'provisioned account must change password first');
select test.eq((public.internal_provision_link((select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids),
  (select op from prov), (select id from prov_user)) ->> 'already')::boolean, true, 'AUTH-012 link retry is idempotent');
select test.eq((select count(*)::integer from hrms.audit_logs where action = 'employee.provisioned'
                and target_id = (select id from prov)), 1, 'AUTH-012 audit exactly once');
select test.throws($$update hrms.employees set auth_user_id = gen_random_uuid() where employee_code = 'EMP100'$$, '42501',
  'auth_user_id is immutable once linked');

-- EMP-005: active cap enforced transactionally.
update hrms.organizations set active_employee_cap = (select count(*) from hrms.employees where org_id = test.org('TEST_ORG')
  and status = 'active') where code = 'TEST_ORG';
select test.throws(format($f$select public.internal_provision_begin(%L, %L, %L, gen_random_uuid(), pg_temp.fields('EMP102'), 'x')$f$,
  (select auth_user_id from hr_ids), (select session_id from hr_ids), (select alias from hr_ids)),
  'ACTIVE_EMPLOYEE_CAP_REACHED', 'EMP-005 cap blocks the next active employee');
update hrms.organizations set active_employee_cap = 20 where code = 'TEST_ORG';

-- ================================================================ last Admin + reauth
select test.login('ADMIN01');
select test.throws(format($f$select public.revoke_role(%L, 'admin', 'test')$f$, test.emp('ADMIN01')), 'VALIDATION_FAILED',
  'AUTH-008 last active Admin cannot be removed');
select test.throws(format($f$select public.grant_role(%L, 'hr', 'promote')$f$, test.emp('EMP01')), 'REAUTH_REQUIRED',
  'AUTH-013 role elevation requires recent reauthentication');
select test.as_admin_db();
-- Expired and wrong-session grants do not work.
insert into hrms.reauthentication_grants (org_id, employee_id, session_id, action, issued_at, expires_at)
values (test.org('TEST_ORG'), test.emp('ADMIN01'), (select session_id from test.people where code = 'ADMIN01'), 'role.elevate',
        now() - interval '10 minutes', now() - interval '6 minutes'),
       (test.org('TEST_ORG'), test.emp('ADMIN01'), gen_random_uuid(), 'role.elevate', now(), now() + interval '4 minutes'),
       (test.org('TEST_ORG'), test.emp('ADMIN01'), (select session_id from test.people where code = 'ADMIN01'), 'archive.cleanup',
        now(), now() + interval '4 minutes');
select test.login('ADMIN01');
select test.throws(format($f$select public.grant_role(%L, 'hr', 'promote')$f$, test.emp('EMP01')), 'REAUTH_REQUIRED',
  'AUTH-013 expired / other-session / other-action grants rejected');
select test.as_admin_db();
select public.internal_issue_reauth_grant((select auth_user_id from test.people where code = 'ADMIN01'),
  (select session_id from test.people where code = 'ADMIN01'), (select alias from test.people where code = 'ADMIN01'), 'role.elevate', null);
select test.login('ADMIN01');
select test.ok((public.grant_role(test.emp('EMP01'), 'hr', 'promote') -> 'data') is not null, 'AUTH-013 server grant allows elevation');
select test.throws(format($f$select public.grant_role(%L, 'admin', 'again')$f$, test.emp('EMP02')), 'REAUTH_REQUIRED',
  'AUTH-013 grant is single use');
select test.as_admin_db();
select test.eq(('hr' = any(hrms.employee_roles(test.emp('EMP01')))), true, 'role granted');

-- ================================================================ scope
select test.login('MGR01');
select test.throws(format($f$select public.get_attendance_day(%L, current_date)$f$, test.emp('EMP03')), 'ACCESS_DENIED',
  'ROLE-002 manager cannot read another team''s attendance');
select test.throws(format($f$select public.get_attendance_day(%L, current_date)$f$, test.emp('EMP09')), 'ACCESS_DENIED',
  'AUTH-009 cross-org read denied');
select test.ok((public.get_attendance_day(test.emp('EMP02'), current_date) -> 'data') is not null,
  'manager reads own team member''s day');
select test.throws($$select public.list_employees()$$, 'ACCESS_DENIED', 'manager has no HR employee list');
select test.throws($$select public.list_payslip_uploads()$$, 'ACCESS_DENIED', 'FILE-002 manager has no payroll access');
select test.login('HR02');
select test.throws($$select public.list_payslip_uploads()$$, 'ACCESS_DENIED', 'FILE-002 HR without payroll grant denied');
select test.login('HR01');
select test.ok((public.list_payslip_uploads() -> 'data') ? 'rows', 'HR with payroll grant can list uploads');

-- Directory never carries private fields.
select test.as_admin_db();
update hrms.employee_private_details set personal_phone = '9999999999' where employee_id = test.emp('EMP02');
insert into hrms.employee_private_details (employee_id, org_id, personal_phone) values (test.emp('EMP03'), test.org('TEST_ORG'), '8888')
on conflict (employee_id) do update set personal_phone = excluded.personal_phone;
select test.login('EMP01');
select test.ok(position('personal_phone' in public.list_directory()::text) = 0 and position('8888' in public.list_directory()::text) = 0,
  'directory projection excludes private details');
select test.throws($$select public.update_my_profile('{"designation":"CEO"}'::jsonb, 1)$$, 'ACCESS_DENIED',
  'FILE-014 own profile cannot change HR-managed fields');

-- ROLE-005: manager scope follows work-date membership AND current authority.
select test.as_admin_db();
update hrms.team_memberships set effective_to = current_date - 3 where employee_id = test.emp('EMP02');
insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from)
values (test.org('TEST_ORG'), test.emp('EMP02'), (select id from hrms.teams where name = 'Team2'), current_date - 3);
select test.login('MGR02');
select set_config('role', 'postgres', false);  -- keep MGR02's JWT claims, call internals as owner
select test.ok(not exists (select 1 from hrms.report_scope((select hrms.current_actor()), current_date - 10, current_date) s
                           where s.employee_id = test.emp('EMP02') and s.window_from < current_date - 3),
  'ROLE-005 new manager does not see pre-transfer days');
select test.ok(exists (select 1 from hrms.report_scope((select hrms.current_actor()), current_date - 10, current_date) s
                       where s.employee_id = test.emp('EMP02') and s.window_from = current_date - 3),
  'ROLE-005 new manager sees post-transfer days');
select test.login('MGR01');
select set_config('role', 'postgres', false);
select test.ok(exists (select 1 from hrms.report_scope((select hrms.current_actor()), current_date - 10, current_date) s
                       where s.employee_id = test.emp('EMP02') and s.window_to = current_date - 4),
  'ROLE-005 old manager keeps only pre-transfer days');

-- EMP-002: reporting cycle rejected.
select test.login('ADMIN01');
select test.throws(format($f$select public.set_team_manager(%L, %L, current_date, 'cycle')$f$,
  pg_temp.team_id('Team1'), test.emp('EMP01')), 'VALIDATION_FAILED',
  'EMP-002 a team member cannot manage their own team');

-- ================================================================ login lookup rate limits
select test.as_admin_db();
select test.ok((public.internal_login_lookup('TEST_ORG', 'nosuch', 'ip1') ->> 'alias') is null, 'AUTH-006 unknown ID gets no alias');
select test.ok((public.internal_login_lookup('TEST_ORG', ' emp01 ', 'ip1') ->> 'alias') is not null, 'login code normalised');
select public.internal_login_result('TEST_ORG', 'EMP01', 'ip2', false, null) from generate_series(1, 5);
select test.eq((public.internal_login_lookup('TEST_ORG', 'EMP01', 'ip3') ->> 'allowed')::boolean, false,
  'AUTH-006 account cooldown after 5 failures (bounded, not permanent)');
select public.internal_login_lookup('TEST_ORG', 'x' || g, 'ip9') from generate_series(1, 30) g;
select test.eq((public.internal_login_lookup('TEST_ORG', 'EMP03', 'ip9') ->> 'allowed')::boolean, false,
  'AUTH-006 per-IP rate limit');
select test.eq((public.internal_login_result('TEST_ORG', 'EMP03', 'ip4', true, gen_random_uuid()) ->> 'ok')::boolean, false,
  'AUTH-015 login success for a different Auth identity is an anomaly');
rollback;
