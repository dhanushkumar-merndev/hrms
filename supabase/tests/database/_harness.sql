-- Test harness for LOCAL disposable databases only (never hosted projects).
-- Provides assertions and synthetic fixtures. Tests run as the real API roles
-- (`authenticated`, `service_role`, `anon`) with Supabase-style JWT claims.
create schema if not exists test;
grant usage on schema test to authenticated, anon, service_role;

create or replace function test.ok(p_cond boolean, p_msg text) returns text
language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'not ok - %', p_msg;
  end if;
  return 'ok ' || p_msg;
end $$;

create or replace function test.eq(p_actual anyelement, p_expected anyelement, p_msg text) returns text
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'not ok - % (expected %, got %)', p_msg, p_expected, p_actual;
  end if;
  return 'ok ' || p_msg;
end $$;

-- Executes SQL and asserts it raises an error whose MESSAGE equals p_code
-- (HRMS error codes) or whose SQLSTATE equals p_code.
create or replace function test.throws(p_sql text, p_code text, p_msg text) returns text
language plpgsql as $$
declare
  v_msg text; v_state text; v_detail text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
    if v_msg = p_code or v_state = p_code or v_msg like p_code || '%' then
      return 'ok ' || p_msg;
    end if;
    raise exception 'not ok - % (expected %, got % / % %)', p_msg, p_code, v_state, v_msg, coalesce(v_detail, '');
  end;
  raise exception 'not ok - % (expected error %, none raised)', p_msg, p_code;
end $$;
grant execute on all functions in schema test to authenticated, anon, service_role;

-- Returns the jsonb error code from a rejected punch envelope.
create or replace function test.err(p jsonb) returns text language sql as $$ select p -> 'error' ->> 'code' $$;

-- ---------------------------------------------------------------------------
-- Fixtures (run as postgres)
-- ---------------------------------------------------------------------------
create table if not exists test.people (
  code text primary key, org_id uuid, employee_id uuid, auth_user_id uuid, session_id uuid, alias text
);
grant select on test.people to authenticated, anon, service_role;

create or replace function test.org(p_code text, p_tz text default 'Asia/Kolkata') returns uuid
language plpgsql security definer as $$
declare v uuid;
begin
  select id into v from hrms.organizations where code = p_code;
  if v is null then
    insert into hrms.organizations (code, name, timezone) values (p_code, p_code || ' Org', p_tz) returning id into v;
  end if;
  return v;
end $$;

-- Creates an active, provisioned employee with an Auth identity + live session.
create or replace function test.person(
  p_org_code text, p_code text, p_name text, p_roles text[] default '{}', p_join date default date '2025-01-01'
) returns uuid
language plpgsql security definer as $$
declare
  v_org uuid := test.org(p_org_code);
  v_uid uuid := gen_random_uuid();
  v_sid uuid := gen_random_uuid();
  v_alias text := 'e-' || replace(gen_random_uuid()::text, '-', '') || '@staff.hrms.invalid';
  v_emp uuid;
  r text;
begin
  insert into auth.users (id, email) values (v_uid, v_alias);
  insert into auth.sessions (id, user_id, created_at) values (v_sid, v_uid, now());
  insert into hrms.employees (org_id, employee_code, full_name, join_date, status, provisioning_state,
                              auth_user_id, auth_alias, must_change_password, credentials_valid_after)
  values (v_org, p_code, p_name, p_join, 'active', 'complete', v_uid, v_alias, false, now() - interval '1 day')
  returning id into v_emp;
  foreach r in array p_roles loop
    insert into hrms.role_grants (org_id, employee_id, role, effective_from)
    values (v_org, v_emp, r, now() - interval '1 day');
  end loop;
  insert into test.people values (p_code, v_org, v_emp, v_uid, v_sid, v_alias);
  return v_emp;
end $$;

create or replace function test.emp(p_code text) returns uuid language sql stable as
$$ select employee_id from test.people where code = p_code $$;

-- Switch to the API role of an employee (JWT claims like PostgREST sets them).
create or replace function test.login(p_code text) returns text
language plpgsql as $$
declare p test.people;
begin
  select * into p from test.people where code = p_code;
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', p.auth_user_id, 'role', 'authenticated', 'session_id', p.session_id, 'email', p.alias)::text, false);
  perform set_config('role', 'authenticated', false);
  return 'as ' || p_code;
end $$;

create or replace function test.as_anon() returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', false);
  perform set_config('role', 'anon', false);
  return 'as anon';
end $$;

create or replace function test.as_service() returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', false);
  perform set_config('role', 'service_role', false);
  return 'as service_role';
end $$;

create or replace function test.as_admin_db() returns text language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  return 'as postgres';
end $$;

-- Standard org structure: departments/teams/offices/shift used by suites.
create or replace function test.standard_org() returns void
language plpgsql security definer as $$
declare
  v_org uuid := test.org('TEST_ORG');
  v_other uuid := test.org('OTHER_ORG');
  v_dept uuid; v_t1 uuid; v_t2 uuid; v_tm uuid; v_o1 uuid; v_o2 uuid; v_o3 uuid; v_shift uuid; v_night uuid;
begin
  insert into hrms.departments (org_id, name) values (v_org, 'Operations') returning id into v_dept;
  insert into hrms.teams (org_id, department_id, name) values (v_org, v_dept, 'Team1') returning id into v_t1;
  insert into hrms.teams (org_id, department_id, name) values (v_org, v_dept, 'Team2') returning id into v_t2;
  insert into hrms.teams (org_id, department_id, name) values (v_org, v_dept, 'Management') returning id into v_tm;

  perform test.person('TEST_ORG', 'ADMIN01', 'Admin A', array['admin']);
  perform test.person('TEST_ORG', 'HR01', 'HR H', array['hr']);
  perform test.person('TEST_ORG', 'HR02', 'HR H2', array['hr']);
  perform test.person('TEST_ORG', 'MGR01', 'Manager M1', array['manager']);
  perform test.person('TEST_ORG', 'MGR02', 'Manager M2', array['manager']);
  perform test.person('TEST_ORG', 'EMP01', 'Employee E1');
  perform test.person('TEST_ORG', 'EMP02', 'Employee E2');
  perform test.person('TEST_ORG', 'EMP03', 'Employee E3');
  perform test.person('OTHER_ORG', 'EMP09', 'Other E9');
  insert into hrms.permission_grants (org_id, employee_id, permission, effective_from)
  values (v_org, test.emp('HR01'), 'payroll.manage', now() - interval '1 day');

  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from)
  select v_org, test.emp(c), v_t1, date '2025-01-01' from unnest(array['EMP01', 'EMP02']) c;
  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from)
  values (v_org, test.emp('EMP03'), v_t2, date '2025-01-01');
  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from)
  select v_org, test.emp(c), v_tm, date '2025-01-01' from unnest(array['ADMIN01', 'HR01', 'HR02', 'MGR01', 'MGR02']) c;
  insert into hrms.team_managers (org_id, team_id, manager_id, effective_from)
  values (v_org, v_t1, test.emp('MGR01'), date '2025-01-01'), (v_org, v_t2, test.emp('MGR02'), date '2025-01-01');

  insert into hrms.approval_routes (org_id, team_id, request_kind, reviewer_mode, fallback_reviewer_id)
  values (v_org, v_t1, 'leave', 'manager', test.emp('HR01')), (v_org, v_t1, 'correction', 'manager', test.emp('HR01')),
         (v_org, v_t2, 'leave', 'manager', test.emp('HR01')), (v_org, v_t2, 'correction', 'manager', test.emp('HR01'));
  insert into hrms.approval_routes (org_id, team_id, request_kind, reviewer_mode, hr_reviewer_id, fallback_reviewer_id)
  values (v_org, v_tm, 'leave', 'hr', test.emp('HR01'), test.emp('ADMIN01')),
         (v_org, v_tm, 'correction', 'hr', test.emp('HR01'), test.emp('ADMIN01'));

  -- O1 = synthetic test point (not a real office). O2 active unassigned, O3 inactive.
  insert into hrms.offices (org_id, name, timezone, location, radius_m, max_accuracy_m, max_sample_age_s)
  values (v_org, 'O1', 'Asia/Kolkata', extensions.st_setsrid(extensions.st_makepoint(77.5946, 12.9716), 4326)::extensions.geography, 20, 15, 10)
  returning id into v_o1;
  insert into hrms.offices (org_id, name, timezone, location)
  values (v_org, 'O2', 'Asia/Kolkata', extensions.st_setsrid(extensions.st_makepoint(77.60, 12.98), 4326)::extensions.geography)
  returning id into v_o2;
  insert into hrms.offices (org_id, name, timezone, location, active)
  values (v_org, 'O3', 'Asia/Kolkata', extensions.st_setsrid(extensions.st_makepoint(77.61, 12.99), 4326)::extensions.geography, false)
  returning id into v_o3;
  insert into hrms.office_assignments (org_id, employee_id, office_id, effective_from)
  select v_org, e.id, v_o1, date '2025-01-01' from hrms.employees e where e.org_id = v_org;

  insert into hrms.shifts (org_id, name) values (v_org, 'General') returning id into v_shift;
  insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local,
    weekly_mask, grace_seconds, lunch_start_local, lunch_end_local, lunch_paid, early_entry_seconds,
    checkout_extension_enabled, checkout_extension_seconds, state, published_at)
  values (v_org, v_shift, 1, date '2025-01-01', time '10:00', time '19:00', 31, 1800, time '13:00', time '14:00',
          true, 1800, true, 7200, 'published', now());
  insert into hrms.shifts (org_id, name) values (v_org, 'Night') returning id into v_night;
  insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local,
    weekly_mask, grace_seconds, lunch_paid, early_entry_seconds, checkout_extension_enabled,
    checkout_extension_seconds, state, published_at)
  values (v_org, v_night, 1, date '2025-01-01', time '22:00', time '07:00', 127, 1800, true, 1800, true, 7200,
          'published', now());
  insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from)
  select v_org, e.id, v_shift, date '2025-01-01' from hrms.employees e where e.org_id = v_org;

  insert into hrms.holidays (org_id, holiday_date, name, state, published_at)
  values (v_org, date '2026-10-02', 'Test Holiday', 'published', now());
end $$;

-- Paid leave fixture: 24 half-day units (12 days) for a leave year. Test
-- allowance only — not a production entitlement.
create or replace function test.grant_leave(p_code text, p_type uuid, p_year integer, p_units integer default 24)
returns uuid
language plpgsql security definer as $$
declare v_acc uuid; v_alloc uuid; v_org uuid; v_op uuid := gen_random_uuid();
begin
  select org_id into v_org from hrms.employees where id = test.emp(p_code);
  insert into hrms.leave_accounts (org_id, employee_id, leave_type_id, leave_year)
  values (v_org, test.emp(p_code), p_type, p_year)
  on conflict (employee_id, leave_type_id, leave_year) do update set leave_year = excluded.leave_year
  returning id into v_acc;
  insert into hrms.leave_allocations (org_id, account_id, source, valid_from, valid_to, operation_id)
  values (v_org, v_acc, 'annual', make_date(p_year, 1, 1), make_date(p_year + 1, 1, 1), v_op)
  returning id into v_alloc;
  insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id)
  values (v_org, v_acc, v_alloc, 'allocate', p_units, v_op);
  return v_alloc;
end $$;
grant execute on all functions in schema test to authenticated, anon, service_role;
