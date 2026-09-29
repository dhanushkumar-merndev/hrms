-- =============================================================================
-- Offices, shifts, holidays, schedule instances and the hours engine
-- (architecture.md §5.2–5.3). All instants are stored in UTC; local dates and
-- times are interpreted in the office time zone (org zone when no office).
-- =============================================================================

create table hrms.offices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  name text not null check (char_length(name) between 1 and 120),
  timezone text not null,
  location extensions.geography(Point, 4326) not null,
  radius_m numeric(7,2) not null default 20 check (radius_m > 0 and radius_m <= 2000),
  max_accuracy_m numeric(7,2) not null default 15 check (max_accuracy_m > 0 and max_accuracy_m <= 500),
  max_sample_age_s integer not null default 10 check (max_sample_age_s between 1 and 120),
  strict_mode boolean not null default false,
  active boolean not null default true,
  calibration_status text not null default 'untested'
    check (calibration_status in ('untested', 'piloting', 'verified')),
  calibration_notes text check (char_length(calibration_notes) <= 1000),
  config_version integer not null default 1,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, name),
  unique (org_id, id)
);
create trigger offices_touch before update on hrms.offices
  for each row execute function hrms.touch_updated_at();

-- Immutable history of geofence configuration; punches record the version used.
create table hrms.office_config_versions (
  office_id uuid not null references hrms.offices(id) on delete restrict,
  config_version integer not null,
  snapshot jsonb not null,
  changed_by uuid,
  created_at timestamptz not null default now(),
  primary key (office_id, config_version)
);
create trigger office_config_versions_append_only before update or delete on hrms.office_config_versions
  for each row execute function hrms.forbid_mutation();

create table hrms.office_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  office_id uuid not null,
  effective_from date not null,
  effective_to date,
  created_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, office_id) references hrms.offices(org_id, id) on delete restrict,
  constraint office_assignments_no_overlap exclude using gist (
    employee_id with =, daterange(effective_from, effective_to, '[)') with &&
  )
);
create index office_assignments_emp_idx on hrms.office_assignments (employee_id, effective_from, effective_to);

-- -----------------------------------------------------------------------------
-- Shifts: a logical shift with immutable published versions (prospective)
-- -----------------------------------------------------------------------------

create table hrms.shifts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  name text not null check (char_length(name) between 1 and 80),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, name),
  unique (org_id, id)
);

create table hrms.shift_versions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  shift_id uuid not null,
  version_no integer not null,
  effective_from date not null,
  start_local time not null,
  end_local time not null,
  crosses_midnight boolean generated always as (end_local <= start_local) stored,
  -- bit 0 = Monday ... bit 6 = Sunday. 31 = Monday–Friday.
  weekly_mask smallint not null default 31 check (weekly_mask between 1 and 127),
  grace_seconds integer not null default 1800 check (grace_seconds between 0 and 14400),
  lunch_start_local time,
  lunch_end_local time,
  lunch_paid boolean not null default true,
  early_entry_seconds integer not null default 1800 check (early_entry_seconds between 0 and 14400),
  early_credit boolean not null default false,
  checkout_extension_enabled boolean not null default true,
  checkout_extension_seconds integer not null default 7200
    check (checkout_extension_seconds between 0 and 43200),
  state text not null default 'draft' check (state in ('draft', 'published')),
  published_at timestamptz,
  published_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (shift_id, version_no),
  unique (org_id, id),
  check (end_local <> start_local),
  check ((lunch_start_local is null) = (lunch_end_local is null)),
  foreign key (org_id, shift_id) references hrms.shifts(org_id, id) on delete restrict
);
create index shift_versions_lookup on hrms.shift_versions (shift_id, effective_from desc, version_no desc)
  where state = 'published';

-- Published versions cannot be edited; a change is a new version.
create or replace function hrms.shift_versions_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state = 'published' then
    raise exception 'HRMS: published shift versions are immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger shift_versions_guard before update on hrms.shift_versions
  for each row execute function hrms.shift_versions_guard();

create table hrms.shift_assignments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  shift_id uuid not null,
  effective_from date not null,
  effective_to date,
  created_by uuid,
  reason text,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, shift_id) references hrms.shifts(org_id, id) on delete restrict,
  constraint shift_assignments_no_overlap exclude using gist (
    employee_id with =, daterange(effective_from, effective_to, '[)') with &&
  )
);
create index shift_assignments_emp_idx on hrms.shift_assignments (employee_id, effective_from, effective_to);

-- Seconds from shift start to a local time on the shift's own timeline
-- (wrapping past midnight). Used to validate lunch within the shift.
create or replace function hrms.shift_offset_seconds(p_start time, p_t time) returns integer
language sql
immutable
set search_path = ''
as $$
  select (((extract(epoch from p_t) - extract(epoch from p_start))::integer % 86400) + 86400) % 86400;
$$;

create or replace function hrms.shift_length_seconds(p_start time, p_end time) returns integer
language sql
immutable
set search_path = ''
as $$
  select case when hrms.shift_offset_seconds(p_start, p_end) = 0 then 86400
              else hrms.shift_offset_seconds(p_start, p_end) end;
$$;

-- Validates a shift draft; returns field errors (empty object when valid).
create or replace function hrms.validate_shift(
  p_start time, p_end time, p_lunch_start time, p_lunch_end time
) returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_len integer;
  v_ls integer;
  v_le integer;
begin
  if p_start = p_end then
    v_errors := v_errors || jsonb_build_object('end_local', 'End must differ from start');
    return v_errors;
  end if;
  v_len := hrms.shift_length_seconds(p_start, p_end);
  if (p_lunch_start is null) <> (p_lunch_end is null) then
    v_errors := v_errors || jsonb_build_object('lunch', 'Set both lunch start and end, or neither');
  elsif p_lunch_start is not null then
    v_ls := hrms.shift_offset_seconds(p_start, p_lunch_start);
    v_le := hrms.shift_offset_seconds(p_start, p_lunch_end);
    if v_le = 0 then v_le := 86400; end if;
    if not (v_ls >= 0 and v_ls < v_le and v_le <= v_len) then
      v_errors := v_errors || jsonb_build_object('lunch', 'Lunch must fall inside the shift');
    end if;
  end if;
  return v_errors;
end;
$$;

-- -----------------------------------------------------------------------------
-- Holidays and schedule exceptions
-- -----------------------------------------------------------------------------

create table hrms.holidays (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  office_id uuid,
  holiday_date date not null,
  name text not null check (char_length(name) between 1 and 120),
  state text not null default 'draft' check (state in ('draft', 'published', 'withdrawn')),
  source text not null default 'manual' check (source in ('manual', 'import')),
  version integer not null default 1,
  published_at timestamptz,
  published_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (org_id, office_id) references hrms.offices(org_id, id) on delete restrict
);
create unique index holidays_unique_active on hrms.holidays
  (org_id, coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), holiday_date)
  where state <> 'withdrawn';
create index holidays_date_idx on hrms.holidays (org_id, holiday_date) where state = 'published';
create trigger holidays_touch before update on hrms.holidays
  for each row execute function hrms.touch_updated_at();

-- Audited per-day overrides: add required work on a holiday/weekly off, or
-- remove it. They never override approved leave.
create table hrms.schedule_exceptions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  work_date date not null,
  kind text not null check (kind in ('extra_workday', 'day_off')),
  shift_id uuid,
  reason text not null check (char_length(reason) between 3 and 500),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  unique (employee_id, work_date),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, shift_id) references hrms.shifts(org_id, id) on delete restrict,
  check ((kind = 'extra_workday') = (shift_id is not null))
);

-- -----------------------------------------------------------------------------
-- Materialised schedule instances (one per employee per shift date)
-- -----------------------------------------------------------------------------

create table hrms.work_schedule_instances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  shift_date date not null,
  kind text not null check (kind in ('workday', 'holiday', 'weekly_off', 'extra_workday', 'day_off')),
  is_required boolean not null,
  office_id uuid,
  shift_version_id uuid not null,
  holiday_id uuid,
  timezone text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  lunch_start_at timestamptz,
  lunch_end_at timestamptz,
  lunch_paid boolean not null,
  grace_seconds integer not null,
  early_entry_seconds integer not null,
  early_credit boolean not null,
  checkout_extension_seconds integer not null,
  expected_seconds integer not null check (expected_seconds >= 0),
  half_split_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (employee_id, shift_date),
  unique (org_id, id),
  check (end_at > start_at),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (shift_version_id) references hrms.shift_versions(id) on delete restrict
);
create index wsi_org_date_idx on hrms.work_schedule_instances (org_id, shift_date desc, employee_id, id);
create index wsi_emp_date_idx on hrms.work_schedule_instances (employee_id, shift_date desc, id);

-- Instances are immutable snapshots. Only FUTURE instances may be removed, and
-- only inside hrms.refresh_future_instances (prospective policy/holiday
-- reconciliation). Instances referenced by attendance are protected by FKs.
create or replace function hrms.wsi_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'HRMS: schedule instances are immutable' using errcode = '42501';
  end if;
  if coalesce(current_setting('hrms.schedule_refresh', true), '') <> 'on'
     or old.shift_date <= (now() at time zone old.timezone)::date then
    raise exception 'HRMS: only future schedule instances can be refreshed' using errcode = '42501';
  end if;
  return old;
end;
$$;
create trigger wsi_guard before update or delete on hrms.work_schedule_instances
  for each row execute function hrms.wsi_guard();

-- Materialises schedule instances for employees over an inclusive date range
-- in ONE set-based statement (no per-day or per-employee loop). Existing
-- instances are never rewritten: policy changes are prospective, and a
-- snapshot taken for a day stays as recorded. Range is bounded to 400 days.
create or replace function hrms.ensure_schedule_instances(
  p_org uuid, p_employee_ids uuid[], p_from date, p_to date
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to < p_from then
    return;
  end if;
  if p_to - p_from > 400 then
    perform hrms.raise_error('RANGE_TOO_LARGE', 'Date range is too large.');
  end if;

  with org as (
    select o.id, o.timezone from hrms.organizations o where o.id = p_org
  ),
  emps as (
    select e.id, e.join_date, e.end_date
    from hrms.employees e
    where e.org_id = p_org and e.id = any(p_employee_ids)
  ),
  days as (
    select e.id as employee_id, d::date as day
    from emps e
    cross join lateral generate_series(
      greatest(p_from, e.join_date),
      least(p_to, coalesce(e.end_date, p_to)),
      interval '1 day'
    ) d
  ),
  -- Published version validity ranges, computed once for all shifts.
  versions as (
    select sv.*,
           daterange(sv.effective_from,
                     lead(sv.effective_from) over (partition by sv.shift_id
                                                   order by sv.effective_from, sv.version_no),
                     '[)') as valid
    from hrms.shift_versions sv
    where sv.org_id = p_org and sv.state = 'published'
  ),
  base as (
    select dd.employee_id, dd.day,
           coalesce(ex.shift_id, sa.shift_id) as shift_id,
           ex.kind as exception_kind,
           oa.office_id
    from days dd
    left join hrms.shift_assignments sa
      on sa.employee_id = dd.employee_id
     and daterange(sa.effective_from, sa.effective_to, '[)') @> dd.day
    left join hrms.schedule_exceptions ex
      on ex.employee_id = dd.employee_id and ex.work_date = dd.day
    left join hrms.office_assignments oa
      on oa.employee_id = dd.employee_id
     and daterange(oa.effective_from, oa.effective_to, '[)') @> dd.day
  ),
  hol as (
    select distinct on (b.employee_id, b.day) b.employee_id, b.day, h.id as holiday_id
    from base b
    join hrms.holidays h
      on h.org_id = p_org and h.state = 'published' and h.holiday_date = b.day
     and (h.office_id is null or h.office_id = b.office_id)
    order by b.employee_id, b.day, h.office_id nulls last
  ),
  resolved as (
    select b.employee_id, b.day, b.office_id, b.exception_kind, hol.holiday_id,
           v.id as shift_version_id, v.start_local, v.end_local, v.crosses_midnight,
           v.weekly_mask, v.grace_seconds, v.lunch_start_local, v.lunch_end_local, v.lunch_paid,
           v.early_entry_seconds, v.early_credit,
           case when v.checkout_extension_enabled then v.checkout_extension_seconds else 0 end as ext,
           coalesce(ofc.timezone, org.timezone) as tz,
           (v.weekly_mask & (1 << (extract(isodow from b.day)::integer - 1))) <> 0 as on_weekly_day
    from base b
    cross join org
    join versions v on v.shift_id = b.shift_id and v.valid @> b.day
    left join hol on hol.employee_id = b.employee_id and hol.day = b.day
    left join hrms.offices ofc on ofc.id = b.office_id
  ),
  timed as (
    select r.*,
           ((r.day + r.start_local) at time zone r.tz) as s_at,
           (((r.day + case when r.crosses_midnight then 1 else 0 end) + r.end_local) at time zone r.tz) as e_at,
           case when r.lunch_start_local is null then null else
             (((r.day + case when r.crosses_midnight and r.lunch_start_local < r.start_local then 1 else 0 end)
               + r.lunch_start_local) at time zone r.tz) end as ls_at,
           case when r.lunch_end_local is null then null else
             (((r.day + case when r.crosses_midnight and r.lunch_end_local <= r.start_local then 1 else 0 end)
               + r.lunch_end_local) at time zone r.tz) end as le_at,
           case
             when r.exception_kind = 'day_off' then 'day_off'
             when r.exception_kind = 'extra_workday' then 'extra_workday'
             when r.holiday_id is not null then 'holiday'
             when not r.on_weekly_day then 'weekly_off'
             else 'workday'
           end as kind
    from resolved r
  )
  insert into hrms.work_schedule_instances (
    org_id, employee_id, shift_date, kind, is_required, office_id, shift_version_id, holiday_id,
    timezone, start_at, end_at, lunch_start_at, lunch_end_at, lunch_paid, grace_seconds,
    early_entry_seconds, early_credit, checkout_extension_seconds, expected_seconds, half_split_at
  )
  select p_org, t.employee_id, t.day, t.kind, t.kind in ('workday', 'extra_workday'), t.office_id,
         t.shift_version_id, t.holiday_id, t.tz, t.s_at, t.e_at, t.ls_at, t.le_at, t.lunch_paid,
         t.grace_seconds, t.early_entry_seconds, t.early_credit, t.ext,
         (extract(epoch from (t.e_at - t.s_at))
           - case when t.lunch_paid or t.ls_at is null then 0
                  else extract(epoch from (t.le_at - t.ls_at)) end)::integer,
         -- Half-day split at the midpoint of the paid timeline (10:00–19:00
         -- with paid lunch -> 14:30). With an unpaid lunch the split skips it.
         case
           when t.lunch_paid or t.ls_at is null then t.s_at + (t.e_at - t.s_at) / 2
           else (
             select case when t.s_at + make_interval(secs => half) <= t.ls_at
                         then t.s_at + make_interval(secs => half)
                         else t.s_at + make_interval(secs => half) + (t.le_at - t.ls_at) end
             from (select (extract(epoch from (t.e_at - t.s_at))
                           - extract(epoch from (t.le_at - t.ls_at))) / 2 as half) h
           )
         end
  from timed t
  on conflict (employee_id, shift_date) do nothing;
end;
$$;

-- -----------------------------------------------------------------------------
-- Hours engine (pure). Seconds everywhere; display rounding happens in the app.
--   p_leave_slots: 0 = none, 1 = AM half, 2 = PM half, 3 = full day
-- Required interval = scheduled paid timeline minus approved leave.
-- Credit window:
--   full day    -> [start (or IN when early credit), end + checkout extension]
--   partial day -> exactly the remaining required interval (no extra credit)
-- Grace only decides the late label; it never creates credited seconds.
-- -----------------------------------------------------------------------------

create type hrms.day_calc as (
  required_start timestamptz,
  required_end timestamptz,
  required_seconds integer,
  presence_seconds integer,
  credited_seconds integer,
  shortfall_seconds integer,
  extra_seconds integer,
  is_late boolean,
  late_seconds integer,
  is_early_departure boolean,
  early_seconds integer,
  leave_conflict_seconds integer
);

create or replace function hrms.overlap_seconds(
  a_start timestamptz, a_end timestamptz, b_start timestamptz, b_end timestamptz
) returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when a_start is null or a_end is null or b_start is null or b_end is null then 0
    else greatest(0, extract(epoch from (least(a_end, b_end) - greatest(a_start, b_start))))::integer
  end;
$$;

create or replace function hrms.calc_day(
  p_is_required boolean,
  p_start timestamptz,
  p_end timestamptz,
  p_split timestamptz,
  p_expected_seconds integer,
  p_leave_slots integer,
  p_grace_seconds integer,
  p_early_credit boolean,
  p_extension_seconds integer,
  p_in timestamptz,
  p_out timestamptz,
  p_unpaid_seconds integer default 0
) returns hrms.day_calc
language plpgsql
immutable
set search_path = ''
as $$
declare
  r hrms.day_calc;
  v_credit_start timestamptz;
  v_credit_end timestamptz;
  v_leave_start timestamptz;
  v_leave_end timestamptz;
begin
  r.presence_seconds := case when p_in is not null and p_out is not null and p_out > p_in
                             then extract(epoch from (p_out - p_in))::integer else 0 end;
  r.is_late := false; r.late_seconds := 0;
  r.is_early_departure := false; r.early_seconds := 0;
  r.leave_conflict_seconds := 0;

  if not p_is_required or p_leave_slots = 3 then
    r.required_seconds := 0;
    r.credited_seconds := 0;
    r.shortfall_seconds := 0;
    r.extra_seconds := 0;
    if p_leave_slots = 3 then
      r.leave_conflict_seconds := r.presence_seconds;
    end if;
    return r;
  end if;

  if p_leave_slots = 1 then          -- AM leave: work the PM half
    r.required_start := p_split; r.required_end := p_end;
    v_leave_start := p_start; v_leave_end := p_split;
  elsif p_leave_slots = 2 then       -- PM leave: work the AM half
    r.required_start := p_start; r.required_end := p_split;
    v_leave_start := p_split; v_leave_end := p_end;
  else
    r.required_start := p_start; r.required_end := p_end;
  end if;

  if p_leave_slots in (1, 2) then
    r.required_seconds := p_expected_seconds / 2;
    v_credit_start := r.required_start;
    v_credit_end := r.required_end;
  else
    r.required_seconds := p_expected_seconds;
    v_credit_start := case when p_early_credit and p_in is not null and p_in < p_start then p_in else p_start end;
    v_credit_end := p_end + make_interval(secs => p_extension_seconds);
  end if;

  if p_in is not null and p_out is not null and p_out > p_in then
    r.credited_seconds := greatest(0,
      hrms.overlap_seconds(p_in, p_out, v_credit_start, v_credit_end) - coalesce(p_unpaid_seconds, 0));
    if v_leave_start is not null then
      r.leave_conflict_seconds := hrms.overlap_seconds(p_in, p_out, v_leave_start, v_leave_end);
    end if;
  else
    r.credited_seconds := 0;
  end if;

  if p_in is not null and p_in > r.required_start + make_interval(secs => p_grace_seconds) then
    r.is_late := true;
    r.late_seconds := extract(epoch from (p_in - r.required_start))::integer;
  end if;
  if p_out is not null and p_out < r.required_end then
    r.is_early_departure := true;
    r.early_seconds := extract(epoch from (r.required_end - p_out))::integer;
  end if;

  r.shortfall_seconds := greatest(0, r.required_seconds - r.credited_seconds);
  r.extra_seconds := greatest(0, r.credited_seconds - r.required_seconds);
  return r;
end;
$$;

do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'hrms' loop
    execute format('alter table hrms.%I enable row level security', r.tablename);
  end loop;
end $$;

select hrms.apply_api_grants();
