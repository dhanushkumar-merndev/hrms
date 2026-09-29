-- =============================================================================
-- Identity: login lookup + rate limits, provisioning saga, fail-closed
-- credential saga, reauthentication grants, session context (§3.1).
-- Passwords never reach the database: Auth hashes them; these functions only
-- coordinate state around the Auth calls made by Edge Functions.
-- =============================================================================

-- Login support for the auth-login Edge Function. Applies IP and account
-- rate limits with bounded temporary cooldowns (never a permanent lock) and
-- returns the internal alias only for an active, provisioned employee.
create or replace function public.internal_login_lookup(p_org_code text, p_employee_code text, p_ip_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := hrms.normalize_employee_code(p_employee_code);
  v_org hrms.organizations;
  v_emp hrms.employees;
  v_ip_hits integer;
  v_fail_count integer;
begin
  v_ip_hits := hrms.rate_limit_hit('login:ip:' || coalesce(p_ip_hash, 'none'), interval '15 minutes');
  if v_ip_hits > 30 then
    return jsonb_build_object('allowed', false, 'retry_after_seconds', 900);
  end if;
  if p_org_code is null or p_org_code = '' then
    select * into v_org from hrms.organizations order by created_at limit 1;
  else
    select * into v_org from hrms.organizations where code = upper(btrim(p_org_code));
  end if;
  if v_code is null or v_org.id is null then
    return jsonb_build_object('allowed', true, 'alias', null);
  end if;
  v_fail_count := hrms.rate_limit_count('login:fail:' || v_org.id::text || ':' || v_code, interval '15 minutes');
  if v_fail_count >= 5 then
    return jsonb_build_object('allowed', false, 'retry_after_seconds', 900);
  end if;
  select * into v_emp from hrms.employees where org_id = v_org.id and employee_code = v_code;
  if not found or v_emp.status <> 'active' or v_emp.provisioning_state <> 'complete' then
    return jsonb_build_object('allowed', true, 'alias', null, 'org_id', v_org.id);
  end if;
  return jsonb_build_object('allowed', true, 'alias', v_emp.auth_alias, 'org_id', v_org.id,
                            'employee_id', v_emp.id);
end;
$$;

-- Records the outcome of a login attempt. A success whose Auth identity does
-- not match the linked auth UUID is an alias anomaly: denied and flagged.
create or replace function public.internal_login_result(
  p_org_code text, p_employee_code text, p_ip_hash text, p_success boolean, p_auth_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := hrms.normalize_employee_code(p_employee_code);
  v_org hrms.organizations;
  v_emp hrms.employees;
begin
  if p_org_code is null or p_org_code = '' then
    select * into v_org from hrms.organizations order by created_at limit 1;
  else
    select * into v_org from hrms.organizations where code = upper(btrim(p_org_code));
  end if;
  if v_org.id is not null and v_code is not null then
    select * into v_emp from hrms.employees where org_id = v_org.id and employee_code = v_code;
  end if;
  if not p_success then
    if v_org.id is not null and v_code is not null then
      perform hrms.rate_limit_hit('login:fail:' || v_org.id::text || ':' || v_code, interval '15 minutes');
    end if;
    perform hrms.security_event(v_org.id, v_emp.id, 'auth.login_failed', null, p_ip_hash);
    return jsonb_build_object('ok', false);
  end if;
  if v_emp.id is null or v_emp.auth_user_id is distinct from p_auth_user_id then
    update hrms.employees set alias_anomaly_at = now() where id = v_emp.id;
    perform hrms.security_event(v_org.id, v_emp.id, 'auth.alias_anomaly', null, p_ip_hash);
    return jsonb_build_object('ok', false);
  end if;
  perform hrms.audit(v_org.id, v_emp.id, 'auth.login', 'employee', v_emp.id, null, 'security', v_emp.id);
  return jsonb_build_object('ok', true, 'employee_id', v_emp.id, 'must_change_password', v_emp.must_change_password,
                            'credential_hold', v_emp.credential_hold_operation_id is not null);
end;
$$;

-- Session context for app routing. Works in RESTRICTED mode so a user with a
-- temporary password (or a pending credential operation) can reach only the
-- password-change / status screens.
create or replace function public.get_session_context() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor('restricted');
  v_emp hrms.employees;
  v_org hrms.organizations;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  return hrms.ok(jsonb_build_object(
    'employee', jsonb_build_object('id', v_emp.id, 'code', v_emp.employee_code, 'name', v_emp.full_name,
                                   'designation', v_emp.designation),
    'org', jsonb_build_object('id', v_org.id, 'code', v_org.code, 'name', v_org.name, 'timezone', v_org.timezone,
                              'support_contact', v_org.support_contact),
    'roles', to_jsonb(v_actor.roles),
    'permissions', to_jsonb(v_actor.permissions),
    'must_change_password', v_emp.must_change_password,
    'credential_hold', v_emp.credential_hold_operation_id is not null,
    'permission_version', md5(array_to_string(v_actor.roles, ',') || '|' || array_to_string(v_actor.permissions, ','))
  ));
end;
$$;

-- -----------------------------------------------------------------------------
-- Provisioning saga: pending record -> Auth identity -> link -> complete.
-- -----------------------------------------------------------------------------

-- Allocates leave for a newly active employee from policies already
-- published for the current leave year (prorata when the policy enables it).
create or replace function hrms.allocate_published_leave(p_org uuid, p_employee uuid) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org hrms.organizations;
  v_emp hrms.employees;
  v_year integer;
  v_pol record;
  v_acc uuid;
  v_units integer;
  v_months integer;
  v_start date;
  v_op uuid;
  v_alloc uuid;
begin
  select * into v_org from hrms.organizations where id = p_org;
  select * into v_emp from hrms.employees where id = p_employee;
  v_year := hrms.leave_year_of(v_org.leave_year_start_month, hrms.org_today(p_org));
  v_start := make_date(v_year, v_org.leave_year_start_month, 1);
  for v_pol in
    select p.* from hrms.leave_policies p join hrms.leave_types t on t.id = p.leave_type_id
    where p.org_id = p_org and p.leave_year = v_year and p.state = 'published' and t.active and t.paid
  loop
    v_op := md5(v_pol.id::text || ':' || p_employee::text)::uuid;
    insert into hrms.leave_accounts (org_id, employee_id, leave_type_id, leave_year)
    values (p_org, p_employee, v_pol.leave_type_id, v_year)
    on conflict (employee_id, leave_type_id, leave_year) do nothing;
    select id into v_acc from hrms.leave_accounts
    where employee_id = p_employee and leave_type_id = v_pol.leave_type_id and leave_year = v_year;
    v_units := v_pol.annual_units;
    if v_pol.prorata and v_emp.join_date > v_start then
      -- Whole remaining months including the joining month, in half-day units (rounded down).
      v_months := 12 - ((extract(year from v_emp.join_date)::integer - v_year) * 12
                        + extract(month from v_emp.join_date)::integer - v_org.leave_year_start_month);
      v_units := greatest(0, least(12, v_months)) * v_pol.annual_units / 12;
    end if;
    insert into hrms.leave_allocations (org_id, account_id, source, valid_from, valid_to, policy_id, operation_id,
                                        reason)
    values (p_org, v_acc, case when v_units < v_pol.annual_units then 'prorata' else 'annual' end,
            v_start, (v_start + interval '1 year')::date, v_pol.id, v_op, 'Published policy allocation')
    on conflict (account_id, operation_id) do nothing
    returning id into v_alloc;
    if v_alloc is not null and v_units > 0 then
      insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id)
      values (p_org, v_acc, v_alloc, 'allocate', v_units, v_op)
      on conflict do nothing;
    end if;
  end loop;
end;
$$;

-- Step 1: authorise + validate + create the pending employee record and its
-- assignments. Idempotent per operation id (a retry returns the same record).
create or replace function public.internal_provision_begin(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_operation_id uuid, p_fields jsonb, p_alias_domain text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_org hrms.organizations;
  v_emp hrms.employees;
  v_code text := hrms.normalize_employee_code(p_fields ->> 'employee_code');
  v_role text := nullif(p_fields ->> 'role', '');
  v_join date;
  v_errors jsonb := '{}'::jsonb;
  v_active integer;
  v_team uuid := nullif(p_fields ->> 'team_id', '')::uuid;
  v_office uuid := nullif(p_fields ->> 'office_id', '')::uuid;
  v_shift uuid := nullif(p_fields ->> 'shift_id', '')::uuid;
  v_dept uuid := nullif(p_fields ->> 'department_id', '')::uuid;
  v_name text := hrms.clean_text(p_fields ->> 'full_name', 200);
begin
  if not (hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'hr.employees.provision')) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  -- HR may create Member/Manager only; Admin and HR roles need an Admin.
  if v_role is not null and v_role not in ('manager', 'hr', 'admin') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown role.', '{"role":"Choose Member, Manager, HR or Admin"}'::jsonb);
  end if;
  if v_role in ('hr', 'admin') and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED', 'Only an Admin can create HR or Admin accounts.');
  end if;

  select * into v_emp from hrms.employees where provisioning_operation_id = p_operation_id;
  if found then
    if v_emp.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
    return jsonb_build_object('employee_id', v_emp.id, 'auth_alias', v_emp.auth_alias,
      'provisioning_state', v_emp.provisioning_state, 'auth_user_id', v_emp.auth_user_id, 'resumed', true);
  end if;

  -- Serialise provisioning per org so the active-employee cap is exact.
  select * into v_org from hrms.organizations where id = v_actor.org_id for update;

  if v_code is null then v_errors := v_errors || '{"employee_code":"3–32 letters, digits or -"}'; end if;
  if v_name is null then v_errors := v_errors || '{"full_name":"Required"}'; end if;
  begin
    v_join := (p_fields ->> 'join_date')::date;
  exception when others then v_join := null;
  end;
  if v_join is null then v_errors := v_errors || '{"join_date":"Required"}'; end if;
  if v_team is null or not exists (select 1 from hrms.teams where id = v_team and org_id = v_org.id and active) then
    v_errors := v_errors || '{"team_id":"Choose a team"}';
  end if;
  if v_office is null or not exists (select 1 from hrms.offices where id = v_office and org_id = v_org.id) then
    v_errors := v_errors || '{"office_id":"Choose an office"}';
  end if;
  if v_shift is null or not exists (select 1 from hrms.shifts where id = v_shift and org_id = v_org.id and active) then
    v_errors := v_errors || '{"shift_id":"Choose a shift"}';
  end if;
  if v_dept is not null and not exists (select 1 from hrms.departments where id = v_dept and org_id = v_org.id) then
    v_errors := v_errors || '{"department_id":"Unknown department"}';
  end if;
  if v_code is not null and exists (select 1 from hrms.employees where org_id = v_org.id and employee_code = v_code) then
    v_errors := v_errors || '{"employee_code":"This employee ID already exists"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the highlighted fields.', v_errors);
  end if;

  select count(*) into v_active from hrms.employees
  where org_id = v_org.id and (status = 'active' or (status = 'pending' and provisioning_state <> 'complete'));
  if v_active >= v_org.active_employee_cap then
    perform hrms.raise_error('ACTIVE_EMPLOYEE_CAP_REACHED',
      format('The active employee limit (%s) is reached. An Admin can review the limit.', v_org.active_employee_cap));
  end if;

  insert into hrms.employees (org_id, employee_code, full_name, designation, department_id, business_email,
    business_phone, join_date, status, provisioning_state, provisioning_operation_id, auth_alias,
    must_change_password, created_by, updated_by)
  values (v_org.id, v_code, v_name, hrms.clean_text(p_fields ->> 'designation', 120), v_dept,
    hrms.clean_text(p_fields ->> 'business_email', 200), hrms.clean_text(p_fields ->> 'business_phone', 40),
    v_join, 'pending', 'pending', p_operation_id,
    'e-' || encode(extensions.gen_random_bytes(12), 'hex') || '@' || coalesce(nullif(p_alias_domain, ''), 'staff.hrms.invalid'),
    true, v_actor.employee_id, v_actor.employee_id)
  returning * into v_emp;

  insert into hrms.employee_private_details (employee_id, org_id) values (v_emp.id, v_org.id);
  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from, created_by, reason)
  values (v_org.id, v_emp.id, v_team, v_join, v_actor.employee_id, 'Provisioned');
  insert into hrms.office_assignments (org_id, employee_id, office_id, effective_from, created_by, reason)
  values (v_org.id, v_emp.id, v_office, v_join, v_actor.employee_id, 'Provisioned');
  insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from, created_by, reason)
  values (v_org.id, v_emp.id, v_shift, v_join, v_actor.employee_id, 'Provisioned');
  if v_role is not null then
    insert into hrms.role_grants (org_id, employee_id, role, granted_by, reason)
    values (v_org.id, v_emp.id, v_role, v_actor.employee_id, 'Provisioned');
  end if;
  insert into hrms.credential_operations (org_id, employee_id, operation_id, kind, issued_by)
  values (v_org.id, v_emp.id, p_operation_id, 'provision', v_actor.employee_id);

  perform hrms.audit(v_org.id, v_actor.employee_id, 'employee.provision_started', 'employee', v_emp.id,
    jsonb_build_object('employee_code', v_code, 'role', coalesce(v_role, 'member'), 'team_id', v_team),
    'security', v_emp.id);
  return jsonb_build_object('employee_id', v_emp.id, 'auth_alias', v_emp.auth_alias,
    'provisioning_state', v_emp.provisioning_state, 'auth_user_id', null, 'resumed', false);
end;
$$;

-- Step 2: link the created Auth identity (immutable) and activate with the
-- first-password gate. Exactly-once per operation.
create or replace function public.internal_provision_link(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_operation_id uuid, p_new_auth_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_emp hrms.employees;
  v_org hrms.organizations;
  v_active integer;
begin
  select * into v_emp from hrms.employees where provisioning_operation_id = p_operation_id for update;
  if not found or v_emp.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_emp.provisioning_state = 'complete' then
    if v_emp.auth_user_id <> p_new_auth_user_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
    return jsonb_build_object('employee_id', v_emp.id, 'employee_code', v_emp.employee_code, 'already', true);
  end if;
  if exists (select 1 from hrms.employees where auth_user_id = p_new_auth_user_id and id <> v_emp.id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Auth identity already linked to another employee.');
  end if;
  select * into v_org from hrms.organizations where id = v_emp.org_id for update;
  select count(*) into v_active from hrms.employees where org_id = v_org.id and status = 'active';
  if v_active >= v_org.active_employee_cap then
    perform hrms.raise_error('ACTIVE_EMPLOYEE_CAP_REACHED', 'The active employee limit is reached.');
  end if;
  update hrms.employees
     set auth_user_id = p_new_auth_user_id, provisioning_state = 'complete', status = 'active',
         must_change_password = true, credentials_valid_after = now(), version = version + 1,
         updated_by = v_actor.employee_id
   where id = v_emp.id
  returning * into v_emp;
  update hrms.credential_operations set stage = 'finalized', barrier_at = now()
  where operation_id = p_operation_id;
  perform hrms.allocate_published_leave(v_emp.org_id, v_emp.id);
  perform hrms.audit(v_emp.org_id, v_actor.employee_id, 'employee.provisioned', 'employee', v_emp.id,
    jsonb_build_object('employee_code', v_emp.employee_code), 'security', v_emp.id);
  return jsonb_build_object('employee_id', v_emp.id, 'employee_code', v_emp.employee_code, 'already', false);
end;
$$;

-- -----------------------------------------------------------------------------
-- Credential saga (self change / admin reset). Hold first, Auth second,
-- barrier + gate third, clear the hold LAST. Never a SQL transaction open
-- across the Auth HTTP call: each step is its own RPC.
-- -----------------------------------------------------------------------------

create or replace function public.internal_credential_begin(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_operation_id uuid, p_kind text, p_target_employee_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor;
  v_target hrms.employees;
  v_op hrms.credential_operations;
  v_target_roles text[];
begin
  if p_kind = 'self_change' then
    v_actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'restricted');
    select * into v_target from hrms.employees where id = v_actor.employee_id for update;
  elsif p_kind = 'admin_reset' then
    v_actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
    select * into v_target from hrms.employees where id = p_target_employee_id for update;
    if not found or v_target.org_id <> v_actor.org_id or v_target.id = v_actor.employee_id then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_target.provisioning_state <> 'complete' or v_target.auth_user_id is null then
      perform hrms.raise_error('VALIDATION_FAILED', 'This account has not finished setup.');
    end if;
    v_target_roles := hrms.employee_roles(v_target.id);
    if hrms.is_admin(v_actor) then
      if 'admin' = any(v_target_roles) then
        perform hrms.require_reauth(v_actor, 'credentials.reset_admin', v_target.id, true);
      end if;
    elsif hrms.has_perm(v_actor, 'hr.employees.provision') then
      if v_target_roles && array['hr', 'admin'] then
        perform hrms.raise_error('ACCESS_DENIED', 'Only an Admin can reset HR or Admin accounts.');
      end if;
    else
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
  else
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown operation');
  end if;

  select * into v_op from hrms.credential_operations where operation_id = p_operation_id;
  if found then
    if v_op.employee_id <> v_target.id or v_op.kind <> p_kind then perform hrms.raise_error('ACCESS_DENIED'); end if;
    return jsonb_build_object('operation_id', v_op.operation_id, 'stage', v_op.stage, 'resumed', true,
      'target_auth_user_id', v_target.auth_user_id, 'target_alias', v_target.auth_alias,
      'employee_code', v_target.employee_code);
  end if;
  if v_target.credential_hold_operation_id is not null and exists (
       select 1 from hrms.credential_operations
       where operation_id = v_target.credential_hold_operation_id and stage in ('started', 'auth_updated')
         and expires_at > now()) then
    perform hrms.raise_error('CREDENTIAL_OPERATION_PENDING',
      'Another password change is in progress for this account. Try again in a few minutes.', null, true);
  end if;

  insert into hrms.credential_operations (org_id, employee_id, operation_id, kind, issued_by)
  values (v_target.org_id, v_target.id, p_operation_id, p_kind, v_actor.employee_id)
  returning * into v_op;
  update hrms.employees set credential_hold_operation_id = p_operation_id where id = v_target.id;
  perform hrms.audit(v_target.org_id, v_actor.employee_id, 'credentials.' || p_kind || '_started', 'employee',
    v_target.id, null, 'security', v_target.id);
  return jsonb_build_object('operation_id', p_operation_id, 'stage', 'started', 'resumed', false,
    'target_auth_user_id', v_target.auth_user_id, 'target_alias', v_target.auth_alias,
    'employee_code', v_target.employee_code);
end;
$$;

-- Auth confirmed the new password: set the credentials barrier and gate,
-- then clear the hold last. Every session created before now is invalid.
create or replace function public.internal_credential_finalize(p_operation_id uuid, p_actor_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op hrms.credential_operations;
  v_emp hrms.employees;
begin
  select * into v_op from hrms.credential_operations where operation_id = p_operation_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_op.issued_by is distinct from p_actor_employee_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_op.stage = 'finalized' then
    return jsonb_build_object('stage', 'finalized', 'already', true);
  end if;
  update hrms.employees
     set credentials_valid_after = clock_timestamp(),
         must_change_password = (v_op.kind <> 'self_change'),
         version = version + 1
   where id = v_op.employee_id
  returning * into v_emp;
  update hrms.credential_operations set stage = 'finalized', barrier_at = v_emp.credentials_valid_after
  where id = v_op.id;
  -- Clear the hold LAST.
  update hrms.employees set credential_hold_operation_id = null
  where id = v_op.employee_id and credential_hold_operation_id = p_operation_id;
  perform hrms.audit(v_op.org_id, p_actor_employee_id, 'credentials.' || v_op.kind || '_completed', 'employee',
    v_op.employee_id, null, 'security', v_op.employee_id);
  if v_op.kind = 'admin_reset' then
    perform hrms.notify(v_op.org_id, v_op.employee_id, 'credentials.reset', 'Password reset',
      'Your password was reset by HR. Sign in with the temporary password you were given.', '/login', null,
      md5(v_op.operation_id::text || ':reset')::uuid);
  end if;
  return jsonb_build_object('stage', 'finalized', 'already', false, 'barrier_at', v_emp.credentials_valid_after);
end;
$$;

-- Auth update failed. When Auth definitely did NOT change the password the
-- hold is released; otherwise it stays (fail closed) until reconciliation
-- verifies the current credential through Auth.
create or replace function public.internal_credential_fail(
  p_operation_id uuid, p_actor_employee_id uuid, p_auth_unchanged boolean, p_error text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op hrms.credential_operations;
begin
  select * into v_op from hrms.credential_operations where operation_id = p_operation_id for update;
  if not found or v_op.issued_by is distinct from p_actor_employee_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_op.stage = 'finalized' then return jsonb_build_object('stage', 'finalized'); end if;
  update hrms.credential_operations set stage = case when p_auth_unchanged then 'failed' else 'auth_updated' end,
         last_error = left(p_error, 300)
  where id = v_op.id;
  if p_auth_unchanged and v_op.kind = 'self_change' then
    update hrms.employees set credential_hold_operation_id = null
    where id = v_op.employee_id and credential_hold_operation_id = p_operation_id;
  end if;
  perform hrms.security_event(v_op.org_id, v_op.employee_id, 'credentials.operation_failed',
    jsonb_build_object('kind', v_op.kind, 'auth_unchanged', p_auth_unchanged));
  return jsonb_build_object('stage', case when p_auth_unchanged then 'failed' else 'auth_updated' end,
    'hold', not (p_auth_unchanged and v_op.kind = 'self_change'));
end;
$$;

-- Credential status for the restricted recovery screen.
create or replace function public.get_credential_status() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor('restricted');
  v_emp hrms.employees;
  v_op hrms.credential_operations;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  select * into v_op from hrms.credential_operations where operation_id = v_emp.credential_hold_operation_id;
  return hrms.ok(jsonb_build_object('must_change_password', v_emp.must_change_password,
    'hold', v_emp.credential_hold_operation_id is not null,
    'operation_id', v_op.operation_id, 'kind', v_op.kind, 'stage', v_op.stage,
    'self_recoverable', v_op.kind = 'self_change'));
end;
$$;

-- Reauthentication grant, issued only after the Edge Function verified the
-- current password through Auth. Bound to actor + session + action + target.
create or replace function public.internal_issue_reauth_grant(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_action text, p_target uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_id uuid;
  v_exp timestamptz := clock_timestamp() + interval '5 minutes';
begin
  insert into hrms.reauthentication_grants (org_id, employee_id, session_id, action, target_id, issued_at, expires_at)
  values (v_actor.org_id, v_actor.employee_id, v_actor.session_id, p_action, p_target, clock_timestamp(), v_exp)
  returning id into v_id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'auth.reauthenticated', 'reauth_grant', v_id,
    jsonb_build_object('action', p_action, 'target', p_target), 'security');
  return jsonb_build_object('grant_id', v_id, 'expires_at', v_exp);
end;
$$;

-- Resolves the actor for Edge Functions from verified JWT claims (restricted
-- allowed where noted) and returns the minimal identity they need.
create or replace function public.internal_resolve_actor(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_mode text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email,
                                           case when p_mode = 'restricted' then 'restricted' else 'business' end);
  v_emp hrms.employees;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  return jsonb_build_object('employee_id', v_actor.employee_id, 'org_id', v_actor.org_id,
    'employee_code', v_emp.employee_code, 'auth_alias', v_emp.auth_alias, 'roles', to_jsonb(v_actor.roles),
    'permissions', to_jsonb(v_actor.permissions), 'must_change_password', v_emp.must_change_password);
end;
$$;

-- Generic bounded rate limit for Edge Functions (returns true if allowed).
create or replace function public.internal_rate_limit(p_bucket text, p_window_seconds integer, p_max integer)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select hrms.rate_limit_hit(left(p_bucket, 120), make_interval(secs => greatest(1, least(p_window_seconds, 86400))))
         <= greatest(1, p_max);
$$;

select hrms.apply_api_grants();
