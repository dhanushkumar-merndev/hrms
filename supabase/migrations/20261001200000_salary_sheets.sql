-- =============================================================================
-- Salary details and the Google Sheets mirror (owner decision 2026-10-01).
--
-- Salary: HR/Admin (payroll managers) record one monthly salary figure per
-- employee with its effective date, the bank the salary is paid into (name,
-- holder, IFSC and only the LAST FOUR digits of the account — the full
-- number is never stored), and optionally the amount actually paid with each
-- published payslip. Still no payroll calculation, tax or statutory engine.
-- Employees see only their own figures; managers never see team salary.
--
-- Sheets: the server keeps one company Google Sheet up to date (one tab per
-- area). Only an Admin can connect it; adding the Salary tab is a bulk
-- salary export and needs a fresh password confirmation.
-- =============================================================================

create table hrms.salary_profiles (
  employee_id uuid primary key,
  org_id uuid not null,
  monthly_salary numeric(12, 2) check (monthly_salary is null or monthly_salary between 0 and 100000000),
  currency text not null default 'INR' check (currency ~ '^[A-Z]{3}$'),
  effective_from date,
  bank_name text check (char_length(bank_name) <= 120),
  account_holder text check (char_length(account_holder) <= 200),
  account_last4 text check (account_last4 ~ '^[0-9]{4}$'),
  ifsc text check (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  version integer not null default 1,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create trigger salary_profiles_touch before update on hrms.salary_profiles
  for each row execute function hrms.touch_updated_at();
alter table hrms.salary_profiles enable row level security;

-- Every change of the salary figure (history shown to payroll managers).
create table hrms.salary_revisions (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  employee_id uuid not null,
  monthly_salary numeric(12, 2),
  currency text not null,
  effective_from date,
  reason text check (char_length(reason) <= 500),
  created_by uuid,
  created_at timestamptz not null default now(),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create index salary_revisions_employee_idx on hrms.salary_revisions (employee_id, created_at desc);
alter table hrms.salary_revisions enable row level security;

-- Amount actually paid for a salary month (optional, entered by payroll).
alter table hrms.payslips
  add column net_amount numeric(12, 2) check (net_amount is null or net_amount between 0 and 100000000);

create table hrms.sheet_sync (
  org_id uuid primary key references hrms.organizations(id) on delete restrict,
  spreadsheet_id text check (spreadsheet_id ~ '^[A-Za-z0-9_-]{20,100}$'),
  enabled boolean not null default false,
  include_salary boolean not null default false,
  sync_requested_at timestamptz,
  last_attempt_at timestamptz,
  last_synced_at timestamptz,
  last_error text check (char_length(last_error) <= 500),
  last_rows integer,
  version integer not null default 1,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
create trigger sheet_sync_touch before update on hrms.sheet_sync
  for each row execute function hrms.touch_updated_at();
alter table hrms.sheet_sync enable row level security;

-- -----------------------------------------------------------------------------
-- Salary
-- -----------------------------------------------------------------------------

create or replace function hrms.salary_json(p_employee uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile', (select jsonb_build_object(
                  'monthly_salary', sp.monthly_salary, 'currency', sp.currency,
                  'effective_from', sp.effective_from, 'bank_name', sp.bank_name,
                  'account_holder', sp.account_holder, 'account_last4', sp.account_last4,
                  'ifsc', sp.ifsc, 'updated_at', sp.updated_at)
                from hrms.salary_profiles sp where sp.employee_id = p_employee),
    'lifetime_paid', (select coalesce(sum(p.net_amount), 0) from hrms.payslips p
                      where p.employee_id = p_employee and p.published_at is not null),
    'paid_months', (select count(*) from hrms.payslips p
                    where p.employee_id = p_employee and p.published_at is not null and p.net_amount is not null),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('salary_month', x.salary_month,
                                                             'net_amount', x.net_amount)
                                         order by x.salary_month desc), '[]'::jsonb)
               from (select p.salary_month, p.net_amount from hrms.payslips p
                     where p.employee_id = p_employee and p.published_at is not null
                     order by p.salary_month desc limit 12) x)
  );
$$;

-- Own salary card. Every reveal is audited (no amounts in the audit row).
create or replace function public.get_my_salary() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'salary.viewed_own', 'employee', v_actor.employee_id,
    null, 'access', v_actor.employee_id);
  return hrms.ok(hrms.salary_json(v_actor.employee_id));
end;
$$;

create or replace function public.get_employee_salary(p_employee_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_version integer;
begin
  if not hrms.can_manage_payroll(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('NOT_FOUND');
  end if;
  select version into v_version from hrms.salary_profiles where employee_id = p_employee_id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'salary.viewed', 'employee', p_employee_id,
    null, 'access', p_employee_id);
  return hrms.ok(hrms.salary_json(p_employee_id) || jsonb_build_object(
    'can_edit', p_employee_id <> v_actor.employee_id or hrms.is_admin(v_actor),
    'revisions', (select coalesce(jsonb_agg(jsonb_build_object(
                    'monthly_salary', r.monthly_salary, 'currency', r.currency,
                    'effective_from', r.effective_from, 'reason', r.reason, 'created_at', r.created_at,
                    'created_by', (select full_name from hrms.employees where id = r.created_by))
                    order by r.created_at desc), '[]'::jsonb)
                  from (select * from hrms.salary_revisions where employee_id = p_employee_id
                        order by created_at desc limit 20) r)
  ), coalesce(v_version, 0));
end;
$$;

-- Partial update: only keys present in p_fields change. Version 0 = no
-- profile yet. Payroll staff (not Admins) cannot change their own salary.
create or replace function public.set_employee_salary(
  p_employee_id uuid, p_fields jsonb, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_emp hrms.employees;
  v_row hrms.salary_profiles;
  v_errors jsonb := '{}'::jsonb;
  v_amount numeric;
  v_from date;
  v_last4 text;
  v_ifsc text;
  v_reason text := hrms.clean_text(p_reason, 500);
  v_amount_changed boolean;
begin
  if not hrms.can_manage_payroll(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_employee_id = v_actor.employee_id and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED', 'Your own salary is changed by an Admin.');
  end if;
  select * into v_emp from hrms.employees where id = p_employee_id and org_id = v_actor.org_id;
  if not found then perform hrms.raise_error('NOT_FOUND'); end if;
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    perform hrms.raise_error('VALIDATION_FAILED', 'Nothing to save.');
  end if;

  if p_fields ? 'monthly_salary' and nullif(p_fields ->> 'monthly_salary', '') is not null then
    begin
      v_amount := (p_fields ->> 'monthly_salary')::numeric;
      if v_amount < 0 or v_amount > 100000000 or v_amount <> round(v_amount, 2) then
        v_errors := v_errors || '{"monthly_salary":"Enter an amount between 0 and 10,00,00,000"}';
      end if;
    exception when others then
      v_errors := v_errors || '{"monthly_salary":"Enter a number, for example 45000"}';
    end;
  end if;
  if p_fields ? 'effective_from' and nullif(p_fields ->> 'effective_from', '') is not null then
    begin
      v_from := (p_fields ->> 'effective_from')::date;
    exception when others then
      v_errors := v_errors || '{"effective_from":"Use a date like 2026-10-01"}';
    end;
  end if;
  if p_fields ? 'account_last4' then
    v_last4 := nullif(regexp_replace(coalesce(p_fields ->> 'account_last4', ''), '\s', '', 'g'), '');
    if v_last4 is not null and length(v_last4) > 4 then v_last4 := right(v_last4, 4); end if;
    if v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then
      v_errors := v_errors || '{"account_last4":"Last 4 digits of the account number"}';
    end if;
  end if;
  if p_fields ? 'ifsc' then
    v_ifsc := nullif(upper(regexp_replace(coalesce(p_fields ->> 'ifsc', ''), '\s', '', 'g')), '');
    if v_ifsc is not null and v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
      v_errors := v_errors || '{"ifsc":"IFSC looks like HDFC0001234"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the highlighted fields.', v_errors);
  end if;

  insert into hrms.salary_profiles (employee_id, org_id, updated_by)
  values (p_employee_id, v_actor.org_id, v_actor.employee_id)
  on conflict (employee_id) do nothing;
  select * into v_row from hrms.salary_profiles where employee_id = p_employee_id for update;
  -- A freshly inserted row is version 1 but the caller saw "no profile" (0).
  if not (v_row.version = p_expected_version
          or (p_expected_version = 0 and v_row.version = 1 and v_row.monthly_salary is null
              and v_row.bank_name is null and v_row.account_last4 is null)) then
    perform hrms.raise_error('STALE_VERSION', 'Salary details changed. Reload and try again.', null, true);
  end if;

  v_amount_changed := p_fields ? 'monthly_salary' and v_amount is distinct from v_row.monthly_salary;
  -- Nothing actually different (e.g. the same Excel imported twice): no
  -- new version, audit row or notification.
  if not v_amount_changed
     and (not p_fields ? 'effective_from' or v_from is not distinct from v_row.effective_from)
     and (not p_fields ? 'bank_name' or hrms.clean_text(p_fields ->> 'bank_name', 120) is not distinct from v_row.bank_name)
     and (not p_fields ? 'account_holder'
          or hrms.clean_text(p_fields ->> 'account_holder', 200) is not distinct from v_row.account_holder)
     and (not p_fields ? 'account_last4' or v_last4 is not distinct from v_row.account_last4)
     and (not p_fields ? 'ifsc' or v_ifsc is not distinct from v_row.ifsc)
     and (not p_fields ? 'currency' or nullif(upper(p_fields ->> 'currency'), '') is null
          or upper(p_fields ->> 'currency') = v_row.currency) then
    return hrms.ok(hrms.salary_json(p_employee_id) || '{"unchanged": true}'::jsonb, v_row.version);
  end if;
  if v_amount_changed and v_row.monthly_salary is not null and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Give a reason for changing the salary.',
      '{"reason":"Required when the amount changes"}'::jsonb);
  end if;

  update hrms.salary_profiles set
    monthly_salary = case when p_fields ? 'monthly_salary' then v_amount else monthly_salary end,
    currency = coalesce(nullif(upper(p_fields ->> 'currency'), ''), currency),
    effective_from = case when p_fields ? 'effective_from' then v_from
                          when v_amount_changed and v_from is null then hrms.org_today(v_actor.org_id)
                          else effective_from end,
    bank_name = case when p_fields ? 'bank_name' then hrms.clean_text(p_fields ->> 'bank_name', 120) else bank_name end,
    account_holder = case when p_fields ? 'account_holder'
                          then hrms.clean_text(p_fields ->> 'account_holder', 200) else account_holder end,
    account_last4 = case when p_fields ? 'account_last4' then v_last4 else account_last4 end,
    ifsc = case when p_fields ? 'ifsc' then v_ifsc else ifsc end,
    version = version + 1,
    updated_by = v_actor.employee_id
  where employee_id = p_employee_id
  returning * into v_row;

  if v_amount_changed then
    insert into hrms.salary_revisions (org_id, employee_id, monthly_salary, currency, effective_from, reason, created_by)
    values (v_actor.org_id, p_employee_id, v_row.monthly_salary, v_row.currency, v_row.effective_from,
            v_reason, v_actor.employee_id);
  end if;

  -- Audit names the fields changed, never the amounts or bank details.
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'salary.updated', 'employee', p_employee_id,
    jsonb_build_object('fields', (select jsonb_agg(k) from jsonb_object_keys(p_fields) k), 'reason', v_reason),
    'business', p_employee_id);
  if p_employee_id <> v_actor.employee_id then
    perform hrms.notify(v_actor.org_id, p_employee_id, 'salary.updated', 'Salary details updated',
      'HR updated your salary details. Open the app to view them.', '/salary', '{}'::jsonb,
      md5(p_employee_id::text || ':salary:' || v_row.version)::uuid);
  end if;
  update hrms.sheet_sync set sync_requested_at = now() where org_id = v_actor.org_id and enabled;
  return hrms.ok(hrms.salary_json(p_employee_id), v_row.version);
end;
$$;

-- Amount paid for one salary month. The payslip row must already exist
-- (created by the payslip upload).
create or replace function public.set_payslip_amount(p_employee_id uuid, p_salary_month date, p_net_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_slip hrms.payslips;
begin
  if not hrms.can_manage_payroll(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_employee_id = v_actor.employee_id and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED', 'Your own salary is changed by an Admin.');
  end if;
  if p_net_amount is not null and (p_net_amount < 0 or p_net_amount > 100000000) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Enter a valid amount.', '{"net_amount":"Between 0 and 10,00,00,000"}');
  end if;
  select * into v_slip from hrms.payslips
  where employee_id = p_employee_id and salary_month = date_trunc('month', p_salary_month)::date
    and org_id = v_actor.org_id
  for update;
  if not found then
    perform hrms.raise_error('NOT_FOUND', 'Upload the payslip for this month first.');
  end if;
  update hrms.payslips set net_amount = round(p_net_amount, 2), version = version + 1
  where id = v_slip.id returning * into v_slip;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'payslip.amount_set', 'payslip', v_slip.id,
    jsonb_build_object('salary_month', v_slip.salary_month), 'business', p_employee_id);
  update hrms.sheet_sync set sync_requested_at = now() where org_id = v_actor.org_id and enabled;
  return hrms.ok(jsonb_build_object('payslip_id', v_slip.id, 'salary_month', v_slip.salary_month,
                                    'net_amount', v_slip.net_amount), v_slip.version);
end;
$$;

-- -----------------------------------------------------------------------------
-- Google Sheets mirror
-- -----------------------------------------------------------------------------

create or replace function hrms.sheet_sync_json(p_org uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select jsonb_build_object(
    'spreadsheet_id', s.spreadsheet_id, 'enabled', s.enabled, 'include_salary', s.include_salary,
    'last_attempt_at', s.last_attempt_at, 'last_synced_at', s.last_synced_at, 'last_error', s.last_error,
    'last_rows', s.last_rows, 'sync_requested_at', s.sync_requested_at)
    from hrms.sheet_sync s where s.org_id = p_org),
    jsonb_build_object('spreadsheet_id', null, 'enabled', false, 'include_salary', false));
$$;

create or replace function public.get_sheet_sync() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok(hrms.sheet_sync_json(v_actor.org_id),
                 coalesce((select version from hrms.sheet_sync where org_id = v_actor.org_id), 0));
end;
$$;

create or replace function public.set_sheet_sync(
  p_spreadsheet_id text, p_enabled boolean, p_include_salary boolean, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_row hrms.sheet_sync;
  v_id text := nullif(trim(coalesce(p_spreadsheet_id, '')), '');
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  -- Accept a pasted sheet link as well as the bare id.
  if v_id ~ '/spreadsheets/d/' then
    v_id := substring(v_id from '/spreadsheets/d/([A-Za-z0-9_-]+)');
  end if;
  if v_id is not null and v_id !~ '^[A-Za-z0-9_-]{20,100}$' then
    perform hrms.raise_error('VALIDATION_FAILED', 'That does not look like a Google Sheet link.',
      '{"spreadsheet_id":"Paste the sheet link from the browser address bar"}');
  end if;
  if coalesce(p_enabled, false) and v_id is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Add the sheet link first.',
      '{"spreadsheet_id":"Required to turn on syncing"}');
  end if;

  insert into hrms.sheet_sync (org_id, updated_by) values (v_actor.org_id, v_actor.employee_id)
  on conflict (org_id) do nothing;
  select * into v_row from hrms.sheet_sync where org_id = v_actor.org_id for update;
  if not (v_row.version = p_expected_version or (p_expected_version = 0 and v_row.version = 1
          and v_row.spreadsheet_id is null and not v_row.enabled)) then
    perform hrms.raise_error('STALE_VERSION', 'Sheet settings changed. Reload and try again.', null, true);
  end if;
  -- Turning ON the salary tab (or pointing it at a new sheet) is a bulk
  -- salary export: it needs a fresh password confirmation.
  if coalesce(p_include_salary, false)
     and (not v_row.include_salary or v_row.spreadsheet_id is distinct from v_id) then
    perform hrms.require_reauth(v_actor, 'export.bulk_salary', null, true);
  end if;

  update hrms.sheet_sync set
    spreadsheet_id = v_id,
    enabled = coalesce(p_enabled, false),
    include_salary = coalesce(p_include_salary, false),
    sync_requested_at = case when coalesce(p_enabled, false) then now() else null end,
    last_error = case when v_id is distinct from v_row.spreadsheet_id then null else last_error end,
    version = version + 1,
    updated_by = v_actor.employee_id
  where org_id = v_actor.org_id
  returning * into v_row;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'sheet_sync.configured', 'organization', v_actor.org_id,
    jsonb_build_object('enabled', v_row.enabled, 'include_salary', v_row.include_salary,
                       'sheet_changed', v_id is distinct from v_row.spreadsheet_id),
    case when v_row.include_salary then 'access' else 'business' end);
  return hrms.ok(hrms.sheet_sync_json(v_actor.org_id), v_row.version);
end;
$$;

-- Called by the sheets-sync function for an Admin's "Sync now".
create or replace function public.internal_sheet_sync_authorize(
  p_auth_user_id uuid, p_session_id uuid, p_email text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return jsonb_build_object('org_id', v_actor.org_id, 'employee_id', v_actor.employee_id);
end;
$$;

-- Organisations whose sheet should be refreshed now: enabled, and either a
-- change was requested or the last refresh is over 30 minutes old. A sheet
-- that failed is retried at most every 15 minutes.
create or replace function public.internal_sheet_sync_due() returns jsonb
language sql
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(s.org_id), '[]'::jsonb)
  from hrms.sheet_sync s
  where s.enabled and s.spreadsheet_id is not null
    and (s.last_attempt_at is null
         or (s.sync_requested_at is not null and s.sync_requested_at > s.last_attempt_at
             and s.last_attempt_at < now() - interval '1 minute')
         or s.last_attempt_at < now() - interval '30 minutes')
    and (s.last_error is null or s.last_attempt_at < now() - interval '15 minutes'
         or s.sync_requested_at > s.last_attempt_at);
$$;

create or replace function hrms.sheet_ts(p_ts timestamptz, p_tz text) returns text
language sql
immutable
set search_path = ''
as $$ select to_char(p_ts at time zone p_tz, 'YYYY-MM-DD HH24:MI'); $$;

create or replace function hrms.sheet_hm(p_seconds numeric) returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_seconds is null then '' else
    (floor(p_seconds / 3600))::int || ':' || lpad((floor(mod(p_seconds, 3600) / 60))::int::text, 2, '0') end;
$$;

-- Builds every tab of the mirror. Text is sent RAW (never evaluated as a
-- formula). Attendance covers the current and previous month.
create or replace function public.internal_sheet_export(p_org_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org hrms.organizations;
  v_cfg hrms.sheet_sync;
  v_today date;
  v_from date;
  v_tz text;
  v_ids uuid[];
  v_tabs jsonb := '[]'::jsonb;
  v_rows jsonb;
  v_counts jsonb := '{}'::jsonb;
begin
  select * into v_org from hrms.organizations where id = p_org_id;
  select * into v_cfg from hrms.sheet_sync where org_id = p_org_id;
  if v_org.id is null or v_cfg.org_id is null then perform hrms.raise_error('NOT_FOUND'); end if;
  v_tz := v_org.timezone;
  v_today := hrms.org_today(p_org_id);
  v_from := (date_trunc('month', v_today) - interval '1 month')::date;
  select array_agg(id) into v_ids from hrms.employees where org_id = p_org_id and auth_user_id is not null;
  v_ids := coalesce(v_ids, array[]::uuid[]);

  -- Employees
  select coalesce(jsonb_agg(jsonb_build_array(
           e.employee_code, e.full_name, coalesce(e.designation, ''), coalesce(d.name, ''),
           coalesce(t.name, ''), array_to_string(hrms.employee_roles(e.id), ', '),
           coalesce(o.name, ''), coalesce(sh.name, ''), initcap(e.status),
           e.join_date::text, coalesce(e.end_date::text, ''),
           coalesce(e.business_email, ''), coalesce(e.business_phone, ''))
         order by e.employee_code), '[]'::jsonb)
    into v_rows
  from hrms.employees e
  left join hrms.departments d on d.id = e.department_id
  left join lateral (select tm.team_id from hrms.team_memberships tm where tm.employee_id = e.id
                     and tm.effective_from <= v_today and (tm.effective_to is null or tm.effective_to > v_today)
                     limit 1) tmx on true
  left join hrms.teams t on t.id = tmx.team_id
  left join lateral (select oa.office_id from hrms.office_assignments oa where oa.employee_id = e.id
                     and oa.effective_from <= v_today and (oa.effective_to is null or oa.effective_to > v_today)
                     limit 1) oax on true
  left join hrms.offices o on o.id = oax.office_id
  left join lateral (select sa.shift_id from hrms.shift_assignments sa where sa.employee_id = e.id
                     and sa.effective_from <= v_today and (sa.effective_to is null or sa.effective_to > v_today)
                     limit 1) sax on true
  left join hrms.shifts sh on sh.id = sax.shift_id
  where e.org_id = p_org_id and e.auth_user_id is not null;
  v_tabs := v_tabs || jsonb_build_object('name', 'Employees', 'header', jsonb_build_array(
    'Employee ID', 'Name', 'Designation', 'Department', 'Team', 'Roles', 'Office', 'Shift', 'Status',
    'Joined', 'Left', 'Work email', 'Work phone'), 'rows', v_rows);
  v_counts := v_counts || jsonb_build_object('Employees', jsonb_array_length(v_rows));

  -- Attendance (current + previous month, up to today)
  select coalesce(jsonb_agg(jsonb_build_array(
           r.shift_date::text, e.employee_code, e.full_name,
           initcap(replace(r.status, '_', ' ')),
           coalesce(hrms.sheet_ts(r.effective_in_at, v_tz), ''), coalesce(hrms.sheet_ts(r.effective_out_at, v_tz), ''),
           hrms.sheet_hm((r.calc).required_seconds), hrms.sheet_hm((r.calc).credited_seconds),
           hrms.sheet_hm((r.calc).shortfall_seconds), hrms.sheet_hm((r.calc).extra_seconds),
           case when (r.calc).is_late then 'Yes' else '' end,
           case r.effective_source when 'manual' then 'Correction' when 'mixed' then 'Corrected'
                when 'gps' then 'Location verified' else coalesce(r.effective_source, '') end)
         order by r.shift_date desc, e.employee_code), '[]'::jsonb)
    into v_rows
  from hrms.attendance_rows(p_org_id, v_ids, v_from, v_today, now()) r
  join hrms.employees e on e.id = r.employee_id
  where r.is_required or r.session_id is not null or r.status = 'leave';
  v_tabs := v_tabs || jsonb_build_object('name', 'Attendance', 'header', jsonb_build_array(
    'Date', 'Employee ID', 'Name', 'Status', 'Check in', 'Check out', 'Expected (h:mm)', 'Worked (h:mm)',
    'Short (h:mm)', 'Extra (h:mm)', 'Late', 'Source'), 'rows', v_rows);
  v_counts := v_counts || jsonb_build_object('Attendance', jsonb_array_length(v_rows));

  -- Requests (leave + corrections) with their latest decision
  select coalesce(jsonb_agg(jsonb_build_array(
           coalesce(hrms.sheet_ts(q.submitted_at, v_tz), hrms.sheet_ts(q.created_at, v_tz)),
           e.employee_code, e.full_name,
           case q.kind when 'leave' then coalesce(lt.name, 'Leave') else 'Attendance correction' end,
           coalesce(q.start_date::text, q.target_shift_date::text, ''), coalesce(q.end_date::text, ''),
           coalesce((q.units / 2.0)::numeric(6,1)::text, ''),
           initcap(replace(q.state, '_', ' ')), coalesce(rv.full_name, ''),
           coalesce(dc.full_name, ''), coalesce(hrms.sheet_ts(q.decided_at, v_tz), ''))
         order by coalesce(q.submitted_at, q.created_at) desc), '[]'::jsonb)
    into v_rows
  from hrms.requests q
  join hrms.employees e on e.id = q.employee_id
  left join hrms.leave_types lt on lt.id = q.leave_type_id
  left join hrms.employees rv on rv.id = q.assigned_reviewer_id
  left join hrms.employees dc on dc.id = q.decided_by
  where q.org_id = p_org_id and q.state <> 'draft'
    and coalesce(q.submitted_at, q.created_at) > now() - interval '400 days';
  v_tabs := v_tabs || jsonb_build_object('name', 'Leave & Requests', 'header', jsonb_build_array(
    'Submitted', 'Employee ID', 'Name', 'Type', 'From / day', 'To', 'Days', 'State', 'Reviewer',
    'Decided by', 'Decided at'), 'rows', v_rows);
  v_counts := v_counts || jsonb_build_object('Leave & Requests', jsonb_array_length(v_rows));

  -- Approval history (who did what; reasons stay in the app)
  select coalesce(jsonb_agg(jsonb_build_array(
           hrms.sheet_ts(ev.created_at, v_tz), e.employee_code, e.full_name,
           case q.kind when 'leave' then 'Leave' else 'Correction' end,
           initcap(replace(ev.action, '_', ' ')), coalesce(a.full_name, 'System'),
           initcap(replace(coalesce(ev.from_state, ''), '_', ' ')), initcap(replace(coalesce(ev.to_state, ''), '_', ' ')))
         order by ev.created_at desc), '[]'::jsonb)
    into v_rows
  from (select * from hrms.approval_events where org_id = p_org_id
        and created_at > now() - interval '400 days' order by created_at desc limit 5000) ev
  join hrms.requests q on q.id = ev.request_id
  join hrms.employees e on e.id = q.employee_id
  left join hrms.employees a on a.id = ev.actor_id;
  v_tabs := v_tabs || jsonb_build_object('name', 'Approvals', 'header', jsonb_build_array(
    'When', 'Employee ID', 'Name', 'Request', 'Action', 'By', 'From', 'To'), 'rows', v_rows);
  v_counts := v_counts || jsonb_build_object('Approvals', jsonb_array_length(v_rows));

  -- Leave balances for the current leave year (paid types)
  with yr as (select hrms.leave_year_of(v_org.leave_year_start_month, v_today) as y),
  acc as (select a.* from hrms.leave_accounts a, yr where a.org_id = p_org_id and a.leave_year = yr.y),
  led as (
    select l.account_id,
           coalesce(sum(l.units) filter (where l.entry_kind in ('allocate', 'adjust')), 0) as allocated,
           coalesce(-sum(l.units) filter (where l.entry_kind = 'debit'), 0)
             - coalesce(sum(l.units) filter (where l.entry_kind = 'credit_back'), 0) as used
    from hrms.leave_ledger l where l.account_id in (select id from acc) group by l.account_id),
  res as (select r.account_id, sum(r.units) as reserved from hrms.leave_reservations r
          where r.account_id in (select id from acc) and r.state = 'active' group by r.account_id),
  av as (select x.account_id, sum(x.available) filter (where x.valid_to > v_today) as available
         from hrms.allocation_availability(array(select id from acc)) x group by x.account_id)
  select coalesce(jsonb_agg(jsonb_build_array(
           e.employee_code, e.full_name, (select y from yr), t.name,
           coalesce(led.allocated, 0) / 2.0, coalesce(led.used, 0) / 2.0,
           coalesce(res.reserved, 0) / 2.0, coalesce(av.available, 0) / 2.0)
         order by e.employee_code, t.name), '[]'::jsonb)
    into v_rows
  from acc
  join hrms.employees e on e.id = acc.employee_id
  join hrms.leave_types t on t.id = acc.leave_type_id and t.paid
  left join led on led.account_id = acc.id
  left join res on res.account_id = acc.id
  left join av on av.account_id = acc.id;
  v_tabs := v_tabs || jsonb_build_object('name', 'Leave Balances', 'header', jsonb_build_array(
    'Employee ID', 'Name', 'Leave year', 'Leave type', 'Allocated (days)', 'Used (days)', 'Pending (days)',
    'Available (days)'), 'rows', v_rows);
  v_counts := v_counts || jsonb_build_object('Leave Balances', jsonb_array_length(v_rows));

  -- Roles & access
  select coalesce(jsonb_agg(jsonb_build_array(
           e.employee_code, e.full_name,
           coalesce(nullif(array_to_string(hrms.employee_roles(e.id), ', '), ''), 'member'),
           coalesce((select string_agg(pg.permission, ', ' order by pg.permission) from hrms.permission_grants pg
                     where pg.employee_id = e.id and pg.revoked_at is null and pg.effective_from <= now()), ''),
           initcap(e.status))
         order by e.employee_code), '[]'::jsonb)
    into v_rows
  from hrms.employees e where e.org_id = p_org_id and e.auth_user_id is not null;
  v_tabs := v_tabs || jsonb_build_object('name', 'Roles & Access', 'header', jsonb_build_array(
    'Employee ID', 'Name', 'Roles', 'Extra permissions', 'Status'), 'rows', v_rows);

  -- Teams
  select coalesce(jsonb_agg(jsonb_build_array(
           t.name, coalesce(d.name, ''),
           coalesce((select string_agg(m.full_name, ', ') from hrms.team_managers tm join hrms.employees m on m.id = tm.manager_id
                     where tm.team_id = t.id and tm.effective_from <= v_today
                       and (tm.effective_to is null or tm.effective_to > v_today)), ''),
           (select count(*) from hrms.team_memberships tm where tm.team_id = t.id and tm.effective_from <= v_today
              and (tm.effective_to is null or tm.effective_to > v_today)),
           case when t.active then 'Active' else 'Inactive' end)
         order by t.name), '[]'::jsonb)
    into v_rows
  from hrms.teams t left join hrms.departments d on d.id = t.department_id
  where t.org_id = p_org_id;
  v_tabs := v_tabs || jsonb_build_object('name', 'Teams', 'header', jsonb_build_array(
    'Team', 'Department', 'Manager', 'Members', 'Status'), 'rows', v_rows);

  -- Salary (only when the Admin turned it on with a password confirmation)
  if v_cfg.include_salary then
    select coalesce(jsonb_agg(jsonb_build_array(
             e.employee_code, e.full_name, sp.monthly_salary, coalesce(sp.currency, 'INR'),
             coalesce(sp.effective_from::text, ''), coalesce(sp.bank_name, ''),
             case when sp.account_last4 is null then '' else 'XXXX' || sp.account_last4 end,
             coalesce(sp.ifsc, ''),
             (select coalesce(sum(p.net_amount), 0) from hrms.payslips p
              where p.employee_id = e.id and p.published_at is not null))
           order by e.employee_code), '[]'::jsonb)
      into v_rows
    from hrms.employees e left join hrms.salary_profiles sp on sp.employee_id = e.id
    where e.org_id = p_org_id and e.auth_user_id is not null;
    v_tabs := v_tabs || jsonb_build_object('name', 'Salary', 'header', jsonb_build_array(
      'Employee ID', 'Name', 'Monthly salary', 'Currency', 'Effective from', 'Bank', 'Account', 'IFSC',
      'Paid to date'), 'rows', v_rows);
  end if;

  v_tabs := jsonb_build_array(jsonb_build_object('name', 'Overview', 'header', jsonb_build_array('HRMS live data', ''),
    'rows', jsonb_build_array(
      jsonb_build_array('Organisation', v_org.name),
      jsonb_build_array('Last updated', hrms.sheet_ts(now(), v_tz) || ' (' || v_tz || ')'),
      jsonb_build_array('Active employees', (select count(*) from hrms.employees
                                             where org_id = p_org_id and status = 'active')),
      jsonb_build_array('Attendance covers', v_from::text || ' to ' || v_today::text),
      jsonb_build_array('Present today', (select count(*) from hrms.attendance_sessions s
                                          join hrms.work_schedule_instances w on w.id = s.schedule_instance_id
                                          where w.org_id = p_org_id and w.shift_date = v_today)),
      jsonb_build_array('Pending requests', (select count(*) from hrms.requests
                                             where org_id = p_org_id and state in ('submitted', 'under_review'))),
      jsonb_build_array('', ''),
      jsonb_build_array('This sheet is rewritten by the HRMS app. Edits made here are overwritten.', '')))) || v_tabs;

  update hrms.sheet_sync set last_attempt_at = now() where org_id = p_org_id;
  return jsonb_build_object('spreadsheet_id', v_cfg.spreadsheet_id, 'include_salary', v_cfg.include_salary,
                            'tabs', v_tabs, 'counts', v_counts);
end;
$$;

create or replace function public.internal_sheet_sync_result(p_org_id uuid, p_ok boolean, p_error text, p_rows integer)
returns void
language sql
security definer
set search_path = ''
as $$
  update hrms.sheet_sync set
    last_synced_at = case when p_ok then now() else last_synced_at end,
    last_error = case when p_ok then null else left(coalesce(p_error, 'Unknown error'), 500) end,
    last_rows = case when p_ok then p_rows else last_rows end,
    -- A change made while this sync ran keeps its request for the next run.
    sync_requested_at = case when p_ok and (sync_requested_at is null or sync_requested_at <= last_attempt_at)
                             then null else sync_requested_at end
  where org_id = p_org_id;
$$;

-- Business changes ask for a refresh (the job runs at most every minute).
create or replace function hrms.sheet_touch() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update hrms.sheet_sync set sync_requested_at = now()
  where enabled and org_id = coalesce(new.org_id, old.org_id)
    and (sync_requested_at is null or sync_requested_at < now() - interval '30 seconds');
  return null;
end;
$$;

create trigger employees_sheet_touch after insert or update on hrms.employees
  for each row execute function hrms.sheet_touch();
create trigger requests_sheet_touch after insert or update on hrms.requests
  for each row execute function hrms.sheet_touch();
create trigger sessions_sheet_touch after insert or update on hrms.attendance_sessions
  for each row execute function hrms.sheet_touch();
create trigger role_grants_sheet_touch after insert or update on hrms.role_grants
  for each row execute function hrms.sheet_touch();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hrms-sheets';
    perform cron.schedule('hrms-sheets', '* * * * *',
      $cron$ select hrms.cron_invoke('sheets') where jsonb_array_length(public.internal_sheet_sync_due()) > 0 $cron$);
  end if;
end $$;

select hrms.apply_api_grants();
