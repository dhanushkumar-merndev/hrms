-- =============================================================================
-- Admin / HR configuration API (S29–S33, S37): organisation settings,
-- structure, offices, shifts, holidays, leave policy, routes and access.
-- Every mutation authorises the actor, validates, versions and audits.
-- =============================================================================

alter table hrms.leave_reservations drop constraint leave_reservations_state_check;
alter table hrms.leave_reservations add constraint leave_reservations_state_check
  check (state in ('active', 'converted', 'released', 'credited'));

create or replace function hrms.can_master_data(p_actor hrms.actor) returns boolean
language sql immutable set search_path = ''
as $$ select hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'hr.master_data'); $$;

create or replace function hrms.can_draft_policy(p_actor hrms.actor) returns boolean
language sql immutable set search_path = ''
as $$ select hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'policy.draft'); $$;

create or replace function hrms.require_admin(p_actor hrms.actor) returns void
language plpgsql set search_path = ''
as $$ begin if not hrms.is_admin(p_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if; end; $$;

create or replace function hrms.valid_timezone(p_tz text) returns boolean
language sql stable set search_path = ''
as $$ select exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz); $$;

-- Active employees of an org (for set-based reconciliation).
create or replace function hrms.active_employee_ids(p_org uuid) returns uuid[]
language sql stable set search_path = ''
as $$ select coalesce(array_agg(id), '{}') from hrms.employees where org_id = p_org and status = 'active'; $$;

-- Reporting graph must stay acyclic (employee -> manager of their team).
create or replace function hrms.assert_no_reporting_cycle(p_org uuid, p_day date) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle boolean;
begin
  with recursive edges as (
    select m.employee_id as child, tm.manager_id as parent
    from hrms.team_memberships m
    join hrms.team_managers tm on tm.team_id = m.team_id
     and daterange(tm.effective_from, tm.effective_to, '[)') @> p_day
    where m.org_id = p_org and daterange(m.effective_from, m.effective_to, '[)') @> p_day
  ),
  walk (start_node, node, depth, path) as (
    select child, parent, 1, array[child] from edges
    union all
    select w.start_node, e.parent, w.depth + 1, w.path || w.node
    from walk w join edges e on e.child = w.node
    where w.depth < 50 and not (w.node = any(w.path))
  )
  select exists (select 1 from walk where node = start_node) into v_cycle;
  if v_cycle then
    perform hrms.raise_error('VALIDATION_FAILED',
      'This change would make someone report to themselves (a management cycle).',
      '{"manager_id":"Creates a reporting cycle"}'::jsonb);
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Organisation settings (S37)
-- -----------------------------------------------------------------------------

create or replace function public.get_org_settings() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_ledger hrms.storage_ledger;
begin
  perform hrms.require_admin(v_actor);
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  select * into v_ledger from hrms.storage_ledger where org_id = v_org.id;
  return hrms.ok(jsonb_build_object(
    'id', v_org.id, 'code', v_org.code, 'name', v_org.name, 'timezone', v_org.timezone,
    'annual_start_month', v_org.annual_start_month, 'leave_year_start_month', v_org.leave_year_start_month,
    'active_employee_cap', v_org.active_employee_cap, 'holiday_target', v_org.holiday_target,
    'support_contact', v_org.support_contact, 'storage_budget_bytes', v_org.storage_budget_bytes,
    'storage_alert_percents', to_jsonb(v_org.storage_alert_percents), 'strict_geofence', v_org.strict_geofence,
    'require_biometric_punch', v_org.require_biometric_punch,
    'storage_used_bytes', coalesce(v_ledger.used_bytes, 0), 'storage_reserved_bytes', coalesce(v_ledger.reserved_bytes, 0),
    'active_employees', (select count(*) from hrms.employees where org_id = v_org.id and status = 'active'),
    'setup_published_at', v_org.setup_published_at, 'version', v_org.version), v_org.version);
end;
$$;

create or replace function public.update_org_settings(p_patch jsonb, p_expected_version integer) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_errors jsonb := '{}'::jsonb;
  v_active integer;
begin
  perform hrms.require_admin(v_actor);
  select * into v_org from hrms.organizations where id = v_actor.org_id for update;
  if v_org.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'Settings changed. Reload and try again.', null, true);
  end if;
  if p_patch ? 'timezone' and not hrms.valid_timezone(p_patch ->> 'timezone') then
    v_errors := v_errors || '{"timezone":"Unknown time zone"}';
  end if;
  if p_patch ? 'annual_start_month' and (p_patch ->> 'annual_start_month')::integer not in (1, 4) then
    v_errors := v_errors || '{"annual_start_month":"January or April"}';
  end if;
  if p_patch ? 'annual_start_month' and (p_patch ->> 'annual_start_month')::integer <> v_org.annual_start_month
     and exists (select 1 from hrms.organizations o where o.id = v_org.id)
     and hrms.org_has_export_jobs(v_org.id) then
    v_errors := v_errors || '{"annual_start_month":"Use the annual-period transition flow; existing archive periods are immutable"}';
  end if;
  if p_patch ? 'leave_year_start_month' and (p_patch ->> 'leave_year_start_month')::integer not between 1 and 12 then
    v_errors := v_errors || '{"leave_year_start_month":"1–12"}';
  end if;
  if p_patch ? 'active_employee_cap' then
    select count(*) into v_active from hrms.employees where org_id = v_org.id and status = 'active';
    if (p_patch ->> 'active_employee_cap')::integer < greatest(1, v_active) then
      v_errors := v_errors || jsonb_build_object('active_employee_cap',
        format('Cannot be below the %s currently active employees', v_active));
    end if;
  end if;
  if p_patch ? 'storage_budget_bytes' and (p_patch ->> 'storage_budget_bytes')::bigint < 1000000 then
    v_errors := v_errors || '{"storage_budget_bytes":"At least 1 MB"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the highlighted fields.', v_errors);
  end if;

  update hrms.organizations set
    name = coalesce(hrms.clean_text(p_patch ->> 'name', 120), name),
    timezone = coalesce(p_patch ->> 'timezone', timezone),
    annual_start_month = coalesce((p_patch ->> 'annual_start_month')::smallint, annual_start_month),
    leave_year_start_month = coalesce((p_patch ->> 'leave_year_start_month')::smallint, leave_year_start_month),
    active_employee_cap = coalesce((p_patch ->> 'active_employee_cap')::integer, active_employee_cap),
    holiday_target = coalesce((p_patch ->> 'holiday_target')::integer, holiday_target),
    support_contact = case when p_patch ? 'support_contact' then hrms.clean_text(p_patch ->> 'support_contact', 200)
                           else support_contact end,
    storage_budget_bytes = coalesce((p_patch ->> 'storage_budget_bytes')::bigint, storage_budget_bytes),
    strict_geofence = coalesce((p_patch ->> 'strict_geofence')::boolean, strict_geofence),
    require_biometric_punch = coalesce((p_patch ->> 'require_biometric_punch')::boolean, require_biometric_punch),
    setup_published_at = case when (p_patch ->> 'publish_setup')::boolean then coalesce(setup_published_at, now())
                              else setup_published_at end,
    version = version + 1
  where id = v_org.id
  returning * into v_org;
  insert into hrms.settings_versions (org_id, version, snapshot, changed_by, reason)
  values (v_org.id, v_org.version, to_jsonb(v_org) - 'updated_at', v_actor.employee_id,
          hrms.clean_text(p_patch ->> 'reason', 500));
  perform hrms.audit(v_org.id, v_actor.employee_id, 'org.settings_updated', 'organization', v_org.id,
    p_patch - 'reason', 'business');
  return public.get_org_settings();
end;
$$;

-- Stub until the exports migration defines archive jobs.
create or replace function hrms.org_has_export_jobs(p_org uuid) returns boolean
language sql stable set search_path = '' as $$ select false; $$;

-- -----------------------------------------------------------------------------
-- Departments and teams (S29)
-- -----------------------------------------------------------------------------

create or replace function public.list_org_structure() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
begin
  return hrms.ok(jsonb_build_object(
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'active', d.active,
                       'version', d.version) order by d.name), '[]'::jsonb)
                    from hrms.departments d where d.org_id = v_actor.org_id),
    'teams', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', t.id, 'name', t.name, 'active', t.active, 'version', t.version, 'department_id', t.department_id,
                 'manager', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code,
                                                       'since', tm.effective_from)
                             from hrms.team_managers tm join hrms.employees e on e.id = tm.manager_id
                             where tm.team_id = t.id and daterange(tm.effective_from, tm.effective_to, '[)') @> v_today),
                 'member_count', (select count(*) from hrms.team_memberships m join hrms.employees e on e.id = m.employee_id
                                  where m.team_id = t.id and e.status = 'active'
                                    and daterange(m.effective_from, m.effective_to, '[)') @> v_today))
                 order by t.name), '[]'::jsonb)
              from hrms.teams t where t.org_id = v_actor.org_id),
    'offices', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'active', o.active)
                   order by o.name), '[]'::jsonb) from hrms.offices o where o.org_id = v_actor.org_id),
    'shifts', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'active', s.active)
                  order by s.name), '[]'::jsonb) from hrms.shifts s where s.org_id = v_actor.org_id)));
end;
$$;

create or replace function public.save_department(p_id uuid, p_name text, p_active boolean, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.departments;
  v_name text := hrms.clean_text(p_name, 80);
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_name is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Name is required.', '{"name":"Required"}'::jsonb);
  end if;
  begin
    if p_id is null then
      insert into hrms.departments (org_id, name, active) values (v_actor.org_id, v_name, coalesce(p_active, true))
      returning * into v_row;
    else
      update hrms.departments set name = v_name, active = coalesce(p_active, active), version = version + 1
      where id = p_id and org_id = v_actor.org_id and version = p_expected_version
      returning * into v_row;
      if not found then perform hrms.raise_error('STALE_VERSION', 'Reload and try again.', null, true); end if;
    end if;
  exception when unique_violation then
    perform hrms.raise_error('VALIDATION_FAILED', 'A department with this name exists.', '{"name":"Already exists"}'::jsonb);
  end;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'department.saved', 'department', v_row.id,
    jsonb_build_object('name', v_row.name, 'active', v_row.active));
  return hrms.ok(to_jsonb(v_row), v_row.version);
end;
$$;

create or replace function public.save_team(p_id uuid, p_name text, p_department_id uuid, p_active boolean,
                                            p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.teams;
  v_name text := hrms.clean_text(p_name, 80);
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_name is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Name is required.', '{"name":"Required"}'::jsonb);
  end if;
  if p_department_id is not null and not exists (
       select 1 from hrms.departments where id = p_department_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown department.', '{"department_id":"Unknown"}'::jsonb);
  end if;
  begin
    if p_id is null then
      insert into hrms.teams (org_id, name, department_id, active)
      values (v_actor.org_id, v_name, p_department_id, coalesce(p_active, true))
      returning * into v_row;
    else
      update hrms.teams set name = v_name, department_id = p_department_id, active = coalesce(p_active, active),
                            version = version + 1
      where id = p_id and org_id = v_actor.org_id and version = p_expected_version
      returning * into v_row;
      if not found then perform hrms.raise_error('STALE_VERSION', 'Reload and try again.', null, true); end if;
    end if;
  exception when unique_violation then
    perform hrms.raise_error('VALIDATION_FAILED', 'A team with this name exists.', '{"name":"Already exists"}'::jsonb);
  end;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'team.saved', 'team', v_row.id,
    jsonb_build_object('name', v_row.name, 'active', v_row.active, 'department_id', v_row.department_id));
  return hrms.ok(to_jsonb(v_row), v_row.version);
end;
$$;

-- Sets (or ends, when p_manager_id is null) a team's manager from a date.
create or replace function public.set_team_manager(p_team_id uuid, p_manager_id uuid, p_effective_from date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_from date := coalesce(p_effective_from, hrms.org_today(v_actor.org_id));
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.teams where id = p_team_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_manager_id is not null and not exists (
       select 1 from hrms.employees where id = p_manager_id and org_id = v_actor.org_id and status = 'active') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose an active employee.', '{"manager_id":"Not active"}'::jsonb);
  end if;
  if p_manager_id is not null and hrms.team_on(p_manager_id, v_from) = p_team_id then
    perform hrms.raise_error('VALIDATION_FAILED',
      'A manager cannot be a member of the team they manage. Place them in a parent team first.',
      '{"manager_id":"Member of this team"}'::jsonb);
  end if;
  -- Close the current assignment at v_from; drop future ones.
  delete from hrms.team_managers where team_id = p_team_id and effective_from >= v_from;
  update hrms.team_managers set effective_to = v_from
  where team_id = p_team_id and effective_from < v_from and (effective_to is null or effective_to > v_from);
  if p_manager_id is not null then
    insert into hrms.team_managers (org_id, team_id, manager_id, effective_from, created_by, reason)
    values (v_actor.org_id, p_team_id, p_manager_id, v_from, v_actor.employee_id, hrms.clean_text(p_reason, 500));
    -- Team manager implies the manager role for reports/approvals.
    if not ('manager' = any(hrms.employee_roles(p_manager_id))) then
      insert into hrms.role_grants (org_id, employee_id, role, granted_by, reason)
      values (v_actor.org_id, p_manager_id, 'manager', v_actor.employee_id, 'Assigned as team manager');
    end if;
  end if;
  perform hrms.assert_no_reporting_cycle(v_actor.org_id, v_from);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'team.manager_set', 'team', p_team_id,
    jsonb_build_object('manager_id', p_manager_id, 'effective_from', v_from, 'reason', p_reason), 'business',
    p_manager_id);
  return public.list_org_structure();
end;
$$;

-- Generic effective-dated reassignment helper for membership-like tables.
create or replace function public.set_employee_team(p_employee_id uuid, p_team_id uuid, p_effective_from date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_from date := coalesce(p_effective_from, hrms.org_today(v_actor.org_id));
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id)
     or not exists (select 1 from hrms.teams where id = p_team_id and org_id = v_actor.org_id and active) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  delete from hrms.team_memberships where employee_id = p_employee_id and effective_from >= v_from;
  update hrms.team_memberships set effective_to = v_from
  where employee_id = p_employee_id and effective_from < v_from and (effective_to is null or effective_to > v_from);
  insert into hrms.team_memberships (org_id, employee_id, team_id, effective_from, created_by, reason)
  values (v_actor.org_id, p_employee_id, p_team_id, v_from, v_actor.employee_id, hrms.clean_text(p_reason, 500));
  if exists (select 1 from hrms.team_managers where team_id = p_team_id and manager_id = p_employee_id
             and daterange(effective_from, effective_to, '[)') @> v_from) then
    perform hrms.raise_error('VALIDATION_FAILED', 'This person manages that team.',
      '{"team_id":"They manage this team"}'::jsonb);
  end if;
  perform hrms.assert_no_reporting_cycle(v_actor.org_id, v_from);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.team_changed', 'employee', p_employee_id,
    jsonb_build_object('team_id', p_team_id, 'effective_from', v_from, 'reason', p_reason), 'business', p_employee_id);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'team_id', p_team_id, 'effective_from', v_from));
end;
$$;

-- -----------------------------------------------------------------------------
-- Offices (S31): geofence configuration is versioned
-- -----------------------------------------------------------------------------

create or replace function hrms.office_json(o hrms.offices) returns jsonb
language sql stable set search_path = ''
as $$
  select jsonb_build_object('id', o.id, 'name', o.name, 'timezone', o.timezone,
    'latitude', extensions.st_y(o.location::extensions.geometry), 'longitude', extensions.st_x(o.location::extensions.geometry),
    'radius_m', o.radius_m, 'max_accuracy_m', o.max_accuracy_m, 'max_sample_age_s', o.max_sample_age_s,
    'strict_mode', o.strict_mode, 'active', o.active, 'calibration_status', o.calibration_status,
    'calibration_notes', o.calibration_notes, 'config_version', o.config_version, 'version', o.version,
    'assigned_count', (select count(*) from hrms.office_assignments a join hrms.employees e on e.id = a.employee_id
                       where a.office_id = o.id and e.status = 'active'
                         and daterange(a.effective_from, a.effective_to, '[)') @> hrms.org_today(o.org_id)));
$$;

create or replace function public.list_offices() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'hr.master_data')) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  return hrms.ok((select coalesce(jsonb_agg(hrms.office_json(o) order by o.name), '[]'::jsonb)
                  from hrms.offices o where o.org_id = v_actor.org_id));
end;
$$;

create or replace function public.save_office(
  p_id uuid, p_name text, p_timezone text, p_latitude double precision, p_longitude double precision,
  p_radius_m numeric, p_max_accuracy_m numeric, p_max_sample_age_s integer, p_strict_mode boolean,
  p_active boolean, p_calibration_status text, p_calibration_notes text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.offices;
  v_old hrms.offices;
  v_errors jsonb := '{}'::jsonb;
  v_org hrms.organizations;
  v_geo_changed boolean;
begin
  perform hrms.require_admin(v_actor);
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  if hrms.clean_text(p_name, 120) is null then v_errors := v_errors || '{"name":"Required"}'; end if;
  if p_latitude is null or p_latitude not between -90 and 90 then v_errors := v_errors || '{"latitude":"-90 to 90"}'; end if;
  if p_longitude is null or p_longitude not between -180 and 180 then v_errors := v_errors || '{"longitude":"-180 to 180"}'; end if;
  if coalesce(p_radius_m, 20) not between 5 and 2000 then v_errors := v_errors || '{"radius_m":"5–2000 m"}'; end if;
  if coalesce(p_max_accuracy_m, 15) not between 1 and 500 then v_errors := v_errors || '{"max_accuracy_m":"1–500 m"}'; end if;
  if coalesce(p_max_sample_age_s, 10) not between 1 and 120 then v_errors := v_errors || '{"max_sample_age_s":"1–120 s"}'; end if;
  if p_timezone is not null and not hrms.valid_timezone(p_timezone) then v_errors := v_errors || '{"timezone":"Unknown"}'; end if;
  if coalesce(p_calibration_status, 'untested') not in ('untested', 'piloting', 'verified') then
    v_errors := v_errors || '{"calibration_status":"Invalid"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the highlighted fields.', v_errors);
  end if;

  if p_id is null then
    insert into hrms.offices (org_id, name, timezone, location, radius_m, max_accuracy_m, max_sample_age_s,
                              strict_mode, active, calibration_status, calibration_notes)
    values (v_actor.org_id, hrms.clean_text(p_name, 120), coalesce(p_timezone, v_org.timezone),
            extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography,
            coalesce(p_radius_m, 20), coalesce(p_max_accuracy_m, 15), coalesce(p_max_sample_age_s, 10),
            coalesce(p_strict_mode, false), coalesce(p_active, true), coalesce(p_calibration_status, 'untested'),
            hrms.clean_text(p_calibration_notes, 1000))
    returning * into v_row;
    v_geo_changed := true;
  else
    select * into v_old from hrms.offices where id = p_id and org_id = v_actor.org_id for update;
    if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
    if v_old.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'Reload and try again.', null, true);
    end if;
    v_geo_changed := extensions.st_y(v_old.location::extensions.geometry) <> p_latitude
      or extensions.st_x(v_old.location::extensions.geometry) <> p_longitude
      or v_old.radius_m <> coalesce(p_radius_m, v_old.radius_m)
      or v_old.max_accuracy_m <> coalesce(p_max_accuracy_m, v_old.max_accuracy_m)
      or v_old.max_sample_age_s <> coalesce(p_max_sample_age_s, v_old.max_sample_age_s)
      or v_old.strict_mode <> coalesce(p_strict_mode, v_old.strict_mode);
    update hrms.offices set
      name = hrms.clean_text(p_name, 120), timezone = coalesce(p_timezone, timezone),
      location = extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography,
      radius_m = coalesce(p_radius_m, radius_m), max_accuracy_m = coalesce(p_max_accuracy_m, max_accuracy_m),
      max_sample_age_s = coalesce(p_max_sample_age_s, max_sample_age_s), strict_mode = coalesce(p_strict_mode, strict_mode),
      active = coalesce(p_active, active), calibration_status = coalesce(p_calibration_status, calibration_status),
      calibration_notes = hrms.clean_text(p_calibration_notes, 1000),
      config_version = config_version + case when v_geo_changed then 1 else 0 end,
      version = version + 1
    where id = p_id
    returning * into v_row;
  end if;
  if v_geo_changed then
    insert into hrms.office_config_versions (office_id, config_version, snapshot, changed_by)
    values (v_row.id, v_row.config_version, hrms.office_json(v_row) - 'assigned_count', v_actor.employee_id);
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'office.saved', 'office', v_row.id,
    jsonb_build_object('config_version', v_row.config_version, 'radius_m', v_row.radius_m,
                       'max_accuracy_m', v_row.max_accuracy_m, 'active', v_row.active));
  return hrms.ok(hrms.office_json(v_row), v_row.version);
end;
$$;

create or replace function public.set_employee_office(p_employee_id uuid, p_office_id uuid, p_effective_from date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_from date := coalesce(p_effective_from, hrms.org_today(v_actor.org_id));
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id)
     or not exists (select 1 from hrms.offices where id = p_office_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_from <= hrms.org_today(v_actor.org_id) and exists (
       select 1 from hrms.work_schedule_instances where employee_id = p_employee_id and shift_date >= v_from
         and shift_date <= hrms.org_today(v_actor.org_id)) then
    v_from := hrms.org_today(v_actor.org_id) + 1;   -- snapshots already taken stay as recorded
  end if;
  delete from hrms.office_assignments where employee_id = p_employee_id and effective_from >= v_from;
  update hrms.office_assignments set effective_to = v_from
  where employee_id = p_employee_id and effective_from < v_from and (effective_to is null or effective_to > v_from);
  insert into hrms.office_assignments (org_id, employee_id, office_id, effective_from, created_by, reason)
  values (v_actor.org_id, p_employee_id, p_office_id, v_from, v_actor.employee_id, hrms.clean_text(p_reason, 500));
  perform hrms.refresh_future_instances(v_actor.org_id, array[p_employee_id], v_from, v_from + 60);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.office_changed', 'employee', p_employee_id,
    jsonb_build_object('office_id', p_office_id, 'effective_from', v_from), 'business', p_employee_id);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'office_id', p_office_id, 'effective_from', v_from));
end;
$$;

-- -----------------------------------------------------------------------------
-- Shifts (S30): HR drafts, Admin publishes; versions are prospective
-- -----------------------------------------------------------------------------

create or replace function public.list_shifts() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.can_master_data(v_actor) or hrms.can_draft_policy(v_actor)) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'active', s.active,
      'versions', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', v.id, 'version_no', v.version_no, 'effective_from', v.effective_from, 'state', v.state,
          'start_local', v.start_local, 'end_local', v.end_local, 'crosses_midnight', v.crosses_midnight,
          'weekly_mask', v.weekly_mask, 'grace_seconds', v.grace_seconds,
          'lunch_start_local', v.lunch_start_local, 'lunch_end_local', v.lunch_end_local, 'lunch_paid', v.lunch_paid,
          'early_entry_seconds', v.early_entry_seconds, 'early_credit', v.early_credit,
          'checkout_extension_enabled', v.checkout_extension_enabled,
          'checkout_extension_seconds', v.checkout_extension_seconds,
          'expected_seconds', hrms.shift_length_seconds(v.start_local, v.end_local)
             - case when v.lunch_paid or v.lunch_start_local is null then 0
                    else hrms.shift_offset_seconds(v.lunch_start_local, v.lunch_end_local) end,
          'published_at', v.published_at) order by v.version_no desc), '[]'::jsonb)
        from hrms.shift_versions v where v.shift_id = s.id),
      'assigned_count', (select count(*) from hrms.shift_assignments a join hrms.employees e on e.id = a.employee_id
                         where a.shift_id = s.id and e.status = 'active'
                           and daterange(a.effective_from, a.effective_to, '[)') @> hrms.org_today(s.org_id)))
      order by s.name), '[]'::jsonb)
    from hrms.shifts s where s.org_id = v_actor.org_id));
end;
$$;

create or replace function public.save_shift_draft(
  p_shift_id uuid, p_name text, p_effective_from date, p_start_local time, p_end_local time, p_weekly_mask integer,
  p_grace_seconds integer, p_lunch_start_local time, p_lunch_end_local time, p_early_entry_seconds integer,
  p_early_credit boolean, p_checkout_extension_enabled boolean, p_checkout_extension_seconds integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_shift hrms.shifts;
  v_ver hrms.shift_versions;
  v_errors jsonb;
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  v_errors := hrms.validate_shift(p_start_local, p_end_local, p_lunch_start_local, p_lunch_end_local);
  if p_effective_from is null then v_errors := v_errors || '{"effective_from":"Required"}'; end if;
  if coalesce(p_weekly_mask, 0) not between 1 and 127 then v_errors := v_errors || '{"weekly_mask":"Pick working days"}'; end if;
  if coalesce(p_grace_seconds, 0) not between 0 and 14400 then v_errors := v_errors || '{"grace_seconds":"0–240 min"}'; end if;
  if coalesce(p_checkout_extension_seconds, 0) not between 0 and 43200 then
    v_errors := v_errors || '{"checkout_extension_seconds":"0–720 min"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the shift.', v_errors);
  end if;
  if p_shift_id is null then
    begin
      insert into hrms.shifts (org_id, name) values (v_actor.org_id, hrms.clean_text(p_name, 80)) returning * into v_shift;
    exception when unique_violation then
      perform hrms.raise_error('VALIDATION_FAILED', 'A shift with this name exists.', '{"name":"Already exists"}'::jsonb);
    end;
  else
    select * into v_shift from hrms.shifts where id = p_shift_id and org_id = v_actor.org_id for update;
    if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  end if;
  -- One open draft per shift: replace it.
  delete from hrms.shift_versions where shift_id = v_shift.id and state = 'draft';
  insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local, weekly_mask,
    grace_seconds, lunch_start_local, lunch_end_local, lunch_paid, early_entry_seconds, early_credit,
    checkout_extension_enabled, checkout_extension_seconds, state, created_by)
  values (v_actor.org_id, v_shift.id,
    coalesce((select max(version_no) from hrms.shift_versions where shift_id = v_shift.id), 0) + 1,
    p_effective_from, p_start_local, p_end_local, p_weekly_mask, coalesce(p_grace_seconds, 1800),
    p_lunch_start_local, p_lunch_end_local, true, coalesce(p_early_entry_seconds, 1800), coalesce(p_early_credit, false),
    coalesce(p_checkout_extension_enabled, true), coalesce(p_checkout_extension_seconds, 7200), 'draft',
    v_actor.employee_id)
  returning * into v_ver;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'shift.draft_saved', 'shift_version', v_ver.id,
    jsonb_build_object('shift_id', v_shift.id, 'effective_from', p_effective_from));
  return hrms.ok(jsonb_build_object('shift_id', v_shift.id, 'version_id', v_ver.id, 'version_no', v_ver.version_no));
end;
$$;

-- Admin publishes. After the first version, changes are prospective only
-- (effective from tomorrow or later); closed history is never rewritten.
create or replace function public.publish_shift_version(p_version_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_ver hrms.shift_versions;
  v_today date := hrms.org_today(v_actor.org_id);
  v_ids uuid[];
begin
  perform hrms.require_admin(v_actor);
  select * into v_ver from hrms.shift_versions where id = p_version_id and org_id = v_actor.org_id for update;
  if not found or v_ver.state <> 'draft' then perform hrms.raise_error('VALIDATION_FAILED', 'Not a draft.'); end if;
  if exists (select 1 from hrms.shift_versions where shift_id = v_ver.shift_id and state = 'published')
     and v_ver.effective_from <= v_today then
    perform hrms.raise_error('VALIDATION_FAILED', 'Shift changes apply from tomorrow or later.',
      '{"effective_from":"Must be after today"}'::jsonb);
  end if;
  if exists (select 1 from hrms.shift_versions where shift_id = v_ver.shift_id and state = 'published'
             and effective_from >= v_ver.effective_from) then
    perform hrms.raise_error('VALIDATION_FAILED', 'A later version is already published.',
      '{"effective_from":"Must be after the latest published version"}'::jsonb);
  end if;
  update hrms.shift_versions set state = 'published', published_at = now(), published_by = v_actor.employee_id
  where id = v_ver.id;
  select coalesce(array_agg(distinct a.employee_id), '{}') into v_ids from hrms.shift_assignments a
  where a.shift_id = v_ver.shift_id and (a.effective_to is null or a.effective_to > v_ver.effective_from);
  perform hrms.refresh_future_instances(v_actor.org_id, v_ids, greatest(v_ver.effective_from, v_today + 1),
                                        greatest(v_ver.effective_from, v_today + 1) + 60);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'shift.published', 'shift_version', v_ver.id,
    jsonb_build_object('shift_id', v_ver.shift_id, 'effective_from', v_ver.effective_from,
                       'version_no', v_ver.version_no));
  return public.list_shifts();
end;
$$;

create or replace function public.set_employee_shift(p_employee_id uuid, p_shift_id uuid, p_effective_from date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
  v_from date := greatest(coalesce(p_effective_from, v_today + 1), v_today + 1);
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id)
     or not exists (select 1 from hrms.shifts where id = p_shift_id and org_id = v_actor.org_id and active) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  delete from hrms.shift_assignments where employee_id = p_employee_id and effective_from >= v_from;
  update hrms.shift_assignments set effective_to = v_from
  where employee_id = p_employee_id and effective_from < v_from and (effective_to is null or effective_to > v_from);
  insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from, created_by, reason)
  values (v_actor.org_id, p_employee_id, p_shift_id, v_from, v_actor.employee_id, hrms.clean_text(p_reason, 500));
  perform hrms.refresh_future_instances(v_actor.org_id, array[p_employee_id], v_from, v_from + 60);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.shift_changed', 'employee', p_employee_id,
    jsonb_build_object('shift_id', p_shift_id, 'effective_from', v_from), 'business', p_employee_id);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'shift_id', p_shift_id, 'effective_from', v_from));
end;
$$;

-- Audited per-day work-schedule exception (future dates only).
create or replace function public.save_schedule_exception(
  p_employee_id uuid, p_work_date date, p_kind text, p_shift_id uuid, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
begin
  if not hrms.can_master_data(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_work_date is null or p_work_date <= hrms.org_today(v_actor.org_id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Exceptions are set for future dates.',
      '{"work_date":"Must be after today"}'::jsonb);
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if p_kind not in ('extra_workday', 'day_off') or (p_kind = 'extra_workday' and p_shift_id is null) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose the exception type (and shift for extra workday).');
  end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if hrms.approved_leave_slots(p_employee_id, p_work_date) > 0 then
    perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT', 'The employee has approved leave that day.');
  end if;
  insert into hrms.schedule_exceptions (org_id, employee_id, work_date, kind, shift_id, reason, created_by)
  values (v_actor.org_id, p_employee_id, p_work_date, p_kind, case when p_kind = 'extra_workday' then p_shift_id end,
          v_reason, v_actor.employee_id)
  on conflict (employee_id, work_date) do update set kind = excluded.kind, shift_id = excluded.shift_id,
    reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  perform hrms.refresh_future_instances(v_actor.org_id, array[p_employee_id], p_work_date, p_work_date);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'schedule.exception_saved', 'employee', p_employee_id,
    jsonb_build_object('work_date', p_work_date, 'kind', p_kind, 'reason', v_reason), 'business', p_employee_id);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'work_date', p_work_date, 'kind', p_kind));
end;
$$;

-- -----------------------------------------------------------------------------
-- Holidays (S13): company calendar, separate from paid-leave entitlement
-- -----------------------------------------------------------------------------

create or replace function public.list_holidays(p_year integer, p_office_id uuid default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_manage boolean := hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor);
  v_year integer := coalesce(p_year, extract(year from hrms.org_today(v_actor.org_id))::integer);
  v_org hrms.organizations;
begin
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  return hrms.ok(jsonb_build_object(
    'year', v_year, 'target', v_org.holiday_target, 'can_manage', v_manage,
    'published_count', (select count(*) from hrms.holidays h where h.org_id = v_org.id and h.state = 'published'
                          and extract(year from h.holiday_date) = v_year),
    'holidays', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', h.id, 'date', h.holiday_date, 'name', h.name, 'state', h.state, 'version', h.version,
                    'office_id', h.office_id, 'office_name', o.name, 'source', h.source)
                    order by h.holiday_date), '[]'::jsonb)
                 from hrms.holidays h left join hrms.offices o on o.id = h.office_id
                 where h.org_id = v_org.id and extract(year from h.holiday_date) = v_year
                   and (h.state = 'published' or (v_manage and h.state = 'draft'))
                   and (p_office_id is null or h.office_id is null or h.office_id = p_office_id))));
end;
$$;

create or replace function public.save_holiday(p_id uuid, p_date date, p_name text, p_office_id uuid,
                                               p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.holidays;
  v_name text := hrms.clean_text(p_name, 120);
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_date is null or v_name is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Date and name are required.',
      jsonb_build_object('date', case when p_date is null then 'Required' end,
                         'name', case when v_name is null then 'Required' end));
  end if;
  if p_office_id is not null and not exists (select 1 from hrms.offices where id = p_office_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  begin
    if p_id is null then
      insert into hrms.holidays (org_id, office_id, holiday_date, name, state, created_by)
      values (v_actor.org_id, p_office_id, p_date, v_name, 'draft', v_actor.employee_id)
      returning * into v_row;
    else
      update hrms.holidays set holiday_date = p_date, name = v_name, office_id = p_office_id, version = version + 1
      where id = p_id and org_id = v_actor.org_id and state = 'draft' and version = p_expected_version
      returning * into v_row;
      if not found then
        perform hrms.raise_error('STALE_VERSION', 'Only unpublished drafts can be edited. Reload and try again.', null, true);
      end if;
    end if;
  exception when unique_violation then
    perform hrms.raise_error('VALIDATION_FAILED', 'A holiday already exists on this date for this scope.',
      '{"date":"Already has a holiday"}'::jsonb);
  end;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'holiday.draft_saved', 'holiday', v_row.id,
    jsonb_build_object('date', v_row.holiday_date, 'name', v_row.name));
  return hrms.ok(to_jsonb(v_row), v_row.version);
end;
$$;

create or replace function public.delete_holiday_draft(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  update hrms.holidays set state = 'withdrawn', version = version + 1
  where id = p_id and org_id = v_actor.org_id and state = 'draft';
  return hrms.ok(jsonb_build_object('removed', found));
end;
$$;

-- Publishes future holiday drafts. Affected future schedules are rebuilt and
-- leave that falls on a new holiday is reconciled exactly once: reserved days
-- are released, approved days credited back to their original allocation.
create or replace function public.publish_holidays(p_ids uuid[]) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_today date := hrms.org_today(v_actor.org_id);
  v_dates date[];
  v_ids uuid[];
  v_slot record;
  v_day date;
  v_reconciled integer := 0;
begin
  perform hrms.require_admin(v_actor);
  if exists (select 1 from hrms.holidays where id = any(p_ids) and org_id = v_actor.org_id and state = 'draft'
             and holiday_date <= v_today) then
    perform hrms.raise_error('VALIDATION_FAILED',
      'Holidays on today or past dates need an audited correction and cannot be published here.');
  end if;
  update hrms.holidays set state = 'published', published_at = now(), published_by = v_actor.employee_id,
                           version = version + 1
  where id = any(p_ids) and org_id = v_actor.org_id and state = 'draft';
  select array_agg(distinct holiday_date) into v_dates from hrms.holidays
  where id = any(p_ids) and org_id = v_actor.org_id and state = 'published';
  if v_dates is null then return hrms.ok(jsonb_build_object('published', 0)); end if;

  -- Rebuild only the affected future dates (instances with attendance are
  -- never touched; today/past were rejected above).
  v_ids := hrms.active_employee_ids(v_actor.org_id);
  perform set_config('hrms.schedule_refresh', 'on', true);
  delete from hrms.work_schedule_instances w
  where w.org_id = v_actor.org_id and w.shift_date = any(v_dates) and w.shift_date > v_today
    and not exists (select 1 from hrms.attendance_sessions s where s.schedule_instance_id = w.id);
  perform set_config('hrms.schedule_refresh', 'off', true);
  foreach v_day in array v_dates loop
    perform hrms.ensure_schedule_instances(v_actor.org_id, v_ids, v_day, v_day);
  end loop;

  for v_slot in
    select s.*, r.org_id as req_org
    from hrms.leave_day_slots s
    join hrms.requests r on r.id = s.request_id
    join hrms.work_schedule_instances w on w.employee_id = s.employee_id and w.shift_date = s.day
    where s.day = any(v_dates) and s.state in ('reserved', 'approved') and w.kind = 'holiday'
      and r.org_id = v_actor.org_id
  loop
    if v_slot.state = 'reserved' then
      update hrms.leave_reservations set state = 'released', released_at = now()
      where request_id = v_slot.request_id and day = v_slot.day and state = 'active';
    else
      insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id,
                                     request_id, created_by)
      select v_slot.org_id, lr.account_id, lr.allocation_id, 'credit_back', sum(lr.units)::integer,
             md5(v_slot.request_id::text || ':holiday:' || v_slot.day::text)::uuid, v_slot.request_id,
             v_actor.employee_id
      from hrms.leave_reservations lr
      where lr.request_id = v_slot.request_id and lr.day = v_slot.day and lr.state = 'converted'
      group by lr.account_id, lr.allocation_id
      on conflict (account_id, source_operation_id, entry_kind, allocation_id) do nothing;
      update hrms.leave_reservations set state = 'credited'
      where request_id = v_slot.request_id and day = v_slot.day and state = 'converted';
    end if;
    update hrms.leave_day_slots set state = 'released', released_at = now() where id = v_slot.id;
    update hrms.requests set units = greatest(0, units - case when v_slot.slot = 'FULL' then 2 else 1 end),
                             version = version + 1
    where id = v_slot.request_id;
    insert into hrms.approval_events (org_id, request_id, action, actor_id, reason)
    values (v_slot.org_id, v_slot.request_id, 'holiday_reconciled', v_actor.employee_id,
            format('%s became a company holiday; leave for that day was released.', v_slot.day));
    perform hrms.notify(v_slot.org_id, v_slot.employee_id, 'leave.holiday_reconciled', 'Leave balance adjusted',
      'A new company holiday falls within your leave. Your balance was updated.', '/requests/' || v_slot.request_id,
      null, md5(v_slot.id::text || ':holiday')::uuid);
    v_reconciled := v_reconciled + 1;
  end loop;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'holiday.published', 'organization', v_actor.org_id,
    jsonb_build_object('holiday_ids', to_jsonb(p_ids), 'leave_days_reconciled', v_reconciled));
  return hrms.ok(jsonb_build_object('published', cardinality(v_dates), 'leave_days_reconciled', v_reconciled));
end;
$$;

-- -----------------------------------------------------------------------------
-- Leave types and policies (S32)
-- -----------------------------------------------------------------------------

create or replace function public.list_leave_types(p_include_inactive boolean default false) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'code', t.code, 'name', t.name, 'paid', t.paid, 'half_day_allowed', t.half_day_allowed,
      'requires_attachment', t.requires_attachment, 'attachment_class', t.attachment_class,
      'max_consecutive_days', t.max_consecutive_days, 'advance_notice_days', t.advance_notice_days,
      'backdate_days', t.backdate_days, 'active', t.active, 'version', t.version) order by t.name), '[]'::jsonb)
    from hrms.leave_types t
    where t.org_id = v_actor.org_id and (t.active or (p_include_inactive and hrms.can_draft_policy(v_actor)))));
end;
$$;

create or replace function public.save_leave_type(
  p_id uuid, p_code text, p_name text, p_paid boolean, p_half_day_allowed boolean, p_requires_attachment boolean,
  p_attachment_class text, p_max_consecutive_days integer, p_advance_notice_days integer, p_backdate_days integer,
  p_active boolean, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.leave_types;
begin
  perform hrms.require_admin(v_actor);
  if upper(coalesce(p_code, '')) !~ '^[A-Z0-9_]{2,16}$' or hrms.clean_text(p_name, 60) is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Code and name are required.',
      '{"code":"2–16 letters/digits","name":"Required"}'::jsonb);
  end if;
  begin
    if p_id is null then
      insert into hrms.leave_types (org_id, code, name, paid, half_day_allowed, requires_attachment, attachment_class,
        max_consecutive_days, advance_notice_days, backdate_days, active)
      values (v_actor.org_id, upper(p_code), hrms.clean_text(p_name, 60), coalesce(p_paid, true),
        coalesce(p_half_day_allowed, true), coalesce(p_requires_attachment, false), coalesce(p_attachment_class, 'general'),
        p_max_consecutive_days, coalesce(p_advance_notice_days, 0), coalesce(p_backdate_days, 7), coalesce(p_active, true))
      returning * into v_row;
    else
      update hrms.leave_types set name = hrms.clean_text(p_name, 60), paid = coalesce(p_paid, paid),
        half_day_allowed = coalesce(p_half_day_allowed, half_day_allowed),
        requires_attachment = coalesce(p_requires_attachment, requires_attachment),
        attachment_class = coalesce(p_attachment_class, attachment_class), max_consecutive_days = p_max_consecutive_days,
        advance_notice_days = coalesce(p_advance_notice_days, advance_notice_days),
        backdate_days = coalesce(p_backdate_days, backdate_days), active = coalesce(p_active, active),
        version = version + 1
      where id = p_id and org_id = v_actor.org_id and version = p_expected_version
      returning * into v_row;
      if not found then perform hrms.raise_error('STALE_VERSION', 'Reload and try again.', null, true); end if;
    end if;
  exception when unique_violation then
    perform hrms.raise_error('VALIDATION_FAILED', 'This leave code exists.', '{"code":"Already exists"}'::jsonb);
  end;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave_type.saved', 'leave_type', v_row.id,
    to_jsonb(v_row) - 'created_at' - 'updated_at');
  return hrms.ok(to_jsonb(v_row), v_row.version);
end;
$$;

create or replace function public.list_leave_policies(p_leave_year integer default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_year integer;
begin
  if not hrms.can_draft_policy(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_year := coalesce(p_leave_year, hrms.leave_year_of(v_org.leave_year_start_month, hrms.org_today(v_org.id)));
  return hrms.ok(jsonb_build_object('leave_year', v_year, 'leave_year_start_month', v_org.leave_year_start_month,
    'policies', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'leave_type', jsonb_build_object('id', t.id, 'code', t.code, 'name', t.name, 'paid', t.paid),
        'annual_units', p.annual_units, 'carry_cap_units', p.carry_cap_units,
        'carry_expiry_months', p.carry_expiry_months, 'prorata', p.prorata, 'state', p.state,
        'published_at', p.published_at) order by t.name), '[]'::jsonb)
      from hrms.leave_policies p join hrms.leave_types t on t.id = p.leave_type_id
      where p.org_id = v_org.id and p.leave_year = v_year)));
end;
$$;

create or replace function public.save_leave_policy(
  p_leave_type_id uuid, p_leave_year integer, p_annual_units integer, p_carry_cap_units integer,
  p_carry_expiry_months integer, p_prorata boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.leave_policies;
begin
  if not hrms.can_draft_policy(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.leave_types where id = p_leave_type_id and org_id = v_actor.org_id and paid) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a paid leave type.', '{"leave_type_id":"Paid type"}'::jsonb);
  end if;
  if coalesce(p_annual_units, -1) not between 0 and 730 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Entitlement is in half-day units (0–730).',
      '{"annual_units":"0–730 half-days"}'::jsonb);
  end if;
  insert into hrms.leave_policies (org_id, leave_type_id, leave_year, annual_units, carry_cap_units,
                                   carry_expiry_months, prorata, created_by)
  values (v_actor.org_id, p_leave_type_id, p_leave_year, p_annual_units, coalesce(p_carry_cap_units, 0),
          p_carry_expiry_months, coalesce(p_prorata, false), v_actor.employee_id)
  on conflict (leave_type_id, leave_year) do update set annual_units = excluded.annual_units,
    carry_cap_units = excluded.carry_cap_units, carry_expiry_months = excluded.carry_expiry_months,
    prorata = excluded.prorata
  where hrms.leave_policies.state = 'draft'
  returning * into v_row;
  if v_row.id is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'This year''s policy is already published.');
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave_policy.draft_saved', 'leave_policy', v_row.id,
    to_jsonb(v_row) - 'created_at');
  return hrms.ok(to_jsonb(v_row));
end;
$$;

-- Publishes a leave-year policy: allocations for every active employee (set
-- based, idempotent per employee) plus capped carry-forward moved exactly
-- once from the previous year (expired there, allocated here).
create or replace function public.publish_leave_policy(p_policy_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_pol hrms.leave_policies;
  v_org hrms.organizations;
  v_start date;
  v_emp uuid;
  v_count integer := 0;
begin
  perform hrms.require_admin(v_actor);
  select * into v_pol from hrms.leave_policies where id = p_policy_id and org_id = v_actor.org_id for update;
  if not found or v_pol.state <> 'draft' then perform hrms.raise_error('VALIDATION_FAILED', 'Not a draft policy.'); end if;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_start := make_date(v_pol.leave_year, v_org.leave_year_start_month, 1);
  update hrms.leave_policies set state = 'published', published_at = now(), published_by = v_actor.employee_id
  where id = v_pol.id;

  foreach v_emp in array hrms.active_employee_ids(v_org.id) loop
    perform hrms.allocate_policy_for_employee(v_pol.id, v_emp, v_actor.employee_id);
    v_count := v_count + 1;
  end loop;

  perform hrms.audit(v_org.id, v_actor.employee_id, 'leave_policy.published', 'leave_policy', v_pol.id,
    jsonb_build_object('leave_year', v_pol.leave_year, 'employees', v_count, 'annual_units', v_pol.annual_units));
  return public.list_leave_policies(v_pol.leave_year);
end;
$$;

create or replace function hrms.allocate_policy_for_employee(p_policy_id uuid, p_employee uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pol hrms.leave_policies;
  v_org hrms.organizations;
  v_emp hrms.employees;
  v_start date;
  v_acc uuid;
  v_prev_acc uuid;
  v_units integer;
  v_months integer;
  v_carry integer;
  v_left integer;
  v_take integer;
  v_alloc uuid;
  v_op uuid := md5(p_policy_id::text || ':' || p_employee::text)::uuid;
  v_carry_op uuid := md5(p_policy_id::text || ':carry:' || p_employee::text)::uuid;
  r record;
begin
  select * into v_pol from hrms.leave_policies where id = p_policy_id;
  select * into v_org from hrms.organizations where id = v_pol.org_id;
  select * into v_emp from hrms.employees where id = p_employee;
  v_start := make_date(v_pol.leave_year, v_org.leave_year_start_month, 1);
  insert into hrms.leave_accounts (org_id, employee_id, leave_type_id, leave_year)
  values (v_org.id, p_employee, v_pol.leave_type_id, v_pol.leave_year)
  on conflict (employee_id, leave_type_id, leave_year) do nothing;
  select id into v_acc from hrms.leave_accounts
  where employee_id = p_employee and leave_type_id = v_pol.leave_type_id and leave_year = v_pol.leave_year;

  v_units := v_pol.annual_units;
  if v_pol.prorata and v_emp.join_date > v_start then
    v_months := 12 - ((extract(year from v_emp.join_date)::integer - v_pol.leave_year) * 12
                      + extract(month from v_emp.join_date)::integer - v_org.leave_year_start_month);
    v_units := greatest(0, least(12, v_months)) * v_pol.annual_units / 12;
  end if;
  insert into hrms.leave_allocations (org_id, account_id, source, valid_from, valid_to, policy_id, operation_id, reason,
                                      created_by)
  values (v_org.id, v_acc, case when v_units < v_pol.annual_units then 'prorata' else 'annual' end, v_start,
          (v_start + interval '1 year')::date, v_pol.id, v_op, 'Published policy allocation', p_actor)
  on conflict (account_id, operation_id) do nothing
  returning id into v_alloc;
  if v_alloc is not null and v_units > 0 then
    insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id, created_by)
    values (v_org.id, v_acc, v_alloc, 'allocate', v_units, v_op, p_actor);
  end if;

  -- Carry forward from the previous leave year, capped, moved exactly once.
  if v_pol.carry_cap_units > 0 then
    select id into v_prev_acc from hrms.leave_accounts
    where employee_id = p_employee and leave_type_id = v_pol.leave_type_id and leave_year = v_pol.leave_year - 1
    for update;
    if v_prev_acc is not null and not exists (
         select 1 from hrms.leave_allocations where account_id = v_acc and operation_id = v_carry_op) then
      select coalesce(sum(av.available), 0) into v_carry from hrms.allocation_availability(array[v_prev_acc]) av;
      v_carry := least(greatest(v_carry, 0), v_pol.carry_cap_units);
      if v_carry > 0 then
        v_left := v_carry;
        for r in select av.* from hrms.allocation_availability(array[v_prev_acc]) av
                 where av.available > 0 order by av.valid_to, av.allocation_id loop
          exit when v_left = 0;
          v_take := least(v_left, r.available);
          insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id, created_by)
          values (v_org.id, v_prev_acc, r.allocation_id, 'expire', -v_take, v_carry_op, p_actor);
          v_left := v_left - v_take;
        end loop;
        insert into hrms.leave_allocations (org_id, account_id, source, valid_from, valid_to, policy_id, operation_id,
                                            reason, created_by)
        values (v_org.id, v_acc, 'carry_forward', v_start,
                case when v_pol.carry_expiry_months is null then (v_start + interval '1 year')::date
                     else (v_start + make_interval(months => v_pol.carry_expiry_months))::date end,
                v_pol.id, v_carry_op, 'Carried forward from previous leave year', p_actor)
        returning id into v_alloc;
        insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id, created_by)
        values (v_org.id, v_acc, v_alloc, 'allocate', v_carry, v_carry_op, p_actor);
      end if;
    end if;
  end if;
end;
$$;

-- Replace the provisioning helper to share the same allocation logic.
create or replace function hrms.allocate_published_leave(p_org uuid, p_employee uuid) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org hrms.organizations;
  v_pol record;
begin
  select * into v_org from hrms.organizations where id = p_org;
  for v_pol in
    select p.id from hrms.leave_policies p join hrms.leave_types t on t.id = p.leave_type_id
    where p.org_id = p_org and p.state = 'published' and t.active and t.paid
      and p.leave_year = hrms.leave_year_of(v_org.leave_year_start_month, hrms.org_today(p_org))
  loop
    perform hrms.allocate_policy_for_employee(v_pol.id, p_employee, null);
  end loop;
end;
$$;

-- Manual balance adjustment (Admin), audited, as its own allocation.
create or replace function public.adjust_leave_balance(
  p_employee_id uuid, p_leave_type_id uuid, p_leave_year integer, p_units integer, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_acc uuid;
  v_alloc uuid;
  v_op uuid := gen_random_uuid();
  v_start date;
  v_reason text := hrms.clean_text(p_reason, 500);
  v_avail integer;
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null or coalesce(p_units, 0) = 0 or abs(p_units) > 730 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Units (non-zero) and a reason are required.');
  end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id)
     or not exists (select 1 from hrms.leave_types where id = p_leave_type_id and org_id = v_actor.org_id and paid) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_start := make_date(p_leave_year, v_org.leave_year_start_month, 1);
  insert into hrms.leave_accounts (org_id, employee_id, leave_type_id, leave_year)
  values (v_org.id, p_employee_id, p_leave_type_id, p_leave_year)
  on conflict (employee_id, leave_type_id, leave_year) do nothing;
  select id into v_acc from hrms.leave_accounts
  where employee_id = p_employee_id and leave_type_id = p_leave_type_id and leave_year = p_leave_year for update;
  if p_units > 0 then
    insert into hrms.leave_allocations (org_id, account_id, source, valid_from, valid_to, operation_id, reason, created_by)
    values (v_org.id, v_acc, 'manual', v_start, (v_start + interval '1 year')::date, v_op, v_reason, v_actor.employee_id)
    returning id into v_alloc;
    insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id, created_by)
    values (v_org.id, v_acc, v_alloc, 'allocate', p_units, v_op, v_actor.employee_id);
  else
    -- Deduct from the latest-expiring allocations without going negative.
    select coalesce(sum(available), 0) into v_avail from hrms.allocation_availability(array[v_acc]);
    if v_avail < -p_units then
      perform hrms.raise_error('INSUFFICIENT_BALANCE', 'The deduction exceeds the available balance.');
    end if;
    insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id, created_by)
    select v_org.id, v_acc, av.allocation_id, 'adjust', -least(av.available, -p_units), v_op, v_actor.employee_id
    from hrms.allocation_availability(array[v_acc]) av where av.available > 0
    order by av.valid_to desc limit 1;
  end if;
  perform hrms.audit(v_org.id, v_actor.employee_id, 'leave.balance_adjusted', 'employee', p_employee_id,
    jsonb_build_object('leave_type_id', p_leave_type_id, 'leave_year', p_leave_year, 'units', p_units,
                       'reason', v_reason), 'business', p_employee_id);
  return hrms.ok(jsonb_build_object('employee_id', p_employee_id, 'units', p_units));
end;
$$;

-- -----------------------------------------------------------------------------
-- Approval routes (S32) and access grants (S33)
-- -----------------------------------------------------------------------------

create or replace function public.list_approval_routes() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.require_admin(v_actor);
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'team', jsonb_build_object('id', t.id, 'name', t.name),
      'routes', (select coalesce(jsonb_agg(jsonb_build_object(
          'kind', k.kind, 'route_id', r.id, 'mode', r.reviewer_mode,
          'hr_reviewer', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                          from hrms.employees e where e.id = r.hr_reviewer_id),
          'fallback', (select jsonb_build_object('id', e.id, 'name', e.full_name, 'code', e.employee_code)
                       from hrms.employees e where e.id = r.fallback_reviewer_id)) order by k.kind), '[]'::jsonb)
        from (values ('leave'), ('correction')) k(kind)
        left join hrms.approval_routes r on r.team_id = t.id and r.request_kind = k.kind and r.superseded_at is null))
      order by t.name), '[]'::jsonb)
    from hrms.teams t where t.org_id = v_actor.org_id and t.active));
end;
$$;

create or replace function public.set_approval_route(
  p_team_id uuid, p_kind text, p_mode text, p_hr_reviewer_id uuid, p_fallback_reviewer_id uuid, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.require_admin(v_actor);
  if p_kind not in ('leave', 'correction') or p_mode not in ('manager', 'hr') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose Manager or HR.');
  end if;
  if not exists (select 1 from hrms.teams where id = p_team_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_mode = 'hr' and (p_hr_reviewer_id is null or not exists (
       select 1 from hrms.employees e where e.id = p_hr_reviewer_id and e.org_id = v_actor.org_id and e.status = 'active'
         and hrms.employee_roles(e.id) && array['hr', 'admin'])) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose an active HR or Admin reviewer.',
      '{"hr_reviewer_id":"HR/Admin required"}'::jsonb);
  end if;
  if p_fallback_reviewer_id is not null and not exists (
       select 1 from hrms.employees e where e.id = p_fallback_reviewer_id and e.org_id = v_actor.org_id
         and e.status = 'active' and hrms.employee_roles(e.id) && array['manager', 'hr', 'admin']) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Fallback must be an active Manager, HR or Admin.',
      '{"fallback_reviewer_id":"Not eligible"}'::jsonb);
  end if;
  -- In-flight requests keep their snapshot; only new requests use this route.
  update hrms.approval_routes set superseded_at = now()
  where team_id = p_team_id and request_kind = p_kind and superseded_at is null;
  insert into hrms.approval_routes (org_id, team_id, request_kind, reviewer_mode, hr_reviewer_id, fallback_reviewer_id,
                                    created_by)
  values (v_actor.org_id, p_team_id, p_kind, p_mode, case when p_mode = 'hr' then p_hr_reviewer_id end,
          p_fallback_reviewer_id, v_actor.employee_id);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'approval_route.set', 'team', p_team_id,
    jsonb_build_object('kind', p_kind, 'mode', p_mode, 'hr_reviewer_id', p_hr_reviewer_id,
                       'fallback_reviewer_id', p_fallback_reviewer_id, 'reason', p_reason));
  return public.list_approval_routes();
end;
$$;

create or replace function public.list_access_grants() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.require_admin(v_actor);
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name, 'status', e.status),
      'roles', to_jsonb(hrms.employee_roles(e.id)),
      'permissions', (select coalesce(jsonb_agg(g.permission order by g.permission), '[]'::jsonb)
                      from hrms.permission_grants g where g.employee_id = e.id and g.revoked_at is null))
      order by e.full_name), '[]'::jsonb)
    from hrms.employees e where e.org_id = v_actor.org_id and e.status <> 'pending'));
end;
$$;

-- Role elevation needs a recent password reauthentication (5 minutes).
create or replace function public.grant_role(p_employee_id uuid, p_role text, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
begin
  perform hrms.require_admin(v_actor);
  if p_role not in ('manager', 'hr', 'admin') then perform hrms.raise_error('VALIDATION_FAILED', 'Unknown role.'); end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id and status = 'active') then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_role in ('hr', 'admin') then
    perform hrms.require_reauth(v_actor, 'role.elevate', p_employee_id, true);
  end if;
  if not (p_role = any(hrms.employee_roles(p_employee_id))) then
    insert into hrms.role_grants (org_id, employee_id, role, granted_by, reason)
    values (v_actor.org_id, p_employee_id, p_role, v_actor.employee_id, v_reason);
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'role.granted', 'employee', p_employee_id,
    jsonb_build_object('role', p_role, 'reason', v_reason), 'security', p_employee_id);
  return public.list_access_grants();
end;
$$;

create or replace function public.revoke_role(p_employee_id uuid, p_role text, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
  v_admins integer;
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if p_role = 'admin' then
    -- Serialise last-Admin checks.
    perform 1 from hrms.organizations where id = v_actor.org_id for update;
    select count(distinct g.employee_id) into v_admins
    from hrms.role_grants g join hrms.employees e on e.id = g.employee_id
    where e.org_id = v_actor.org_id and e.status = 'active' and g.role = 'admin' and g.revoked_at is null
      and g.effective_from <= now();
    if v_admins <= 1 then
      perform hrms.raise_error('VALIDATION_FAILED', 'At least one active Admin must remain.');
    end if;
  end if;
  update hrms.role_grants set revoked_at = now(), revoked_by = v_actor.employee_id
  where employee_id = p_employee_id and role = p_role and revoked_at is null
    and exists (select 1 from hrms.employees e where e.id = p_employee_id and e.org_id = v_actor.org_id);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'role.revoked', 'employee', p_employee_id,
    jsonb_build_object('role', p_role, 'reason', v_reason), 'security', p_employee_id);
  return public.list_access_grants();
end;
$$;

create or replace function public.set_permission(p_employee_id uuid, p_permission text, p_enabled boolean, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_reason text := hrms.clean_text(p_reason, 500);
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_enabled then
    if p_permission in ('payroll.manage', 'documents.medical') then
      perform hrms.require_reauth(v_actor, 'role.elevate', p_employee_id, true);
    end if;
    if not exists (select 1 from hrms.permission_grants where employee_id = p_employee_id and permission = p_permission
                   and revoked_at is null) then
      insert into hrms.permission_grants (org_id, employee_id, permission, granted_by, reason)
      values (v_actor.org_id, p_employee_id, p_permission, v_actor.employee_id, v_reason);
    end if;
  else
    update hrms.permission_grants set revoked_at = now(), revoked_by = v_actor.employee_id
    where employee_id = p_employee_id and permission = p_permission and revoked_at is null;
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_enabled then 'permission.granted' else 'permission.revoked' end, 'employee', p_employee_id,
    jsonb_build_object('permission', p_permission, 'reason', v_reason), 'security', p_employee_id);
  return public.list_access_grants();
end;
$$;

select hrms.apply_api_grants();
