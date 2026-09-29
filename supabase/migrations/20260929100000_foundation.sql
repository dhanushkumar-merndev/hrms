-- =============================================================================
-- HRMS foundation: schemas, helpers, organisation, identity, roles, audit.
--
-- Security model (see architecture.md §2):
--   * All tables live in schema `hrms`, which is NOT exposed by the Data API
--     (PostgREST/GraphQL only serve `public`). RLS is enabled on every table
--     with no client policies (deny by default) as defence in depth.
--   * Clients reach data only through `public.*` RPC functions. Each is
--     SECURITY DEFINER with an empty search_path, fully qualified names, and
--     starts by resolving the actor through hrms.current_actor(), which enforces
--     account status, provisioning, credential holds, first-password change and
--     original-session validity against auth.sessions.
--   * `public.internal_*` functions are executable only by service_role and are
--     called by Edge Functions after they verify the caller themselves.
-- =============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists btree_gist with schema extensions;
create extension if not exists postgis with schema extensions;

create schema if not exists hrms;
revoke all on schema hrms from public;
revoke all on schema hrms from anon, authenticated;
grant usage on schema hrms to service_role;

-- Functions are executable by PUBLIC by default in Postgres; Supabase also
-- grants API roles default privileges in `public`. Undo both for everything
-- this project creates; each client RPC is granted explicitly at the end.
alter default privileges in schema hrms revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema hrms revoke all on tables from public;

-- -----------------------------------------------------------------------------
-- Error and request helpers
-- -----------------------------------------------------------------------------

-- Raises a client-safe error. PostgREST returns {code:'P0001', message:<CODE>,
-- details:<json>, hint:'retryable'|''}; the app maps `message` to its error enum.
create or replace function hrms.raise_error(
  p_code text,
  p_message text default null,
  p_field_errors jsonb default null,
  p_retryable boolean default false
) returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_code,
    detail = jsonb_build_object(
      'message', coalesce(p_message, p_code),
      'field_errors', coalesce(p_field_errors, '{}'::jsonb),
      'retryable', p_retryable,
      'request_id', hrms.request_id()
    )::text,
    hint = case when p_retryable then 'retryable' else '' end;
end;
$$;

-- Stable per-transaction request id: the client's x-request-id header when it
-- is a valid UUID, else a generated one. Returned in responses and audit rows.
create or replace function hrms.request_id() returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v text := nullif(current_setting('hrms.request_id', true), '');
begin
  if v is null then
    begin
      v := nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-request-id';
    exception when others then
      v := null;
    end;
    if v is null or v !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v := gen_random_uuid()::text;
    end if;
    perform set_config('hrms.request_id', v, true);
  end if;
  return v::uuid;
end;
$$;

-- Standard success envelope {data, version, request_id}.
create or replace function hrms.ok(p_data jsonb, p_version integer default null)
returns jsonb
language sql
set search_path = ''
as $$
  select jsonb_build_object('data', p_data, 'version', p_version, 'request_id', hrms.request_id());
$$;

create or replace function hrms.forbid_mutation() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('hrms.retention_purge', true), '') = 'on'
     and tg_table_name in ('security_events', 'rate_limit_buckets') then
    return old;
  end if;
  raise exception 'HRMS: % on %.% is not allowed (append-only)', tg_op, tg_table_schema, tg_table_name
    using errcode = '42501';
end;
$$;

create or replace function hrms.touch_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Normalises an employee login code: trim + uppercase, allowlist [A-Z0-9-],
-- length 3–32. Returns null when invalid.
create or replace function hrms.normalize_employee_code(p_code text) returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when upper(btrim(coalesce(p_code, ''))) ~ '^[A-Z0-9-]{3,32}$' then upper(btrim(p_code))
    else null
  end;
$$;

-- Sanitises free text for storage: trims, strips control characters, bounds length.
create or replace function hrms.clean_text(p_text text, p_max integer) returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(left(btrim(regexp_replace(coalesce(p_text, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')), p_max), '');
$$;

-- -----------------------------------------------------------------------------
-- Organisation and versioned settings
-- -----------------------------------------------------------------------------

create table hrms.organizations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z0-9_-]{2,32}$'),
  name text not null check (char_length(name) between 1 and 120),
  timezone text not null default 'Asia/Kolkata',
  annual_start_month smallint not null default 1 check (annual_start_month in (1, 4)),
  leave_year_start_month smallint not null default 1 check (leave_year_start_month between 1 and 12),
  active_employee_cap integer not null default 20 check (active_employee_cap between 1 and 10000),
  holiday_target integer not null default 12 check (holiday_target between 0 and 60),
  support_contact text check (char_length(support_contact) <= 200),
  storage_budget_bytes bigint not null default 1000000000 check (storage_budget_bytes > 0),
  storage_alert_percents smallint[] not null default '{70,85,95}',
  strict_geofence boolean not null default false,
  -- Punch keys must require a fresh fingerprint/face confirmation on the
  -- employee's own phone for every signature (verified via attestation).
  require_biometric_punch boolean not null default true,
  setup_published_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger organizations_touch before update on hrms.organizations
  for each row execute function hrms.touch_updated_at();

create table hrms.settings_versions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  version integer not null,
  snapshot jsonb not null,
  changed_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  unique (org_id, version)
);
create trigger settings_versions_append_only before update or delete on hrms.settings_versions
  for each row execute function hrms.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Departments, teams, employees
-- -----------------------------------------------------------------------------

create table hrms.departments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  name text not null check (char_length(name) between 1 and 80),
  active boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name),
  unique (org_id, id)
);
create trigger departments_touch before update on hrms.departments
  for each row execute function hrms.touch_updated_at();

create table hrms.teams (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  department_id uuid,
  name text not null check (char_length(name) between 1 and 80),
  active boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name),
  unique (org_id, id),
  foreign key (org_id, department_id) references hrms.departments(org_id, id) on delete restrict
);
create trigger teams_touch before update on hrms.teams
  for each row execute function hrms.touch_updated_at();

create table hrms.employees (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  employee_code text not null check (employee_code ~ '^[A-Z0-9-]{3,32}$'),
  full_name text not null check (char_length(full_name) between 1 and 200),
  designation text check (char_length(designation) <= 120),
  department_id uuid,
  business_email text check (char_length(business_email) <= 200),
  business_phone text check (char_length(business_phone) <= 40),
  avatar_file_version_id uuid,
  join_date date not null,
  end_date date,
  status text not null default 'pending' check (status in ('pending', 'active', 'inactive')),
  provisioning_state text not null default 'pending'
    check (provisioning_state in ('pending', 'auth_created', 'complete')),
  provisioning_operation_id uuid unique,
  auth_user_id uuid unique,
  auth_alias text unique,
  must_change_password boolean not null default true,
  credentials_valid_after timestamptz not null default now(),
  credential_hold_operation_id uuid,
  alias_anomaly_at timestamptz,
  version integer not null default 1,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, employee_code),
  unique (org_id, id),
  check (end_date is null or end_date >= join_date),
  foreign key (org_id, department_id) references hrms.departments(org_id, id) on delete restrict
);
create index employees_org_status_idx on hrms.employees (org_id, status, id);
create index employees_name_idx on hrms.employees (org_id, lower(full_name) text_pattern_ops);
create trigger employees_touch before update on hrms.employees
  for each row execute function hrms.touch_updated_at();

-- auth_user_id is immutable once linked; an Auth alias change cannot relink.
create or replace function hrms.employees_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.auth_user_id is not null and new.auth_user_id is distinct from old.auth_user_id then
    raise exception 'HRMS: auth_user_id is immutable once linked' using errcode = '42501';
  end if;
  if new.employee_code is distinct from old.employee_code then
    raise exception 'HRMS: employee_code is immutable' using errcode = '42501';
  end if;
  if new.org_id is distinct from old.org_id then
    raise exception 'HRMS: org_id is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger employees_guard before update on hrms.employees
  for each row execute function hrms.employees_guard();

create table hrms.employee_private_details (
  employee_id uuid primary key references hrms.employees(id) on delete restrict,
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  personal_email text check (char_length(personal_email) <= 200),
  personal_phone text check (char_length(personal_phone) <= 40),
  address text check (char_length(address) <= 500),
  emergency_contact_name text check (char_length(emergency_contact_name) <= 120),
  emergency_contact_phone text check (char_length(emergency_contact_phone) <= 40),
  date_of_birth date,
  version integer not null default 1,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Team membership: one primary team per employee at a time (effective dated,
-- inclusive start / exclusive end).
create table hrms.team_memberships (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  team_id uuid not null,
  effective_from date not null,
  effective_to date,
  created_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, team_id) references hrms.teams(org_id, id) on delete restrict,
  constraint team_memberships_no_overlap exclude using gist (
    employee_id with =, daterange(effective_from, effective_to, '[)') with &&
  )
);
create index team_memberships_team_idx on hrms.team_memberships (team_id, effective_from, effective_to);
create index team_memberships_emp_idx on hrms.team_memberships (employee_id, effective_from, effective_to);

-- Team manager: one manager per team at a time; a manager may manage several teams.
create table hrms.team_managers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  team_id uuid not null,
  manager_id uuid not null,
  effective_from date not null,
  effective_to date,
  created_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  foreign key (org_id, team_id) references hrms.teams(org_id, id) on delete restrict,
  foreign key (org_id, manager_id) references hrms.employees(org_id, id) on delete restrict,
  constraint team_managers_no_overlap exclude using gist (
    team_id with =, daterange(effective_from, effective_to, '[)') with &&
  )
);
create index team_managers_manager_idx on hrms.team_managers (manager_id, effective_to, team_id);

-- -----------------------------------------------------------------------------
-- Roles and permissions (server-owned; never read from Auth metadata)
-- -----------------------------------------------------------------------------

create table hrms.role_grants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  role text not null check (role in ('manager', 'hr', 'admin')),
  effective_from timestamptz not null default now(),
  revoked_at timestamptz,
  granted_by uuid,
  revoked_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (revoked_at is null or revoked_at >= effective_from),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  constraint role_grants_no_overlap exclude using gist (
    employee_id with =, role with =, tstzrange(effective_from, revoked_at, '[)') with &&
  )
);
create index role_grants_emp_idx on hrms.role_grants (employee_id) where revoked_at is null;

create table hrms.permission_grants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  permission text not null check (permission in (
    'payroll.manage', 'documents.medical', 'hr.employees.provision', 'hr.master_data',
    'policy.draft', 'audit.scoped', 'announcements.publish'
  )),
  effective_from timestamptz not null default now(),
  revoked_at timestamptz,
  granted_by uuid,
  revoked_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (revoked_at is null or revoked_at >= effective_from),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  constraint permission_grants_no_overlap exclude using gist (
    employee_id with =, permission with =, tstzrange(effective_from, revoked_at, '[)') with &&
  )
);
create index permission_grants_emp_idx on hrms.permission_grants (employee_id) where revoked_at is null;

-- Permission bundles per role. Admin holds every permission ('*').
-- Payroll and medical documents are never implied by the HR role: they need
-- an explicit permission grant (architecture §3.2).
create or replace function hrms.role_bundle(p_role text) returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'admin' then array['*']
    when 'hr' then array[
      'hr.directory', 'hr.employees.view', 'hr.employees.provision', 'hr.master_data',
      'policy.draft', 'reports.org', 'audit.scoped', 'announcements.publish', 'approvals.review'
    ]
    when 'manager' then array['reports.team', 'approvals.review']
    else array[]::text[]
  end;
$$;

-- -----------------------------------------------------------------------------
-- Credential operations, reauthentication grants, rate limits
-- -----------------------------------------------------------------------------

create table hrms.credential_operations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  operation_id uuid not null unique,
  kind text not null check (kind in ('provision', 'self_change', 'admin_reset')),
  issued_by uuid,
  stage text not null default 'started'
    check (stage in ('started', 'auth_updated', 'finalized', 'failed', 'abandoned')),
  barrier_at timestamptz,
  expires_at timestamptz not null default now() + interval '15 minutes',
  last_error text check (char_length(last_error) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create index credential_operations_emp_idx on hrms.credential_operations (employee_id, created_at desc);
create trigger credential_operations_touch before update on hrms.credential_operations
  for each row execute function hrms.touch_updated_at();

create table hrms.reauthentication_grants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  session_id uuid not null,
  action text not null check (action in (
    'role.elevate', 'archive.cleanup', 'export.bulk_salary', 'export.annual', 'credentials.reset_admin'
  )),
  target_id uuid,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  check (expires_at > issued_at and expires_at <= issued_at + interval '5 minutes')
);
create index reauthentication_grants_lookup on hrms.reauthentication_grants (employee_id, action, expires_at desc);

create table hrms.rate_limit_buckets (
  bucket text not null,
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (bucket, window_start)
);

-- Fixed-window counter. Returns the hit count after recording this hit.
create or replace function hrms.rate_limit_hit(p_bucket text, p_window interval)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_start timestamptz := date_bin(p_window, clock_timestamp(), timestamptz '2000-01-01 00:00:00+00');
  v_hits integer;
begin
  insert into hrms.rate_limit_buckets as b (bucket, window_start, hits)
  values (p_bucket, v_start, 1)
  on conflict (bucket, window_start) do update set hits = b.hits + 1
  returning b.hits into v_hits;
  return v_hits;
end;
$$;

create or replace function hrms.rate_limit_count(p_bucket text, p_window interval)
returns integer
language sql
stable
set search_path = ''
as $$
  select coalesce((
    select hits from hrms.rate_limit_buckets
    where bucket = p_bucket
      and window_start = date_bin(p_window, clock_timestamp(), timestamptz '2000-01-01 00:00:00+00')
  ), 0);
$$;

-- -----------------------------------------------------------------------------
-- Audit log and security events (append-only for application roles)
-- -----------------------------------------------------------------------------

create table hrms.audit_logs (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  actor_employee_id uuid,
  action text not null check (char_length(action) <= 80),
  target_type text check (char_length(target_type) <= 40),
  target_id uuid,
  target_employee_id uuid,
  request_id uuid,
  changes jsonb,
  classification text not null default 'business'
    check (classification in ('business', 'security', 'access', 'system')),
  created_at timestamptz not null default now()
);
create index audit_logs_org_time_idx on hrms.audit_logs (org_id, created_at desc, id desc);
create index audit_logs_target_idx on hrms.audit_logs (target_id) where target_id is not null;
create index audit_logs_target_emp_idx on hrms.audit_logs (target_employee_id, created_at desc)
  where target_employee_id is not null;
create trigger audit_logs_append_only before update or delete on hrms.audit_logs
  for each row execute function hrms.forbid_mutation();
create trigger audit_logs_no_truncate before truncate on hrms.audit_logs
  for each statement execute function hrms.forbid_mutation();

create table hrms.security_events (
  id bigint generated always as identity primary key,
  org_id uuid,
  employee_id uuid,
  kind text not null check (char_length(kind) <= 60),
  detail jsonb,
  ip_hash text,
  created_at timestamptz not null default now()
);
create index security_events_org_time_idx on hrms.security_events (org_id, created_at desc, id desc);
create index security_events_emp_idx on hrms.security_events (employee_id, created_at desc);
create trigger security_events_append_only before update or delete on hrms.security_events
  for each row execute function hrms.forbid_mutation();

-- Removes keys that must never be persisted in audit/security payloads.
create or replace function hrms.redact(p jsonb) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p is null then null else
    p - array['password', 'new_password', 'current_password', 'temporary_password', 'token',
              'access_token', 'refresh_token', 'signed_url', 'url', 'proof', 'signature',
              'attestation', 'nonce', 'secret']
  end;
$$;

create or replace function hrms.audit(
  p_org_id uuid,
  p_actor uuid,
  p_action text,
  p_target_type text,
  p_target_id uuid,
  p_changes jsonb default null,
  p_classification text default 'business',
  p_target_employee uuid default null
) returns void
language sql
set search_path = ''
as $$
  insert into hrms.audit_logs (org_id, actor_employee_id, action, target_type, target_id,
                               target_employee_id, request_id, changes, classification)
  values (p_org_id, p_actor, p_action, p_target_type, p_target_id, p_target_employee,
          hrms.request_id(), hrms.redact(p_changes), p_classification);
$$;

create or replace function hrms.security_event(
  p_org_id uuid, p_employee uuid, p_kind text, p_detail jsonb default null, p_ip_hash text default null
) returns void
language sql
set search_path = ''
as $$
  insert into hrms.security_events (org_id, employee_id, kind, detail, ip_hash)
  values (p_org_id, p_employee, p_kind, hrms.redact(p_detail), p_ip_hash);
$$;

-- -----------------------------------------------------------------------------
-- Idempotency records for client-supplied operation keys
-- -----------------------------------------------------------------------------

create table hrms.idempotency_records (
  actor_employee_id uuid not null references hrms.employees(id) on delete restrict,
  scope text not null check (char_length(scope) <= 40),
  operation_key uuid not null,
  org_id uuid not null,
  request_hash text not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (actor_employee_id, scope, operation_key)
);
create index idempotency_records_created_idx on hrms.idempotency_records (created_at);

-- Claims an operation key. Returns NULL for a new operation (caller proceeds
-- and later calls idem_complete in the same transaction), or the stored result
-- for an identical replay. A different payload under the same key conflicts.
-- A concurrent same-key call blocks on the unique index until the first
-- transaction ends, then observes its committed result.
create or replace function hrms.idem_claim(
  p_actor uuid, p_org uuid, p_scope text, p_key uuid, p_hash text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_hash text;
  v_result jsonb;
begin
  if p_key is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'operation key required',
      jsonb_build_object('operation_key', 'required'));
  end if;
  insert into hrms.idempotency_records (actor_employee_id, scope, operation_key, org_id, request_hash)
  values (p_actor, p_scope, p_key, p_org, p_hash)
  on conflict do nothing;
  if found then
    return null;
  end if;
  select request_hash, result into v_hash, v_result
  from hrms.idempotency_records
  where actor_employee_id = p_actor and scope = p_scope and operation_key = p_key;
  if v_hash <> p_hash then
    perform hrms.raise_error('IDEMPOTENCY_CONFLICT',
      'This operation key was already used with different details.');
  end if;
  if v_result is null then
    perform hrms.raise_error('OPERATION_IN_PROGRESS', 'Operation is still in progress.', null, true);
  end if;
  return v_result;
end;
$$;

create or replace function hrms.idem_complete(p_actor uuid, p_scope text, p_key uuid, p_result jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  update hrms.idempotency_records set result = p_result
  where actor_employee_id = p_actor and scope = p_scope and operation_key = p_key
  returning p_result;
$$;

-- -----------------------------------------------------------------------------
-- Actor resolution: the gate every business RPC passes first
-- -----------------------------------------------------------------------------

create type hrms.actor as (
  employee_id uuid,
  org_id uuid,
  auth_user_id uuid,
  session_id uuid,
  roles text[],
  permissions text[],
  must_change_password boolean,
  timezone text
);

create or replace function hrms.employee_roles(p_employee uuid) returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct g.role order by g.role), array[]::text[])
  from hrms.role_grants g
  where g.employee_id = p_employee
    and g.effective_from <= now()
    and (g.revoked_at is null or g.revoked_at > now());
$$;

create or replace function hrms.employee_permissions(p_employee uuid) returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(distinct p order by p), array[]::text[])
  from (
    select unnest(hrms.role_bundle(r)) as p from unnest(hrms.employee_roles(p_employee)) as r
    union
    select g.permission from hrms.permission_grants g
    where g.employee_id = p_employee
      and g.effective_from <= now()
      and (g.revoked_at is null or g.revoked_at > now())
  ) s;
$$;

-- Core resolution used by both JWT-context RPCs and service-role internal RPCs
-- (which pass identities they verified themselves). Modes:
--   'business'   : full gates (default for every business operation)
--   'restricted' : allows must_change_password and credential holds, for the
--                  password-change screen and credential status/recovery only.
create or replace function hrms.resolve_actor(
  p_auth_user_id uuid,
  p_session_id uuid,
  p_email text,
  p_mode text default 'business'
) returns hrms.actor
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_emp hrms.employees;
  v_org hrms.organizations;
  v_session_created timestamptz;
  v_actor hrms.actor;
begin
  if p_auth_user_id is null or p_session_id is null then
    perform hrms.raise_error('AUTH_REQUIRED');
  end if;

  select * into v_emp from hrms.employees where auth_user_id = p_auth_user_id;
  if not found then
    perform hrms.raise_error('AUTH_REQUIRED');
  end if;

  -- The Auth identity must still carry the alias we issued. An unexpected
  -- alias change cannot grant access; Admin repairs it against the auth UUID.
  if v_emp.auth_alias is null or p_email is null or lower(p_email) <> lower(v_emp.auth_alias) then
    perform hrms.raise_error('AUTH_REQUIRED');
  end if;

  if v_emp.status <> 'active' or v_emp.provisioning_state <> 'complete' then
    perform hrms.raise_error('ACCOUNT_INACTIVE');
  end if;

  -- Original session creation time must be at/after the credential barrier.
  -- A refreshed JWT keeps its session id, so a pre-reset refresh token cannot
  -- regain access. Revoked sessions no longer exist in auth.sessions.
  select s.created_at into v_session_created
  from auth.sessions s
  where s.id = p_session_id
    and s.user_id = p_auth_user_id
    and (s.not_after is null or s.not_after > now());
  if not found or v_session_created < v_emp.credentials_valid_after then
    perform hrms.raise_error('AUTH_REQUIRED', 'Session expired. Please sign in again.');
  end if;

  if p_mode <> 'restricted' then
    if v_emp.credential_hold_operation_id is not null then
      perform hrms.raise_error('CREDENTIAL_OPERATION_PENDING',
        'A password change is being completed. Try again shortly.', null, true);
    end if;
    if v_emp.must_change_password then
      perform hrms.raise_error('PASSWORD_CHANGE_REQUIRED');
    end if;
  end if;

  select * into v_org from hrms.organizations where id = v_emp.org_id;

  v_actor.employee_id := v_emp.id;
  v_actor.org_id := v_emp.org_id;
  v_actor.auth_user_id := p_auth_user_id;
  v_actor.session_id := p_session_id;
  v_actor.roles := hrms.employee_roles(v_emp.id);
  v_actor.permissions := hrms.employee_permissions(v_emp.id);
  v_actor.must_change_password := v_emp.must_change_password;
  v_actor.timezone := v_org.timezone;
  return v_actor;
end;
$$;

-- JWT-context actor for public RPCs.
create or replace function hrms.current_actor(p_mode text default 'business')
returns hrms.actor
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims jsonb := auth.jwt();
  v_sid uuid;
begin
  if coalesce(v_claims ->> 'role', '') <> 'authenticated' then
    perform hrms.raise_error('AUTH_REQUIRED');
  end if;
  begin
    v_sid := nullif(v_claims ->> 'session_id', '')::uuid;
  exception when others then
    v_sid := null;
  end;
  return hrms.resolve_actor(auth.uid(), v_sid, v_claims ->> 'email', p_mode);
end;
$$;

create or replace function hrms.has_perm(p_actor hrms.actor, p_perm text) returns boolean
language sql
immutable
set search_path = ''
as $$
  select '*' = any(p_actor.permissions) or p_perm = any(p_actor.permissions);
$$;

create or replace function hrms.is_admin(p_actor hrms.actor) returns boolean
language sql
immutable
set search_path = ''
as $$
  select 'admin' = any(p_actor.roles);
$$;

create or replace function hrms.require_perm(p_actor hrms.actor, p_perm text) returns void
language plpgsql
set search_path = ''
as $$
begin
  if not hrms.has_perm(p_actor, p_perm) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
end;
$$;

-- Server-issued reauthentication grant check (consumes when p_consume).
create or replace function hrms.require_reauth(
  p_actor hrms.actor, p_action text, p_target uuid default null, p_consume boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id
  from hrms.reauthentication_grants
  where employee_id = p_actor.employee_id
    and session_id = p_actor.session_id
    and action = p_action
    and (target_id is null or target_id = p_target)
    and consumed_at is null
    and expires_at > now()
  order by issued_at desc
  limit 1
  for update;
  if v_id is null then
    perform hrms.raise_error('REAUTH_REQUIRED', 'Confirm your password to continue.');
  end if;
  if p_consume then
    update hrms.reauthentication_grants set consumed_at = now() where id = v_id;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Organisation calendar helpers
-- -----------------------------------------------------------------------------

create or replace function hrms.org_today(p_org uuid) returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone o.timezone)::date from hrms.organizations o where o.id = p_org;
$$;

-- Team of an employee on a given work date.
create or replace function hrms.team_on(p_employee uuid, p_date date) returns uuid
language sql
stable
set search_path = ''
as $$
  select m.team_id from hrms.team_memberships m
  where m.employee_id = p_employee
    and m.effective_from <= p_date
    and (m.effective_to is null or m.effective_to > p_date)
  limit 1;
$$;

-- Manager of a team on a given date.
create or replace function hrms.manager_of_team_on(p_team uuid, p_date date) returns uuid
language sql
stable
set search_path = ''
as $$
  select tm.manager_id from hrms.team_managers tm
  where tm.team_id = p_team
    and tm.effective_from <= p_date
    and (tm.effective_to is null or tm.effective_to > p_date)
  limit 1;
$$;

-- Execution grants for the API surface. Every migration that adds functions
-- ends with `select hrms.apply_api_grants();`.
--   public.internal_* -> service_role only (called by Edge Functions)
--   other public.*    -> authenticated only (each starts with hrms.current_actor)
--   anon              -> nothing (login goes through the auth-login function)
--   hrms.*            -> no client access at all
create or replace function hrms.apply_api_grants() returns void
language plpgsql
set search_path = ''
as $$
declare
  r record;
begin
  -- No client access to tables/sequences in hrms.
  execute 'revoke all on all tables in schema hrms from public, anon, authenticated';
  execute 'revoke all on all sequences in schema hrms from public, anon, authenticated';
  execute 'revoke all on all functions in schema hrms from public, anon, authenticated';

  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')  -- skip extension-owned
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.sig);
    if r.proname like 'internal\_%' then
      execute format('grant execute on function %s to service_role', r.sig);
    else
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;

  -- service_role (Edge Functions) needs schema usage to resolve types used by
  -- internal functions; it never receives table grants in hrms.
  execute 'grant usage on schema hrms to service_role';
end;
$$;

-- Enable RLS everywhere in hrms (no client policies: deny by default).
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'hrms' loop
    execute format('alter table hrms.%I enable row level security', r.tablename);
  end loop;
end $$;

select hrms.apply_api_grants();
