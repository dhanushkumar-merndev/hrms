-- =============================================================================
-- People (S16, S17, S25–S27), reports (S24), notifications (S19, S38),
-- audit (S36) and the role workspace (S21).
-- =============================================================================

create or replace function hrms.can_view_hr(p_actor hrms.actor) returns boolean
language sql immutable set search_path = ''
as $$ select hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'hr.employees.view'); $$;

-- LIKE-safe search term.
create or replace function hrms.like_escape(p text) returns text
language sql immutable set search_path = ''
as $$ select replace(replace(replace(coalesce(p, ''), '\', '\\'), '%', '\%'), '_', '\_'); $$;

create or replace function hrms.employee_card(e hrms.employees, p_day date) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'id', e.id, 'code', e.employee_code, 'name', e.full_name, 'designation', e.designation,
    'department', (select jsonb_build_object('id', d.id, 'name', d.name) from hrms.departments d where d.id = e.department_id),
    'team', (select jsonb_build_object('id', t.id, 'name', t.name) from hrms.team_memberships m
             join hrms.teams t on t.id = m.team_id
             where m.employee_id = e.id and daterange(m.effective_from, m.effective_to, '[)') @> p_day limit 1),
    'avatar_file_version_id', e.avatar_file_version_id,
    'business_email', e.business_email, 'business_phone', e.business_phone);
$$;

-- -----------------------------------------------------------------------------
-- HR / Admin employee management
-- -----------------------------------------------------------------------------

create or replace function public.list_employees(
  p_search text default null, p_status text default 'active', p_team_id uuid default null,
  p_department_id uuid default null, p_limit integer default 25, p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 10000);
  v_term text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
  v_total integer;
  v_org hrms.organizations;
begin
  if not hrms.can_view_hr(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  with filtered as (
    select e.* from hrms.employees e
    where e.org_id = v_actor.org_id
      and (p_status is null or p_status = 'all' or e.status = p_status)
      and (p_department_id is null or e.department_id = p_department_id)
      and (p_team_id is null or hrms.team_on(e.id, v_today) = p_team_id)
      and (v_term is null
           or e.employee_code like upper(hrms.like_escape(v_term)) || '%'
           or lower(e.full_name) like lower(hrms.like_escape(v_term)) || '%'
           or lower(e.full_name) like '% ' || lower(hrms.like_escape(v_term)) || '%')
  )
  select (select count(*) from filtered),
         (select coalesce(jsonb_agg(hrms.employee_card(f, v_today) || jsonb_build_object(
                    'status', f.status, 'join_date', f.join_date, 'end_date', f.end_date,
                    'roles', to_jsonb(hrms.employee_roles(f.id)),
                    'setup_pending', f.must_change_password or f.provisioning_state <> 'complete',
                    'version', f.version) order by f.full_name, f.id), '[]'::jsonb)
          from (select * from filtered order by full_name, id limit v_limit offset v_offset) f)
    into v_total, v_rows;
  return hrms.ok(jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset,
    'active_count', (select count(*) from hrms.employees where org_id = v_org.id and status = 'active'),
    'active_cap', v_org.active_employee_cap));
end;
$$;

create or replace function public.get_employee(p_employee_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_today date := hrms.org_today(v_actor.org_id);
  v_private hrms.employee_private_details;
begin
  if not hrms.can_view_hr(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_emp from hrms.employees where id = p_employee_id and org_id = v_actor.org_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_private from hrms.employee_private_details where employee_id = v_emp.id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.viewed', 'employee', v_emp.id, null, 'access', v_emp.id);
  return hrms.ok(hrms.employee_card(v_emp, v_today) || jsonb_build_object(
    'status', v_emp.status, 'provisioning_state', v_emp.provisioning_state, 'join_date', v_emp.join_date,
    'end_date', v_emp.end_date, 'must_change_password', v_emp.must_change_password,
    'credential_hold', v_emp.credential_hold_operation_id is not null, 'alias_anomaly_at', v_emp.alias_anomaly_at,
    'roles', to_jsonb(hrms.employee_roles(v_emp.id)),
    'permissions', (select coalesce(jsonb_agg(g.permission), '[]'::jsonb) from hrms.permission_grants g
                    where g.employee_id = v_emp.id and g.revoked_at is null),
    'private', jsonb_build_object('personal_email', v_private.personal_email, 'personal_phone', v_private.personal_phone,
      'address', v_private.address, 'emergency_contact_name', v_private.emergency_contact_name,
      'emergency_contact_phone', v_private.emergency_contact_phone, 'date_of_birth', v_private.date_of_birth,
      'version', v_private.version),
    'teams', (select coalesce(jsonb_agg(jsonb_build_object('team', t.name, 'team_id', t.id, 'from', m.effective_from,
                'to', m.effective_to, 'reason', m.reason) order by m.effective_from desc), '[]'::jsonb)
              from hrms.team_memberships m join hrms.teams t on t.id = m.team_id where m.employee_id = v_emp.id),
    'offices', (select coalesce(jsonb_agg(jsonb_build_object('office', o.name, 'office_id', o.id, 'from', a.effective_from,
                  'to', a.effective_to) order by a.effective_from desc), '[]'::jsonb)
                from hrms.office_assignments a join hrms.offices o on o.id = a.office_id where a.employee_id = v_emp.id),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object('shift', s.name, 'shift_id', s.id, 'from', a.effective_from,
                 'to', a.effective_to) order by a.effective_from desc), '[]'::jsonb)
               from hrms.shift_assignments a join hrms.shifts s on s.id = a.shift_id where a.employee_id = v_emp.id),
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'platform', d.platform, 'label', d.device_label,
                  'attestation_level', d.attestation_level, 'registered_at', d.registered_at,
                  'last_used_at', d.last_used_at, 'revoked_at', d.revoked_at, 'revoke_reason', d.revoke_reason)
                  order by d.registered_at desc), '[]'::jsonb)
                from hrms.devices d where d.employee_id = v_emp.id),
    'can_manage_payroll', hrms.can_manage_payroll(v_actor),
    'can_edit', hrms.can_master_data(v_actor),
    'version', v_emp.version), v_emp.version);
end;
$$;

create or replace function public.update_employee(p_employee_id uuid, p_patch jsonb, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_before jsonb;
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_emp from hrms.employees where id = p_employee_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_emp.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This profile changed. Reload and try again.', null, true);
  end if;
  if p_patch ? 'department_id' and nullif(p_patch ->> 'department_id', '') is not null and not exists (
       select 1 from hrms.departments where id = (p_patch ->> 'department_id')::uuid and org_id = v_actor.org_id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown department.', '{"department_id":"Unknown"}'::jsonb);
  end if;
  if p_patch ? 'full_name' and hrms.clean_text(p_patch ->> 'full_name', 200) is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Name is required.', '{"full_name":"Required"}'::jsonb);
  end if;
  v_before := jsonb_build_object('full_name', v_emp.full_name, 'designation', v_emp.designation,
    'department_id', v_emp.department_id, 'business_email', v_emp.business_email,
    'business_phone', v_emp.business_phone, 'join_date', v_emp.join_date);
  update hrms.employees set
    full_name = coalesce(hrms.clean_text(p_patch ->> 'full_name', 200), full_name),
    designation = case when p_patch ? 'designation' then hrms.clean_text(p_patch ->> 'designation', 120) else designation end,
    department_id = case when p_patch ? 'department_id' then nullif(p_patch ->> 'department_id', '')::uuid else department_id end,
    business_email = case when p_patch ? 'business_email' then hrms.clean_text(p_patch ->> 'business_email', 200) else business_email end,
    business_phone = case when p_patch ? 'business_phone' then hrms.clean_text(p_patch ->> 'business_phone', 40) else business_phone end,
    join_date = coalesce((p_patch ->> 'join_date')::date, join_date),
    version = version + 1, updated_by = v_actor.employee_id
  where id = v_emp.id
  returning * into v_emp;
  if v_emp.end_date is not null and v_emp.end_date < v_emp.join_date then
    perform hrms.raise_error('VALIDATION_FAILED', 'Join date must be before the end date.', '{"join_date":"After end date"}'::jsonb);
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.updated', 'employee', v_emp.id,
    jsonb_build_object('before', v_before, 'patch', p_patch), 'business', v_emp.id);
  return public.get_employee(v_emp.id);
end;
$$;

-- Activate / deactivate. Deactivation keeps every record, cuts business
-- access immediately (credential barrier) and protects the last Admin.
create or replace function public.set_employee_status(
  p_employee_id uuid, p_status text, p_end_date date, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_org hrms.organizations;
  v_reason text := hrms.clean_text(p_reason, 500);
  v_admins integer;
  v_active integer;
  v_pending jsonb;
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_status not in ('active', 'inactive') or v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a status and give a reason.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_org from hrms.organizations where id = v_actor.org_id for update;
  select * into v_emp from hrms.employees where id = p_employee_id and org_id = v_org.id for update;
  if not found or v_emp.id = v_actor.employee_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_emp.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This profile changed. Reload and try again.', null, true);
  end if;
  if (hrms.employee_roles(v_emp.id) && array['hr', 'admin']) and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED', 'Only an Admin can change HR or Admin accounts.');
  end if;
  if p_status = 'inactive' then
    if 'admin' = any(hrms.employee_roles(v_emp.id)) then
      select count(distinct g.employee_id) into v_admins
      from hrms.role_grants g join hrms.employees e on e.id = g.employee_id
      where e.org_id = v_org.id and e.status = 'active' and g.role = 'admin' and g.revoked_at is null;
      if v_admins <= 1 then
        perform hrms.raise_error('VALIDATION_FAILED', 'At least one active Admin must remain.');
      end if;
    end if;
    update hrms.employees set status = 'inactive', end_date = coalesce(p_end_date, hrms.org_today(v_org.id)),
           credentials_valid_after = clock_timestamp(), version = version + 1, updated_by = v_actor.employee_id
    where id = v_emp.id returning * into v_emp;
    update hrms.push_tokens set revoked_at = now() where employee_id = v_emp.id and revoked_at is null;
    select coalesce(jsonb_agg(hrms.request_summary(r)), '[]'::jsonb) into v_pending
    from hrms.requests r where r.assigned_reviewer_id = v_emp.id
      and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending');
  else
    select count(*) into v_active from hrms.employees where org_id = v_org.id and status = 'active';
    if v_active >= v_org.active_employee_cap then
      perform hrms.raise_error('ACTIVE_EMPLOYEE_CAP_REACHED', 'The active employee limit is reached.');
    end if;
    if v_emp.provisioning_state <> 'complete' then
      perform hrms.raise_error('VALIDATION_FAILED', 'Finish account setup first.');
    end if;
    update hrms.employees set status = 'active', end_date = null, version = version + 1,
           updated_by = v_actor.employee_id
    where id = v_emp.id returning * into v_emp;
  end if;
  perform hrms.audit(v_org.id, v_actor.employee_id, 'employee.status_' || p_status, 'employee', v_emp.id,
    jsonb_build_object('reason', v_reason, 'end_date', v_emp.end_date), 'security', v_emp.id);
  return hrms.ok(jsonb_build_object('employee_id', v_emp.id, 'status', v_emp.status, 'end_date', v_emp.end_date,
    'pending_reviews_to_reassign', coalesce(v_pending, '[]'::jsonb)), v_emp.version);
end;
$$;

create or replace function hrms.save_private_details(p_actor hrms.actor, p_employee_id uuid, p_patch jsonb,
                                                     p_expected_version integer)
returns hrms.employee_private_details
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row hrms.employee_private_details;
  v_dob date;
begin
  insert into hrms.employee_private_details (employee_id, org_id)
  values (p_employee_id, p_actor.org_id) on conflict (employee_id) do nothing;
  select * into v_row from hrms.employee_private_details where employee_id = p_employee_id for update;
  if v_row.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'These details changed. Reload and try again.', null, true);
  end if;
  begin
    v_dob := nullif(p_patch ->> 'date_of_birth', '')::date;
  exception when others then
    perform hrms.raise_error('VALIDATION_FAILED', 'Invalid date of birth.', '{"date_of_birth":"Invalid date"}'::jsonb);
  end;
  update hrms.employee_private_details set
    personal_email = case when p_patch ? 'personal_email' then hrms.clean_text(p_patch ->> 'personal_email', 200) else personal_email end,
    personal_phone = case when p_patch ? 'personal_phone' then hrms.clean_text(p_patch ->> 'personal_phone', 40) else personal_phone end,
    address = case when p_patch ? 'address' then hrms.clean_text(p_patch ->> 'address', 500) else address end,
    emergency_contact_name = case when p_patch ? 'emergency_contact_name' then hrms.clean_text(p_patch ->> 'emergency_contact_name', 120) else emergency_contact_name end,
    emergency_contact_phone = case when p_patch ? 'emergency_contact_phone' then hrms.clean_text(p_patch ->> 'emergency_contact_phone', 40) else emergency_contact_phone end,
    date_of_birth = case when p_patch ? 'date_of_birth' then v_dob else date_of_birth end,
    version = version + 1, updated_by = p_actor.employee_id, updated_at = now()
  where employee_id = p_employee_id
  returning * into v_row;
  -- Field names only: personal values are not copied into the audit log.
  perform hrms.audit(p_actor.org_id, p_actor.employee_id, 'employee.private_details_updated', 'employee', p_employee_id,
    jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(p_patch) k)), 'business', p_employee_id);
  return v_row;
end;
$$;

create or replace function public.update_private_details(p_employee_id uuid, p_patch jsonb, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  perform hrms.save_private_details(v_actor, p_employee_id, p_patch, p_expected_version);
  return public.get_employee(p_employee_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Own profile (S16) and directory (S17)
-- -----------------------------------------------------------------------------

create or replace function public.get_my_profile() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_today date := hrms.org_today(v_actor.org_id);
  v_private hrms.employee_private_details;
begin
  select * into v_emp from hrms.employees where id = v_actor.employee_id;
  select * into v_private from hrms.employee_private_details where employee_id = v_emp.id;
  return hrms.ok(hrms.employee_card(v_emp, v_today) || jsonb_build_object(
    'join_date', v_emp.join_date, 'end_date', v_emp.end_date, 'status', v_emp.status,
    'roles', to_jsonb(v_actor.roles),
    'manager', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                from hrms.employees e
                where e.id = hrms.manager_of_team_on(hrms.team_on(v_emp.id, v_today), v_today)),
    'office', (select jsonb_build_object('id', o.id, 'name', o.name) from hrms.office_assignments a
               join hrms.offices o on o.id = a.office_id
               where a.employee_id = v_emp.id and daterange(a.effective_from, a.effective_to, '[)') @> v_today),
    'shift', (select jsonb_build_object('id', s.id, 'name', s.name, 'start_local', v.start_local, 'end_local', v.end_local,
                                        'lunch_paid', v.lunch_paid, 'lunch_start_local', v.lunch_start_local,
                                        'lunch_end_local', v.lunch_end_local, 'grace_seconds', v.grace_seconds,
                                        'weekly_mask', v.weekly_mask)
              from hrms.shift_assignments a join hrms.shifts s on s.id = a.shift_id
              join lateral (select * from hrms.shift_versions sv where sv.shift_id = s.id and sv.state = 'published'
                            and sv.effective_from <= v_today order by sv.effective_from desc limit 1) v on true
              where a.employee_id = v_emp.id and daterange(a.effective_from, a.effective_to, '[)') @> v_today),
    'private', jsonb_build_object('personal_email', v_private.personal_email, 'personal_phone', v_private.personal_phone,
      'address', v_private.address, 'emergency_contact_name', v_private.emergency_contact_name,
      'emergency_contact_phone', v_private.emergency_contact_phone, 'date_of_birth', v_private.date_of_birth,
      'version', coalesce(v_private.version, 1)),
    'version', v_emp.version));
end;
$$;

-- Own personal fields only; role/team/shift/employment go through HR.
create or replace function public.update_my_profile(p_patch jsonb, p_expected_version integer) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_allowed text[] := array['personal_email', 'personal_phone', 'address', 'emergency_contact_name',
                            'emergency_contact_phone', 'date_of_birth'];
  v_key text;
begin
  for v_key in select jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) loop
    if not (v_key = any(v_allowed)) then
      perform hrms.raise_error('ACCESS_DENIED', 'This field is managed by HR.',
        jsonb_build_object(v_key, 'Managed by HR'));
    end if;
  end loop;
  perform hrms.save_private_details(v_actor, v_actor.employee_id, p_patch, p_expected_version);
  return public.get_my_profile();
end;
$$;

-- Safe directory projection: private details are never selected here.
create or replace function public.list_directory(
  p_search text default null, p_team_id uuid default null, p_department_id uuid default null,
  p_limit integer default 25, p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 10000);
  v_term text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
  v_total integer;
begin
  with filtered as (
    select e.* from hrms.employees e
    where e.org_id = v_actor.org_id and e.status = 'active'
      and (p_department_id is null or e.department_id = p_department_id)
      and (p_team_id is null or hrms.team_on(e.id, v_today) = p_team_id)
      and (v_term is null
           or e.employee_code like upper(hrms.like_escape(v_term)) || '%'
           or lower(e.full_name) like lower(hrms.like_escape(v_term)) || '%'
           or lower(e.full_name) like '% ' || lower(hrms.like_escape(v_term)) || '%')
  )
  select (select count(*) from filtered),
         (select coalesce(jsonb_agg(hrms.employee_card(f, v_today) order by f.full_name, f.id), '[]'::jsonb)
          from (select * from filtered order by full_name, id limit v_limit offset v_offset) f)
    into v_total, v_rows;
  return hrms.ok(jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset));
end;
$$;

create or replace function public.revoke_device(p_device_id uuid, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_dev hrms.devices;
  v_reason text := hrms.clean_text(p_reason, 300);
begin
  select * into v_dev from hrms.devices where id = p_device_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_dev.employee_id <> v_actor.employee_id and not hrms.can_master_data(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  update hrms.devices set revoked_at = coalesce(revoked_at, now()), revoked_by = v_actor.employee_id,
                          revoke_reason = coalesce(revoke_reason, v_reason)
  where id = v_dev.id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'device.revoked', 'device', v_dev.id,
    jsonb_build_object('reason', v_reason), 'security', v_dev.employee_id);
  return hrms.ok(jsonb_build_object('device_id', v_dev.id, 'revoked', true));
end;
$$;

-- Eligible reviewers for pickers (routes, reassignment).
create or replace function public.list_reviewer_candidates() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.is_admin(v_actor) or hrms.can_master_data(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name,
      'roles', to_jsonb(hrms.employee_roles(e.id))) order by e.full_name), '[]'::jsonb)
    from hrms.employees e where e.org_id = v_actor.org_id and e.status = 'active'
      and hrms.employee_roles(e.id) && array['manager', 'hr', 'admin']));
end;
$$;

-- -----------------------------------------------------------------------------
-- Hours reports (S24): scope = work-date team membership AND current authority
-- -----------------------------------------------------------------------------

-- Visible (employee, date-window) pairs for the actor over a range, as ONE
-- set-based query. Manager windows are the intersection of the employee's
-- membership in a team the actor manages TODAY with the requested range.
create or replace function hrms.report_scope(p_actor hrms.actor, p_from date, p_to date)
returns table (employee_id uuid, window_from date, window_to date)
language sql
stable
security definer
set search_path = ''
as $$
  select e.id, greatest(p_from, e.join_date), least(p_to, coalesce(e.end_date, p_to))
  from hrms.employees e
  where hrms.has_perm(p_actor, 'reports.org') and e.org_id = p_actor.org_id and e.status <> 'pending'
    and e.id <> p_actor.employee_id
  union all
  select m.employee_id, greatest(p_from, m.effective_from),
         least(p_to, coalesce(m.effective_to - 1, p_to))
  from hrms.team_memberships m
  join hrms.team_managers tm on tm.team_id = m.team_id
   and tm.manager_id = p_actor.employee_id
   and daterange(tm.effective_from, tm.effective_to, '[)') @> hrms.org_today(p_actor.org_id)
  where not hrms.has_perm(p_actor, 'reports.org') and hrms.has_perm(p_actor, 'reports.team')
    and m.employee_id <> p_actor.employee_id
    and daterange(m.effective_from, m.effective_to, '[)') && daterange(p_from, p_to, '[]');
$$;

create or replace function public.get_hours_report(
  p_from date, p_to date, p_team_id uuid default null, p_office_id uuid default null,
  p_employee_ids uuid[] default null, p_limit integer default 25, p_offset integer default 0
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_now timestamptz := clock_timestamp();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 10000);
  v_ids uuid[];
  v_scope_ids uuid[];
  v_scope_from date[];
  v_scope_to date[];
  v_result jsonb;
begin
  if not (hrms.has_perm(v_actor, 'reports.org') or hrms.has_perm(v_actor, 'reports.team')) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a valid date range.', '{"range":"Invalid"}'::jsonb);
  end if;
  if p_to - p_from > 365 then
    perform hrms.raise_error('RANGE_TOO_LARGE', 'Choose at most 366 days. Use export for longer periods.');
  end if;

  select array_agg(s.employee_id), array_agg(s.window_from), array_agg(s.window_to)
    into v_scope_ids, v_scope_from, v_scope_to
  from hrms.report_scope(v_actor, p_from, p_to) s
  where s.window_to >= s.window_from
    and (p_employee_ids is null or s.employee_id = any(p_employee_ids))
    and (p_team_id is null or hrms.team_on(s.employee_id, s.window_to) = p_team_id)
    and (p_office_id is null or exists (select 1 from hrms.office_assignments a where a.employee_id = s.employee_id
         and a.office_id = p_office_id and daterange(a.effective_from, a.effective_to, '[)') && daterange(s.window_from, s.window_to, '[]')));

  select array_agg(distinct x) into v_ids from unnest(v_scope_ids) x;
  if v_ids is null then
    return hrms.ok(jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'totals', hrms.attendance_totals('[]'::jsonb),
                                      'from', p_from, 'to', p_to));
  end if;
  perform hrms.ensure_schedule_instances(v_actor.org_id, v_ids, p_from, least(p_to, hrms.org_today(v_actor.org_id)));

  with scope as (
    select * from unnest(v_scope_ids, v_scope_from, v_scope_to) as u(employee_id, window_from, window_to)
  ),
  rows as (
    select r.employee_id, hrms.attendance_row_json(r) as j
    from hrms.attendance_rows(v_actor.org_id, v_ids, p_from, p_to, v_now) r
    join scope s on s.employee_id = r.employee_id and r.shift_date between s.window_from and s.window_to
  ),
  per_emp as (
    select employee_id, hrms.attendance_totals(jsonb_agg(j)) as totals, jsonb_agg(j) as all_rows
    from rows group by employee_id
  ),
  ranked as (
    select p.*, e.full_name, e.employee_code, e.status
    from per_emp p join hrms.employees e on e.id = p.employee_id
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'server_time', v_now,
    'total', (select count(*) from ranked),
    'totals', hrms.attendance_totals(coalesce((select jsonb_agg(x.j) from rows x), '[]'::jsonb)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
               'employee', jsonb_build_object('id', r.employee_id, 'code', r.employee_code, 'name', r.full_name,
                                              'status', r.status),
               'totals', r.totals) order by r.full_name, r.employee_id)
             from (select * from ranked order by full_name, employee_id limit v_limit offset v_offset) r), '[]'::jsonb))
    into v_result;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'report.hours_viewed', 'organization', v_actor.org_id,
    jsonb_build_object('from', p_from, 'to', p_to, 'team_id', p_team_id, 'employees', cardinality(v_ids)), 'access');
  return hrms.ok(v_result);
end;
$$;

-- Day rows for one employee inside the actor's report scope.
create or replace function public.get_hours_report_days(p_employee_id uuid, p_from date, p_to date) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_now timestamptz := clock_timestamp();
  v_rows jsonb;
begin
  if p_to - p_from > 365 or p_to < p_from then
    perform hrms.raise_error('RANGE_TOO_LARGE', 'Choose at most 366 days.');
  end if;
  if not exists (select 1 from hrms.report_scope(v_actor, p_from, p_to) s where s.employee_id = p_employee_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  perform hrms.ensure_schedule_instances(v_actor.org_id, array[p_employee_id], p_from, least(p_to, hrms.org_today(v_actor.org_id)));
  select coalesce(jsonb_agg(hrms.attendance_row_json(r) order by r.shift_date desc), '[]'::jsonb) into v_rows
  from hrms.attendance_rows(v_actor.org_id, array[p_employee_id], p_from, p_to, v_now) r
  where exists (select 1 from hrms.report_scope(v_actor, p_from, p_to) s
                where s.employee_id = p_employee_id and r.shift_date between s.window_from and s.window_to);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'rows', v_rows, 'totals', hrms.attendance_totals(v_rows)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Notifications (S19) + push tokens + announcements (S38)
-- -----------------------------------------------------------------------------

create or replace function public.list_notifications(
  p_before_created_at timestamptz default null, p_before_id uuid default null, p_limit integer default 25
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  return hrms.ok(jsonb_build_object(
    'unread', (select count(*) from hrms.notifications where recipient_id = v_actor.employee_id and read_at is null),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'event_id', n.event_id, 'kind', n.kind,
               'title', n.title, 'body', n.body, 'deep_link', n.deep_link, 'read_at', n.read_at,
               'created_at', n.created_at) order by n.created_at desc, n.id desc), '[]'::jsonb)
             from (select * from hrms.notifications n
                   where n.recipient_id = v_actor.employee_id
                     and (p_before_created_at is null or (n.created_at, n.id) < (p_before_created_at, p_before_id))
                   order by n.created_at desc, n.id desc limit v_limit) n)));
end;
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_count integer;
begin
  update hrms.notifications set read_at = now()
  where recipient_id = v_actor.employee_id and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics v_count = row_count;
  return hrms.ok(jsonb_build_object('marked', v_count));
end;
$$;

-- Binds a push token to the authenticated installation. A reused device or
-- token is rebound, never shared across employees.
create or replace function public.register_push_token(p_installation_id uuid, p_token text, p_platform text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if p_platform not in ('android', 'ios') or char_length(coalesce(p_token, '')) < 20 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Invalid token.');
  end if;
  update hrms.push_tokens set revoked_at = now()
  where revoked_at is null and (installation_id = p_installation_id or token = p_token);
  insert into hrms.push_tokens (org_id, employee_id, installation_id, token, platform)
  values (v_actor.org_id, v_actor.employee_id, p_installation_id, p_token, p_platform);
  return hrms.ok(jsonb_build_object('registered', true));
end;
$$;

create or replace function public.unregister_push_token(p_installation_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor('restricted');
begin
  update hrms.push_tokens set revoked_at = now()
  where installation_id = p_installation_id and employee_id = v_actor.employee_id and revoked_at is null;
  return hrms.ok(jsonb_build_object('unregistered', found));
end;
$$;

create or replace function public.publish_announcement(p_title text, p_body text, p_team_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_title text := hrms.clean_text(p_title, 120);
  v_body text := hrms.clean_text(p_body, 500);
  v_event uuid := gen_random_uuid();
  v_count integer;
begin
  if not (hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'announcements.publish')) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_title is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A title is required.', '{"title":"Required"}'::jsonb);
  end if;
  with recipients as (
    select e.id from hrms.employees e
    where e.org_id = v_actor.org_id and e.status = 'active'
      and (p_team_id is null or hrms.team_on(e.id, hrms.org_today(v_actor.org_id)) = p_team_id)
  ),
  ins as (
    insert into hrms.notifications (org_id, recipient_id, event_id, kind, title, body, deep_link)
    select v_actor.org_id, r.id, v_event, 'announcement', v_title, v_body, '/notifications' from recipients r
    on conflict (recipient_id, event_id) do nothing
    returning id
  ),
  outbox as (
    insert into hrms.outbox (org_id, notification_id) select v_actor.org_id, id from ins returning 1
  )
  select count(*) into v_count from outbox;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'announcement.published', 'organization', v_actor.org_id,
    jsonb_build_object('title', v_title, 'team_id', p_team_id, 'recipients', v_count));
  return hrms.ok(jsonb_build_object('recipients', v_count, 'event_id', v_event));
end;
$$;

-- -----------------------------------------------------------------------------
-- Audit (S36): Admin sees all; HR with audit.scoped sees business rows about
-- non-Admin employees. Keyset pagination on (created_at, id).
-- -----------------------------------------------------------------------------

create or replace function public.list_audit(
  p_from timestamptz default null, p_to timestamptz default null, p_actor_id uuid default null,
  p_action_prefix text default null, p_target_employee_id uuid default null,
  p_before_created_at timestamptz default null, p_before_id bigint default null, p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_full boolean := hrms.is_admin(v_actor);
begin
  if not (v_full or hrms.has_perm(v_actor, 'audit.scoped')) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'created_at', a.created_at, 'action', a.action, 'classification', a.classification,
      'target_type', a.target_type, 'target_id', a.target_id, 'request_id', a.request_id, 'changes', a.changes,
      'actor', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                from hrms.employees e where e.id = a.actor_employee_id),
      'target_employee', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                          from hrms.employees e where e.id = a.target_employee_id))
      order by a.created_at desc, a.id desc), '[]'::jsonb)
    from (select * from hrms.audit_logs a
          where a.org_id = v_actor.org_id
            and (p_from is null or a.created_at >= p_from) and (p_to is null or a.created_at < p_to)
            and (p_actor_id is null or a.actor_employee_id = p_actor_id)
            and (p_action_prefix is null or a.action like hrms.like_escape(p_action_prefix) || '%')
            and (p_target_employee_id is null or a.target_employee_id = p_target_employee_id)
            and (v_full or (a.classification = 'business' and (a.target_employee_id is null
                   or not ('admin' = any(hrms.employee_roles(a.target_employee_id))))))
            and (p_before_created_at is null or (a.created_at, a.id) < (p_before_created_at, p_before_id))
          order by a.created_at desc, a.id desc limit v_limit) a));
end;
$$;

-- -----------------------------------------------------------------------------
-- Workspace (S21)
-- -----------------------------------------------------------------------------

create or replace function public.get_workspace_summary() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_now timestamptz := clock_timestamp();
  v_today date := hrms.org_today(v_actor.org_id);
  v_week_start date := v_today - (extract(isodow from v_today)::integer - 1);
  v_ids uuid[];
  v_week jsonb;
  v_missed integer;
begin
  if not (hrms.has_perm(v_actor, 'reports.org') or hrms.has_perm(v_actor, 'reports.team')
          or hrms.has_perm(v_actor, 'approvals.review') or hrms.is_admin(v_actor)) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  select array_agg(distinct s.employee_id) into v_ids from hrms.report_scope(v_actor, v_week_start, v_today) s;
  if v_ids is not null then
    perform hrms.ensure_schedule_instances(v_actor.org_id, v_ids, v_week_start, v_today);
    select hrms.attendance_totals(coalesce(jsonb_agg(hrms.attendance_row_json(r)), '[]'::jsonb)) into v_week
    from hrms.attendance_rows(v_actor.org_id, v_ids, v_week_start, v_today, v_now) r;
    select count(*) into v_missed from hrms.attendance_sessions s
    where s.employee_id = any(v_ids) and s.state = 'needs_correction' and s.shift_date >= v_today - 7;
  end if;
  return hrms.ok(jsonb_build_object(
    'team_today', hrms.team_today(v_actor, v_now),
    'week', jsonb_build_object('from', v_week_start, 'to', v_today, 'totals', v_week),
    'missed_punches_7d', coalesce(v_missed, 0),
    'pending_reviews', (select count(*) from hrms.requests r where r.assigned_reviewer_id = v_actor.employee_id
                          and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')),
    'unassigned_reviews', case when hrms.is_admin(v_actor) then (select count(*) from hrms.requests r
                             where r.org_id = v_actor.org_id and r.assigned_reviewer_id is null
                               and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')) end,
    'storage', case when hrms.is_admin(v_actor) then (select jsonb_build_object('used_bytes', coalesce(l.used_bytes, 0),
                      'reserved_bytes', coalesce(l.reserved_bytes, 0), 'budget_bytes', o.storage_budget_bytes)
                    from hrms.organizations o left join hrms.storage_ledger l on l.org_id = o.id
                    where o.id = v_actor.org_id) end,
    'admin_tasks', case when hrms.is_admin(v_actor) then hrms.admin_tasks(v_actor.org_id) end,
    'scope', case when hrms.has_perm(v_actor, 'reports.org') then 'organization'
                  when hrms.has_perm(v_actor, 'reports.team') then 'team' else 'reviews' end));
end;
$$;

-- Extension point for archive/maintenance tasks (filled by later migrations).
create or replace function hrms.admin_tasks(p_org uuid) returns jsonb
language sql stable set search_path = '' as $$ select '[]'::jsonb; $$;

select hrms.apply_api_grants();
