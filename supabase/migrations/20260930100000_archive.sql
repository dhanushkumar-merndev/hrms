-- =============================================================================
-- Annual archive (M7) and guarded annual file cleanup (M8): architecture §8,
-- design S34/S35.
--
--   * Annual periods are materialised rows (hrms.archive_periods) generated
--     from the organisation's cycle. A cycle change affects only periods not
--     generated yet and starts with an explicit transition period (EXP-019).
--   * create_archive_export freezes, in ONE locked transaction, the period's
--     report rows and its immutable file-version inventory (hashes, sizes,
--     ZIP paths) plus a manifest hash. The app downloads files through
--     audited <=60 s links, builds XLSX + ZIP on the phone, verifies every
--     hash and count, and only then acknowledges (EXP-003..011).
--   * Later changes to the period's attendance, leave or files mark jobs
--     stale, so they can no longer unlock cleanup (EXP-005/006).
--   * Cleanup deletes exactly the verified inventory in leased, idempotent
--     batches behind a persistent period write gate, with resume, abandon,
--     tombstones and assisted restore. Employee, attendance, leave, audit and
--     manifest records are never deleted (DEL-001..012).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Periods
-- -----------------------------------------------------------------------------

create table hrms.archive_periods (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  period_start date not null,
  period_end date not null,                     -- inclusive
  kind text not null check (kind in ('annual', 'transition')),
  start_month smallint not null,                -- cycle the period was generated under
  cleanup_job_id uuid,                          -- persistent write gate while a cleanup runs
  created_at timestamptz not null default now(),
  unique (org_id, period_start),
  check (period_end >= period_start),
  constraint archive_periods_no_overlap exclude using gist (
    org_id with =, daterange(period_start, period_end, '[]') with &&
  )
);

-- Bounds are immutable once generated; only the cleanup gate may change.
create or replace function hrms.archive_periods_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or new.period_start <> old.period_start or new.period_end <> old.period_end
     or new.kind <> old.kind or new.org_id <> old.org_id then
    raise exception 'HRMS: archive periods are immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger archive_periods_guard before update or delete on hrms.archive_periods
  for each row execute function hrms.archive_periods_guard();

-- '2025' (Jan–Dec), '2025-26' (Apr–Mar), otherwise explicit dates.
create or replace function hrms.period_label(p_start date, p_end date) returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when extract(day from p_start) = 1 and p_end = (p_start + interval '1 year - 1 day')::date then
      case when extract(month from p_start) = 1 then to_char(p_start, 'YYYY')
           else to_char(p_start, 'YYYY') || '-' || to_char(p_end, 'YY') end
    else to_char(p_start, 'YYYY-MM-DD') || ' to ' || to_char(p_end, 'YYYY-MM-DD')
  end;
$$;

-- Generates missing periods (backwards to the earliest joining date, forwards
-- to the period containing today) under the CURRENT cycle. A first period
-- that does not start on the cycle month is a transition period.
create or replace function hrms.ensure_archive_periods(p_org uuid) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org hrms.organizations;
  v_today date;
  v_first date;
  v_last date;
  v_earliest date;
  v_start date;
  v_next date;
  v_sm integer;
  i integer := 0;
begin
  select * into v_org from hrms.organizations where id = p_org for no key update;
  if not found then return; end if;
  v_sm := v_org.annual_start_month;
  v_today := hrms.org_today(p_org);
  select min(period_start), max(period_end) into v_first, v_last from hrms.archive_periods where org_id = p_org;
  select least(coalesce(min(e.join_date), v_today), v_today) into v_earliest
  from hrms.employees e where e.org_id = p_org and e.status <> 'pending';

  if v_first is null then
    v_start := make_date(extract(year from v_earliest)::integer
                         - case when extract(month from v_earliest)::integer < v_sm then 1 else 0 end, v_sm, 1);
    v_last := v_start - 1;
  else
    while v_earliest < v_first and i < 100 loop
      v_start := make_date(extract(year from (v_first - 1))::integer
                           - case when extract(month from (v_first - 1))::integer < v_sm then 1 else 0 end, v_sm, 1);
      insert into hrms.archive_periods (org_id, period_start, period_end, kind, start_month)
      values (p_org, v_start, v_first - 1,
              case when extract(month from v_first)::integer = v_sm and extract(day from v_first) = 1
                   then 'annual' else 'transition' end, v_sm)
      on conflict do nothing;
      v_first := v_start;
      i := i + 1;
    end loop;
  end if;

  v_start := v_last + 1;
  while v_start <= v_today and i < 200 loop
    v_next := make_date(extract(year from v_start)::integer, v_sm, 1);
    if v_next <= v_start then v_next := (v_next + interval '1 year')::date; end if;
    insert into hrms.archive_periods (org_id, period_start, period_end, kind, start_month)
    values (p_org, v_start, v_next - 1,
            case when extract(month from v_start)::integer = v_sm and extract(day from v_start) = 1
                 then 'annual' else 'transition' end, v_sm)
    on conflict do nothing;
    v_start := v_next;
    i := i + 1;
  end loop;
end;
$$;

-- Before the cycle changes, freeze every period up to today under the OLD
-- cycle; the change then only shapes future periods (EXP-019). This makes
-- the earlier "block the change once exports exist" rule unnecessary.
create or replace function hrms.organizations_cycle_change() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.annual_start_month is distinct from old.annual_start_month then
    perform hrms.ensure_archive_periods(old.id);
  end if;
  return new;
end;
$$;
create trigger organizations_cycle_change before update of annual_start_month on hrms.organizations
  for each row execute function hrms.organizations_cycle_change();

create or replace function hrms.org_has_export_jobs(p_org uuid) returns boolean
language sql stable set search_path = '' as $$ select false; $$;

-- Preview of how a cycle change would continue from the periods on record.
create or replace function public.preview_annual_cycle(p_start_month integer) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_last date;
  v_start date;
  v_next date;
  v_rows jsonb := '[]'::jsonb;
begin
  perform hrms.require_admin(v_actor);
  if p_start_month not in (1, 4) then
    perform hrms.raise_error('VALIDATION_FAILED', 'January or April.', '{"annual_start_month":"January or April"}'::jsonb);
  end if;
  perform hrms.ensure_archive_periods(v_actor.org_id);
  select max(period_end) into v_last from hrms.archive_periods where org_id = v_actor.org_id;
  v_start := coalesce(v_last, hrms.org_today(v_actor.org_id)) + 1;
  for i in 1 .. 2 loop
    v_next := make_date(extract(year from v_start)::integer, p_start_month, 1);
    if v_next <= v_start then v_next := (v_next + interval '1 year')::date; end if;
    v_rows := v_rows || jsonb_build_object('period_start', v_start, 'period_end', v_next - 1,
      'label', hrms.period_label(v_start, v_next - 1),
      'kind', case when extract(month from v_start)::integer = p_start_month and extract(day from v_start) = 1
                   then 'annual' else 'transition' end);
    v_start := v_next;
  end loop;
  return hrms.ok(jsonb_build_object('current_period_end', v_last, 'next_periods', v_rows));
end;
$$;

-- -----------------------------------------------------------------------------
-- Export jobs: frozen employees/rows and file inventory
-- -----------------------------------------------------------------------------

create table hrms.export_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  period_id uuid not null references hrms.archive_periods(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  timezone text not null,
  revision integer not null,
  state text not null check (state in ('ready', 'acknowledged', 'partial', 'superseded', 'cancelled')),
  provisional boolean not null default false,
  live_until timestamptz,
  requires_local_base boolean not null default false,
  base_export_id uuid references hrms.export_jobs(id) on delete restrict,
  as_of timestamptz not null,
  manifest_hash text not null,
  file_count integer not null default 0,
  total_bytes bigint not null default 0,
  local_base_count integer not null default 0,
  row_counts jsonb not null default '{}'::jsonb,
  exclusions jsonb not null default '[]'::jsonb,
  missing_file_ids uuid[],
  stale_at timestamptz,
  stale_reason text,
  ready_expires_at timestamptz not null,
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  cleanup_consumed_at timestamptz,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  version integer not null default 1,
  unique (period_id, revision)
);
create index export_jobs_org_period_idx on hrms.export_jobs (org_id, period_start, period_end);

create table hrms.export_employees (
  job_id uuid not null references hrms.export_jobs(id) on delete restrict,
  employee_id uuid not null references hrms.employees(id) on delete restrict,
  employee_code text not null,
  full_name text not null,
  folder text not null,
  status text not null,
  profile jsonb not null,
  attendance jsonb not null,
  leave jsonb not null,
  totals jsonb not null,
  attendance_count integer not null,
  leave_count integer not null,
  primary key (job_id, employee_id),
  unique (job_id, folder)
);

create table hrms.export_items (
  id bigint generated always as identity primary key,
  job_id uuid not null references hrms.export_jobs(id) on delete restrict,
  file_version_id uuid not null references hrms.file_versions(id) on delete restrict,
  employee_id uuid,
  class text not null,
  business_date date not null,
  path text not null,
  size_bytes bigint not null,
  sha256 text not null,
  version_state text not null,
  source text not null check (source in ('cloud', 'local_base')),
  unique (job_id, file_version_id),
  unique (job_id, path)
);

create trigger export_employees_append_only before update or delete on hrms.export_employees
  for each row execute function hrms.forbid_mutation();
create trigger export_items_append_only before update or delete on hrms.export_items
  for each row execute function hrms.forbid_mutation();
create trigger export_jobs_no_delete before delete on hrms.export_jobs
  for each row execute function hrms.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Cleanup jobs and their immutable inventory
-- -----------------------------------------------------------------------------

create table hrms.cleanup_jobs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  export_job_id uuid not null references hrms.export_jobs(id) on delete restrict,
  period_id uuid not null references hrms.archive_periods(id) on delete restrict,
  state text not null check (state in ('running', 'completed', 'abandoned', 'abandoned_with_partial_deletions')),
  driver_id uuid not null references hrms.employees(id) on delete restrict,
  lease_token uuid,
  lease_until timestamptz,
  total_items integer not null,
  total_bytes bigint not null,
  deleted_items integer not null default 0,
  deleted_bytes bigint not null default 0,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  abandoned_by uuid,
  abandoned_at timestamptz,
  abandon_reason text check (char_length(abandon_reason) <= 500),
  version integer not null default 1
);
create unique index cleanup_jobs_one_running on hrms.cleanup_jobs (period_id) where state = 'running';
create unique index cleanup_jobs_one_per_export on hrms.cleanup_jobs (export_job_id);
create trigger cleanup_jobs_no_delete before delete on hrms.cleanup_jobs
  for each row execute function hrms.forbid_mutation();

alter table hrms.archive_periods add constraint archive_periods_cleanup_fk
  foreign key (cleanup_job_id) references hrms.cleanup_jobs(id) on delete restrict;

create table hrms.cleanup_items (
  id bigint generated always as identity primary key,
  cleanup_job_id uuid not null references hrms.cleanup_jobs(id) on delete restrict,
  file_version_id uuid not null references hrms.file_versions(id) on delete restrict,
  path text not null,
  bucket text not null,
  object_key text not null,
  size_bytes bigint not null,
  prev_state text not null check (prev_state in ('published', 'superseded')),
  state text not null default 'pending' check (state in ('pending', 'deleting', 'deleted', 'failed', 'released')),
  claimed_by uuid,
  attempts integer not null default 0,
  last_error text check (char_length(last_error) <= 300),
  updated_at timestamptz not null default now(),
  unique (cleanup_job_id, file_version_id)
);
create index cleanup_items_job_state_idx on hrms.cleanup_items (cleanup_job_id, state, id);
create trigger cleanup_items_no_delete before delete on hrms.cleanup_items
  for each row execute function hrms.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Staleness and the period write gate
-- -----------------------------------------------------------------------------

create or replace function hrms.mark_exports_stale(p_org uuid, p_from date, p_to date, p_reason text) returns void
language sql
security definer
set search_path = ''
as $$
  update hrms.export_jobs j
     set stale_at = now(), stale_reason = left(p_reason, 200), version = j.version + 1
   where j.org_id = p_org and j.stale_at is null and j.state in ('ready', 'acknowledged', 'partial')
     and p_from is not null and j.period_start <= coalesce(p_to, p_from) and j.period_end >= p_from;
$$;

-- Business-date changes after a snapshot invalidate that snapshot for
-- cleanup. Profile edits do not: the profile is labelled "as of export".
create or replace function hrms.export_stale_trigger() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
begin
  if coalesce(current_setting('hrms.cleanup_worker', true), '') = 'on' then
    return null;
  end if;
  if tg_table_name = 'attendance_sessions' then
    perform hrms.mark_exports_stale(new.org_id, new.shift_date, new.shift_date, 'Attendance changed after the export');
  elsif tg_table_name = 'requests' then
    if new.kind = 'leave' then
      perform hrms.mark_exports_stale(new.org_id, new.start_date, new.end_date, 'Leave changed after the export');
      if tg_op = 'UPDATE' and (old.start_date, old.end_date) is distinct from (new.start_date, new.end_date) then
        perform hrms.mark_exports_stale(old.org_id, old.start_date, old.end_date, 'Leave changed after the export');
      end if;
    end if;
  elsif tg_table_name = 'file_versions' then
    if new.state = 'published' and (tg_op = 'INSERT' or old.state is distinct from 'published') then
      select coalesce(r.period_start, r.document_date) into v_day from hrms.file_records r
      where r.id = new.file_record_id and r.class in ('payslip', 'employee_document');
      perform hrms.mark_exports_stale(new.org_id, v_day, v_day, 'Files changed after the export');
    end if;
  end if;
  return null;
end;
$$;
create trigger attendance_sessions_export_stale after insert or update on hrms.attendance_sessions
  for each row execute function hrms.export_stale_trigger();
create trigger requests_export_stale after insert or update on hrms.requests
  for each row execute function hrms.export_stale_trigger();
create trigger file_versions_export_stale after insert or update of state on hrms.file_versions
  for each row execute function hrms.export_stale_trigger();

-- Deleted versions are terminal, and while a cleanup runs no file of that
-- period may be uploaded, validated, published or replaced (PERIOD_BUSY,
-- retryable). Housekeeping transitions (rejected) are never blocked.
create or replace function hrms.file_versions_archive_guard() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
begin
  if tg_op = 'UPDATE' and old.state = 'deleted' and new.state is distinct from 'deleted' then
    raise exception 'HRMS: deleted file versions are terminal' using errcode = '42501';
  end if;
  if coalesce(current_setting('hrms.cleanup_worker', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'UPDATE' and (new.state is not distinct from old.state
                           or new.state not in ('validated', 'published', 'superseded')) then
    return new;
  end if;
  if tg_op = 'INSERT' and new.state not in ('requested', 'validated', 'published') then
    return new;
  end if;
  select coalesce(r.period_start, r.document_date) into v_day from hrms.file_records r
  where r.id = new.file_record_id and r.class in ('payslip', 'employee_document');
  if v_day is not null and exists (
       select 1 from hrms.archive_periods p
       where p.org_id = new.org_id and p.cleanup_job_id is not null and v_day between p.period_start and p.period_end) then
    perform hrms.raise_error('PERIOD_BUSY', 'Files for this period are being cleaned up. Try again later.', null, true);
  end if;
  return new;
end;
$$;
create trigger file_versions_archive_guard before insert or update on hrms.file_versions
  for each row execute function hrms.file_versions_archive_guard();

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- Last permitted checkout of any required schedule starting in the period.
create or replace function hrms.period_live_until(p_org uuid, p_start date, p_end date) returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select max(w.end_at + make_interval(secs => w.checkout_extension_seconds))
  from hrms.work_schedule_instances w
  where w.org_id = p_org and w.shift_date between p_start and p_end and w.is_required;
$$;

-- Safe ZIP path segment: ASCII allowlist, no leading/trailing dots or spaces,
-- never empty, bounded length. Employee codes keep folders collision free.
create or replace function hrms.archive_segment(p text, p_max integer) returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(left(regexp_replace(
           regexp_replace(left(coalesce(p, ''), 300), '[^A-Za-z0-9 ._()-]', '_', 'g'),
           '^[. ]+|[. ]+$', '', 'g'), p_max), ''), 'file');
$$;

create or replace function hrms.mime_ext(p_mime text) returns text
language sql
immutable
set search_path = ''
as $$
  select case p_mime when 'application/pdf' then '.pdf' when 'image/jpeg' then '.jpg'
                     when 'image/png' then '.png' when 'image/webp' then '.webp' else '' end;
$$;

create or replace function hrms.cleanup_job_json(c hrms.cleanup_jobs) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', c.id, 'export_job_id', c.export_job_id, 'period_id', c.period_id, 'state', c.state,
    'label', (select hrms.period_label(p.period_start, p.period_end) from hrms.archive_periods p where p.id = c.period_id),
    'total_items', c.total_items, 'total_bytes', c.total_bytes,
    'deleted_items', c.deleted_items, 'deleted_bytes', c.deleted_bytes,
    'pending_items', (select count(*) from hrms.cleanup_items i where i.cleanup_job_id = c.id and i.state = 'pending'),
    'in_flight_items', (select count(*) from hrms.cleanup_items i where i.cleanup_job_id = c.id and i.state = 'deleting'),
    'failed_items', (select count(*) from hrms.cleanup_items i where i.cleanup_job_id = c.id and i.state = 'failed'),
    'released_items', (select count(*) from hrms.cleanup_items i where i.cleanup_job_id = c.id and i.state = 'released'),
    'driver', (select jsonb_build_object('id', e.id, 'name', e.full_name) from hrms.employees e where e.id = c.driver_id),
    'lease_active', coalesce(c.lease_until > now(), false), 'lease_until', c.lease_until,
    'created_at', c.created_at, 'finished_at', c.finished_at,
    'abandoned_at', c.abandoned_at, 'abandon_reason', c.abandon_reason, 'version', c.version);
$$;

create or replace function hrms.export_job_json(j hrms.export_jobs) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', j.id, 'period_id', j.period_id, 'period_start', j.period_start, 'period_end', j.period_end,
    'label', hrms.period_label(j.period_start, j.period_end), 'revision', j.revision,
    'state', case when j.state = 'ready' and j.ready_expires_at < now() then 'expired' else j.state end,
    'stale', j.stale_at is not null, 'stale_at', j.stale_at, 'stale_reason', j.stale_reason,
    'provisional', coalesce(j.live_until > now(), false), 'live_until', j.live_until,
    'as_of', j.as_of, 'timezone', j.timezone, 'file_count', j.file_count, 'total_bytes', j.total_bytes,
    'local_base_count', j.local_base_count, 'requires_local_base', j.requires_local_base,
    'base_export_id', j.base_export_id,
    'base', (select jsonb_build_object('id', b.id, 'revision', b.revision, 'manifest_hash', b.manifest_hash)
             from hrms.export_jobs b where b.id = j.base_export_id),
    'manifest_hash', j.manifest_hash, 'row_counts', j.row_counts, 'exclusions', j.exclusions,
    'missing_file_ids', to_jsonb(j.missing_file_ids),
    'ready_expires_at', j.ready_expires_at, 'acknowledged_at', j.acknowledged_at,
    'acknowledged_by', (select jsonb_build_object('id', e.id, 'name', e.full_name) from hrms.employees e
                        where e.id = j.acknowledged_by),
    'cleanup_consumed', j.cleanup_consumed_at is not null,
    'cleanup', (select hrms.cleanup_job_json(c) from hrms.cleanup_jobs c where c.export_job_id = j.id),
    'created_at', j.created_at,
    'created_by', (select jsonb_build_object('id', e.id, 'name', e.full_name) from hrms.employees e where e.id = j.created_by),
    'version', j.version);
$$;

-- -----------------------------------------------------------------------------
-- S34 overview
-- -----------------------------------------------------------------------------

create or replace function public.get_archive_overview() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_today date;
begin
  perform hrms.require_admin(v_actor);
  perform hrms.ensure_archive_periods(v_actor.org_id);
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_today := hrms.org_today(v_org.id);
  return hrms.ok(jsonb_build_object(
    'today', v_today, 'timezone', v_org.timezone, 'annual_start_month', v_org.annual_start_month,
    'storage', (select jsonb_build_object('used_bytes', coalesce(l.used_bytes, 0),
                                          'reserved_bytes', coalesce(l.reserved_bytes, 0),
                                          'budget_bytes', v_org.storage_budget_bytes)
                from (select 1) x left join hrms.storage_ledger l on l.org_id = v_org.id),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'period_start', p.period_start, 'period_end', p.period_end, 'kind', p.kind,
        'label', hrms.period_label(p.period_start, p.period_end),
        'closed', p.period_end < v_today, 'unlocks_on', p.period_end + 1,
        'due', p.period_end < v_today and not exists (
                 select 1 from hrms.export_jobs j where j.period_id = p.id and j.state in ('acknowledged', 'partial')
                   and j.stale_at is null),
        'live_until', hrms.period_live_until(v_org.id, p.period_start, p.period_end),
        'cleanup_running', p.cleanup_job_id is not null,
        'cleanups', (select coalesce(jsonb_agg(hrms.cleanup_job_json(c) order by c.created_at desc), '[]'::jsonb)
                     from hrms.cleanup_jobs c where c.period_id = p.id),
        'jobs', (select coalesce(jsonb_agg(hrms.export_job_json(j) order by j.revision desc), '[]'::jsonb)
                 from hrms.export_jobs j where j.period_id = p.id))
        order by p.period_start desc), '[]'::jsonb)
      from hrms.archive_periods p where p.org_id = v_org.id)));
end;
$$;

-- -----------------------------------------------------------------------------
-- Snapshot creation (Admin + recent reauthentication; bulk salary export)
-- -----------------------------------------------------------------------------

create or replace function public.create_archive_export(p_period_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_period hrms.archive_periods;
  v_org hrms.organizations;
  v_now timestamptz := clock_timestamp();
  v_job hrms.export_jobs;
  v_ids uuid[];
  v_rev integer;
  v_live timestamptz;
  v_base uuid;
  v_hash text;
  v_exclusions jsonb;
begin
  perform hrms.require_admin(v_actor);
  select * into v_period from hrms.archive_periods where id = p_period_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_period.period_end >= hrms.org_today(v_actor.org_id) then
    perform hrms.raise_error('PERIOD_NOT_CLOSED',
      format('This period can be archived from %s.', to_char(v_period.period_end + 1, 'DD Mon YYYY')));
  end if;
  if v_period.cleanup_job_id is not null then
    perform hrms.raise_error('PERIOD_BUSY', 'A file cleanup is running for this period. Resume or abandon it first.',
      null, true);
  end if;
  perform hrms.require_reauth(v_actor, 'export.annual', v_period.id, true);

  -- One consistent snapshot: writers to the period's sources wait for the
  -- few moments this takes (no network I/O happens inside).
  lock table hrms.requests, hrms.leave_day_slots, hrms.attendance_sessions, hrms.file_versions, hrms.payslips
    in share mode;

  select * into v_org from hrms.organizations where id = v_actor.org_id;
  select coalesce(array_agg(distinct x.id), '{}') into v_ids from (
    select e.id from hrms.employees e
    where e.org_id = v_org.id and e.status <> 'pending'
      and e.join_date <= v_period.period_end and (e.end_date is null or e.end_date >= v_period.period_start)
    union
    select r.owner_employee_id from hrms.file_records r
    where r.org_id = v_org.id and r.owner_employee_id is not null and r.class in ('payslip', 'employee_document')
      and coalesce(r.period_start, r.document_date) between v_period.period_start and v_period.period_end
  ) x;
  perform hrms.ensure_schedule_instances(v_org.id, v_ids, v_period.period_start, v_period.period_end);

  select coalesce(max(revision), 0) + 1 into v_rev from hrms.export_jobs where period_id = v_period.id;
  update hrms.export_jobs set state = 'superseded', version = version + 1
  where period_id = v_period.id and state = 'ready';
  v_live := hrms.period_live_until(v_org.id, v_period.period_start, v_period.period_end);
  select j.id into v_base from hrms.export_jobs j
  where j.period_id = v_period.id and j.state = 'acknowledged' order by j.revision desc limit 1;

  insert into hrms.export_jobs (org_id, period_id, period_start, period_end, timezone, revision, state, provisional,
                                live_until, as_of, manifest_hash, ready_expires_at, created_by)
  values (v_org.id, v_period.id, v_period.period_start, v_period.period_end, v_org.timezone, v_rev, 'ready',
          coalesce(v_live > v_now, false), v_live, v_now, '', v_now + interval '3 days', v_actor.employee_id)
  returning * into v_job;

  insert into hrms.export_employees (job_id, employee_id, employee_code, full_name, folder, status, profile,
                                     attendance, leave, totals, attendance_count, leave_count)
  select v_job.id, e.id, e.employee_code, e.full_name,
         'Employees/' || e.employee_code || '_' || hrms.archive_segment(e.full_name, 60), e.status,
         hrms.employee_card(e, least(v_period.period_end, hrms.org_today(v_org.id))) || jsonb_build_object(
           'status', e.status, 'join_date', e.join_date, 'end_date', e.end_date,
           'as_of', v_now, 'note', 'Profile as of the export time; it is not a historical record.'),
         att.rows, lv.rows, hrms.attendance_totals(att.rows), jsonb_array_length(att.rows), jsonb_array_length(lv.rows)
  from hrms.employees e
  cross join lateral (
    select coalesce(jsonb_agg(hrms.attendance_row_json(r) order by r.shift_date), '[]'::jsonb) as rows
    from hrms.attendance_rows(v_org.id, array[e.id], v_period.period_start, v_period.period_end, v_now) r
  ) att
  cross join lateral (
    select coalesce(jsonb_agg(jsonb_build_object(
             'request_id', r.id, 'leave_type_code', lt.code, 'leave_type', lt.name, 'paid', lt.paid,
             'start_date', r.start_date, 'end_date', r.end_date, 'state', r.state,
             'status', case r.state when 'approved' then 'Approved' when 'rejected' then 'Not approved'
                                    when 'cancelled' then 'Cancelled' when 'returned' then 'Returned (not booked)'
                                    when 'cancellation_pending' then 'Approved, cancellation pending'
                                    else 'Pending' end,
             'units_total', r.units,
             'booked_units_in_period', (select coalesce(sum(case when s.slot = 'FULL' then 2 else 1 end), 0)
                                        from hrms.leave_day_slots s
                                        where s.request_id = r.id and s.state in ('reserved', 'approved')
                                          and s.day between v_period.period_start and v_period.period_end),
             'requested_units_in_period', (select coalesce(sum((d ->> 'units')::integer), 0)
                                           from jsonb_array_elements(rv.payload -> 'days') d
                                           where (d ->> 'day')::date between v_period.period_start and v_period.period_end),
             'submitted_at', r.submitted_at, 'decided_at', r.decided_at) order by r.start_date, r.id), '[]'::jsonb) as rows
    from hrms.requests r
    join hrms.leave_types lt on lt.id = r.leave_type_id
    join hrms.request_revisions rv on rv.request_id = r.id and rv.revision_no = r.current_revision
    where r.employee_id = e.id and r.kind = 'leave' and r.state <> 'draft'
      and r.start_date <= v_period.period_end and r.end_date >= v_period.period_start
  ) lv
  where e.id = any(v_ids);

  -- Every period revision (current, superseded, and already deleted ones that
  -- must come from the previous local archive).
  insert into hrms.export_items (job_id, file_version_id, employee_id, class, business_date, path, size_bytes, sha256,
                                 version_state, source)
  select v_job.id, v.id, r.owner_employee_id, r.class, coalesce(r.period_start, r.document_date),
         ee.folder || case
           when r.class = 'payslip' and p.current_file_version_id = v.id then
             '/Payslips/' || to_char(r.period_start, 'YYYY') || '/' || to_char(r.period_start, 'YYYY-MM') || '.pdf'
           when r.class = 'payslip' then
             '/Payslips/' || to_char(r.period_start, 'YYYY') || '/Revisions/' || to_char(r.period_start, 'YYYY-MM')
               || '_v' || v.version_no || '.pdf'
           else
             '/Documents/' || to_char(r.document_date, 'YYYY') || '/' || left(replace(r.id::text, '-', ''), 12)
               || '_v' || v.version_no || '_'
               || hrms.archive_segment(regexp_replace(coalesce(r.title, v.original_filename, 'document'),
                                                      '\.[A-Za-z0-9]{1,5}$', ''), 60)
               || hrms.mime_ext(coalesce(v.detected_mime, v.declared_mime))
         end,
         v.size_bytes, v.sha256, v.state, case when v.state = 'deleted' then 'local_base' else 'cloud' end
  from hrms.file_versions v
  join hrms.file_records r on r.id = v.file_record_id
  join hrms.export_employees ee on ee.job_id = v_job.id and ee.employee_id = r.owner_employee_id
  left join hrms.payslips p on p.file_record_id = r.id
  where r.org_id = v_org.id and r.class in ('payslip', 'employee_document')
    and coalesce(r.period_start, r.document_date) between v_period.period_start and v_period.period_end
    and v.state in ('published', 'superseded', 'deleted')
    and v.sha256 is not null and v.size_bytes is not null;

  v_exclusions := jsonb_build_array(
    jsonb_build_object('kind', 'avatar', 'label', 'Profile photos (not period records)',
      'count', (select count(*) from hrms.file_records r where r.org_id = v_org.id and r.class = 'avatar')),
    jsonb_build_object('kind', 'company_policy', 'label', 'Company policy documents (reusable, undated)',
      'count', (select count(*) from hrms.file_records r where r.org_id = v_org.id and r.class = 'company_policy')),
    jsonb_build_object('kind', 'undated_document', 'label', 'Employee documents without a document date',
      'count', (select count(*) from hrms.file_records r where r.org_id = v_org.id and r.class = 'employee_document'
                  and r.document_date is null)),
    jsonb_build_object('kind', 'request_attachment', 'label', 'Leave/correction attachments (kept with their requests)',
      'count', (select count(*) from hrms.file_records r where r.org_id = v_org.id
                  and r.class in ('leave_attachment', 'medical_attachment', 'correction_attachment'))));

  -- Canonical manifest (mirrored byte for byte by the app).
  select hrms.sha256_hex(concat_ws(E'\n',
    'hrms-archive-v1',
    'job:' || v_job.id::text,
    'period:' || to_char(v_period.period_start, 'YYYY-MM-DD') || '..' || to_char(v_period.period_end, 'YYYY-MM-DD'),
    'revision:' || v_rev::text,
    (select string_agg('file:' || i.path || '|' || i.size_bytes::text || '|' || i.sha256 || '|'
                       || i.file_version_id::text || '|' || i.source, E'\n' order by i.path collate "C")
     from hrms.export_items i where i.job_id = v_job.id),
    (select string_agg('employee:' || x.employee_id::text || '|' || x.attendance_count::text || '|'
                       || x.leave_count::text, E'\n' order by x.employee_id::text collate "C")
     from hrms.export_employees x where x.job_id = v_job.id)))
    into v_hash;

  update hrms.export_jobs j set
    manifest_hash = v_hash,
    file_count = (select count(*) from hrms.export_items i where i.job_id = j.id),
    total_bytes = (select coalesce(sum(i.size_bytes), 0) from hrms.export_items i where i.job_id = j.id),
    local_base_count = (select count(*) from hrms.export_items i where i.job_id = j.id and i.source = 'local_base'),
    requires_local_base = exists (select 1 from hrms.export_items i where i.job_id = j.id and i.source = 'local_base'),
    base_export_id = case when exists (select 1 from hrms.export_items i where i.job_id = j.id and i.source = 'local_base')
                          then v_base end,
    row_counts = jsonb_build_object(
      'employees', (select count(*) from hrms.export_employees x where x.job_id = j.id),
      'attendance_rows', (select coalesce(sum(x.attendance_count), 0) from hrms.export_employees x where x.job_id = j.id),
      'leave_rows', (select coalesce(sum(x.leave_count), 0) from hrms.export_employees x where x.job_id = j.id)),
    exclusions = v_exclusions
  where j.id = v_job.id
  returning * into v_job;

  perform hrms.audit(v_org.id, v_actor.employee_id, 'archive.export_created', 'export_job', v_job.id,
    jsonb_build_object('period', hrms.period_label(v_job.period_start, v_job.period_end), 'revision', v_rev,
                       'files', v_job.file_count, 'bytes', v_job.total_bytes, 'local_base', v_job.local_base_count),
    'security');
  return hrms.ok(hrms.export_job_json(v_job), v_job.version);
end;
$$;

create or replace function hrms.export_job_for_admin(p_actor hrms.actor, p_job_id uuid) returns hrms.export_jobs
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_job hrms.export_jobs;
begin
  perform hrms.require_admin(p_actor);
  select * into v_job from hrms.export_jobs where id = p_job_id and org_id = p_actor.org_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return v_job;
end;
$$;

-- Manifest for the app: items, employees and the canonical inputs.
create or replace function public.get_export_manifest(p_job_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
begin
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'archive.manifest_viewed', 'export_job', v_job.id, null, 'access');
  return hrms.ok(hrms.export_job_json(v_job) || jsonb_build_object(
    'org', (select jsonb_build_object('name', o.name, 'code', o.code) from hrms.organizations o where o.id = v_job.org_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'file_version_id', i.file_version_id, 'employee_id', i.employee_id, 'class', i.class,
                'business_date', i.business_date, 'path', i.path, 'size_bytes', i.size_bytes, 'sha256', i.sha256,
                'source', i.source, 'version_state', i.version_state) order by i.path collate "C"), '[]'::jsonb)
              from hrms.export_items i where i.job_id = v_job.id),
    'employees', (select coalesce(jsonb_agg(jsonb_build_object(
                    'employee_id', x.employee_id, 'code', x.employee_code, 'name', x.full_name, 'folder', x.folder,
                    'status', x.status, 'attendance_count', x.attendance_count, 'leave_count', x.leave_count,
                    'totals', x.totals) order by x.employee_id::text collate "C"), '[]'::jsonb)
                  from hrms.export_employees x where x.job_id = v_job.id)), v_job.version);
end;
$$;

-- Frozen rows of one employee (paged by employee to bound responses).
create or replace function public.get_export_employee(p_job_id uuid, p_employee_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
  v_row hrms.export_employees;
begin
  select * into v_row from hrms.export_employees where job_id = v_job.id and employee_id = p_employee_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok(jsonb_build_object('employee_id', v_row.employee_id, 'code', v_row.employee_code,
    'name', v_row.full_name, 'folder', v_row.folder, 'profile', v_row.profile, 'attendance', v_row.attendance,
    'leave', v_row.leave, 'totals', v_row.totals));
end;
$$;

-- Audited <=60 s link for one inventoried cloud file (archive Edge Function).
create or replace function public.internal_authorize_export_file(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_job_id uuid, p_file_version_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
  v_item hrms.export_items;
  v_ver hrms.file_versions;
  v_grant uuid;
begin
  if v_job.state not in ('ready', 'acknowledged', 'partial') or (v_job.state = 'ready' and v_job.ready_expires_at < now()) then
    perform hrms.raise_error('ARCHIVE_INCOMPLETE', 'This export is no longer active. Create a new export.');
  end if;
  select * into v_item from hrms.export_items where job_id = v_job.id and file_version_id = p_file_version_id;
  if not found or v_item.source <> 'cloud' then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_ver from hrms.file_versions where id = p_file_version_id;
  if v_ver.state not in ('published', 'superseded') or v_ver.object_key is null then
    return jsonb_build_object('available', false, 'message', 'This file is no longer in cloud storage.');
  end if;
  insert into hrms.file_access_grants (org_id, actor_id, file_version_id, purpose, link_ttl_seconds)
  values (v_actor.org_id, v_actor.employee_id, v_ver.id, 'export', 60)
  returning id into v_grant;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.access_granted', 'file_version', v_ver.id,
    jsonb_build_object('purpose', 'export', 'export_job_id', v_job.id, 'grant_id', v_grant), 'access',
    v_item.employee_id);
  return jsonb_build_object('available', true, 'grant_id', v_grant, 'bucket', 'hrms-files', 'object_key', v_ver.object_key,
                            'size_bytes', v_item.size_bytes, 'sha256', v_item.sha256);
end;
$$;

-- The app verified every hash/count and the Admin confirmed a saved copy.
-- A partial archive (previous local originals unavailable) is recorded but
-- can never unlock cleanup (EXP-017).
create or replace function public.acknowledge_export(
  p_job_id uuid, p_manifest_hash text, p_included_files integer, p_included_bytes bigint,
  p_partial boolean, p_missing_file_ids uuid[], p_saved boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
  v_missing_count integer := coalesce(cardinality(p_missing_file_ids), 0);
  v_missing_bytes bigint;
  v_valid_missing integer;
begin
  select * into v_job from hrms.export_jobs where id = v_job.id for update;
  if v_job.state in ('acknowledged', 'partial') and v_job.manifest_hash = p_manifest_hash then
    return hrms.ok(hrms.export_job_json(v_job), v_job.version);     -- idempotent replay
  end if;
  if v_job.state <> 'ready' or v_job.ready_expires_at < now() then
    perform hrms.raise_error('ARCHIVE_INCOMPLETE', 'This export is no longer active. Create a new export.');
  end if;
  if v_job.stale_at is not null then
    perform hrms.raise_error('ARCHIVE_STALE', 'Records for this period changed after the export. Create a new export.');
  end if;
  if not coalesce(p_saved, false) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Confirm that you saved a copy of the archive.',
      '{"saved":"Required"}'::jsonb);
  end if;
  if coalesce(p_partial, false) then
    if not v_job.requires_local_base or v_missing_count = 0 then
      perform hrms.raise_error('VALIDATION_FAILED', 'Only archives missing earlier local originals can be partial.');
    end if;
    select count(*), coalesce(sum(i.size_bytes), 0) into v_valid_missing, v_missing_bytes
    from hrms.export_items i where i.job_id = v_job.id and i.source = 'local_base'
      and i.file_version_id = any(p_missing_file_ids);
    if v_valid_missing <> v_missing_count then
      perform hrms.raise_error('ARCHIVE_INCOMPLETE', 'Missing files must be earlier local originals of this export.');
    end if;
  else
    v_missing_count := 0;
    v_missing_bytes := 0;
  end if;
  if p_manifest_hash is distinct from v_job.manifest_hash
     or p_included_files is distinct from v_job.file_count - v_missing_count
     or p_included_bytes is distinct from v_job.total_bytes - v_missing_bytes then
    perform hrms.raise_error('ARCHIVE_INCOMPLETE', 'The verified archive does not match the server manifest.');
  end if;
  update hrms.export_jobs
     set state = case when coalesce(p_partial, false) then 'partial' else 'acknowledged' end,
         missing_file_ids = case when coalesce(p_partial, false) then p_missing_file_ids end,
         acknowledged_at = now(), acknowledged_by = v_actor.employee_id, version = version + 1
   where id = v_job.id
  returning * into v_job;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when v_job.state = 'partial' then 'archive.acknowledged_partial' else 'archive.acknowledged' end,
    'export_job', v_job.id, jsonb_build_object('manifest_hash', v_job.manifest_hash, 'files', p_included_files,
                                               'missing', v_missing_count), 'security');
  return hrms.ok(hrms.export_job_json(v_job), v_job.version);
end;
$$;

create or replace function public.cancel_export(p_job_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
begin
  update hrms.export_jobs set state = 'cancelled', version = version + 1
  where id = v_job.id and state = 'ready'
  returning * into v_job;
  if not found then
    select * into v_job from hrms.export_jobs where id = p_job_id;
  else
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'archive.export_cancelled', 'export_job', v_job.id, null);
  end if;
  return hrms.ok(hrms.export_job_json(v_job), v_job.version);
end;
$$;

-- -----------------------------------------------------------------------------
-- Cleanup gates, preview and start
-- -----------------------------------------------------------------------------

-- Every gate with its outcome; the first failing gate decides the error.
create or replace function hrms.cleanup_checks(p_job hrms.export_jobs) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with p as (select * from hrms.archive_periods where id = p_job.period_id),
  live as (select hrms.period_live_until(p_job.org_id, p_job.period_start, p_job.period_end) as until)
  select jsonb_build_array(
    jsonb_build_object('key', 'closed', 'code', 'PERIOD_NOT_CLOSED',
      'ok', p_job.period_end < hrms.org_today(p_job.org_id), 'label', 'The period has ended'),
    jsonb_build_object('key', 'acknowledged', 'code', 'ARCHIVE_INCOMPLETE',
      'ok', p_job.state = 'acknowledged', 'label', 'A complete archive was verified and saved'),
    jsonb_build_object('key', 'latest', 'code', 'ARCHIVE_STALE',
      'ok', not exists (select 1 from hrms.export_jobs j where j.period_id = p_job.period_id
                          and j.revision > p_job.revision
                          and (j.state in ('acknowledged', 'partial') or (j.state = 'ready' and j.ready_expires_at > now()))),
      'label', 'This is the newest archive for the period'),
    jsonb_build_object('key', 'fresh', 'code', 'ARCHIVE_STALE',
      'ok', p_job.stale_at is null, 'label', 'No records changed after the export'),
    jsonb_build_object('key', 'not_live', 'code', 'PERIOD_BUSY',
      'ok', coalesce((select until from live) <= now(), true),
      'label', 'No shift from the period can still be punched'),
    jsonb_build_object('key', 'unused', 'code', 'ARCHIVE_STALE',
      'ok', p_job.cleanup_consumed_at is null, 'label', 'This archive was not used for an earlier cleanup'),
    jsonb_build_object('key', 'no_running', 'code', 'PERIOD_BUSY',
      'ok', (select cleanup_job_id is null from p), 'label', 'No other cleanup is running for the period'));
$$;

create or replace function public.preview_cleanup(p_job_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
  v_window date := hrms.payslip_window_start(v_actor.org_id);
begin
  return hrms.ok(jsonb_build_object(
    'job', hrms.export_job_json(v_job),
    'confirm_label', hrms.period_label(v_job.period_start, v_job.period_end),
    'checks', hrms.cleanup_checks(v_job),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('file_version_id', i.file_version_id, 'path', i.path,
                'size_bytes', i.size_bytes, 'class', i.class, 'business_date', i.business_date)
                order by i.path collate "C"), '[]'::jsonb)
              from hrms.export_items i join hrms.file_versions v on v.id = i.file_version_id
              where i.job_id = v_job.id and i.source = 'cloud' and v.state in ('published', 'superseded')),
    'item_count', (select count(*) from hrms.export_items i join hrms.file_versions v on v.id = i.file_version_id
                   where i.job_id = v_job.id and i.source = 'cloud' and v.state in ('published', 'superseded')),
    'total_bytes', (select coalesce(sum(i.size_bytes), 0) from hrms.export_items i
                    join hrms.file_versions v on v.id = i.file_version_id
                    where i.job_id = v_job.id and i.source = 'cloud' and v.state in ('published', 'superseded')),
    'employee_count', (select count(distinct i.employee_id) from hrms.export_items i where i.job_id = v_job.id),
    'already_archived_locally', v_job.local_base_count,
    'visible_payslips', (select count(*) from hrms.export_items i join hrms.file_versions v on v.id = i.file_version_id
                         where i.job_id = v_job.id and i.source = 'cloud' and i.class = 'payslip'
                           and v.state = 'published' and i.business_date >= v_window),
    'kept', jsonb_build_array('Employee records and profiles', 'Attendance, corrections and leave records',
                              'Leave balances and ledger', 'Audit history', 'File metadata and archive manifests'),
    'exclusions', v_job.exclusions));
end;
$$;

-- Starts the destructive cleanup of exactly the verified inventory.
create or replace function public.begin_cleanup(
  p_job_id uuid, p_manifest_hash text, p_confirm_label text, p_accept_visible_loss boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_job hrms.export_jobs := hrms.export_job_for_admin(v_actor, p_job_id);
  v_period hrms.archive_periods;
  v_existing hrms.cleanup_jobs;
  v_cleanup hrms.cleanup_jobs;
  v_check jsonb;
  v_visible integer;
begin
  select * into v_period from hrms.archive_periods where id = v_job.period_id for update;
  select * into v_job from hrms.export_jobs where id = v_job.id for update;

  -- Replay of an already started/finished cleanup never deletes anything new.
  select * into v_existing from hrms.cleanup_jobs where export_job_id = v_job.id;
  if found then
    return hrms.ok(hrms.cleanup_job_json(v_existing), v_existing.version);
  end if;

  if p_manifest_hash is distinct from v_job.manifest_hash then
    perform hrms.raise_error('ARCHIVE_INCOMPLETE', 'The archive you verified does not match this export.');
  end if;
  for v_check in select value from jsonb_array_elements(hrms.cleanup_checks(v_job)) loop
    if not (v_check ->> 'ok')::boolean then
      perform hrms.raise_error(v_check ->> 'code', v_check ->> 'label', jsonb_build_object('gate', v_check ->> 'key'),
                               v_check ->> 'code' = 'PERIOD_BUSY');
    end if;
  end loop;
  if upper(btrim(coalesce(p_confirm_label, ''))) <> upper(hrms.period_label(v_job.period_start, v_job.period_end)) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Type the period exactly as shown to confirm.',
      '{"confirm_label":"Does not match"}'::jsonb);
  end if;
  select count(*) into v_visible from hrms.export_items i join hrms.file_versions v on v.id = i.file_version_id
  where i.job_id = v_job.id and i.source = 'cloud' and i.class = 'payslip' and v.state = 'published'
    and i.business_date >= hrms.payslip_window_start(v_actor.org_id);
  if v_visible > 0 and not coalesce(p_accept_visible_loss, false) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Confirm that recent payslips will show as archived.',
      '{"accept_visible_loss":"Required"}'::jsonb);
  end if;
  perform hrms.require_reauth(v_actor, 'archive.cleanup', v_job.id, true);

  perform set_config('hrms.cleanup_worker', 'on', true);
  insert into hrms.cleanup_jobs (org_id, export_job_id, period_id, state, driver_id, total_items, total_bytes, created_by)
  values (v_job.org_id, v_job.id, v_period.id, 'running', v_actor.employee_id, 0, 0, v_actor.employee_id)
  returning * into v_cleanup;
  insert into hrms.cleanup_items (cleanup_job_id, file_version_id, path, bucket, object_key, size_bytes, prev_state)
  select v_cleanup.id, v.id, i.path, 'hrms-files', v.object_key, i.size_bytes, v.state
  from hrms.export_items i join hrms.file_versions v on v.id = i.file_version_id
  where i.job_id = v_job.id and i.source = 'cloud' and v.state in ('published', 'superseded') and v.object_key is not null;
  if not found then
    perform hrms.raise_error('VALIDATION_FAILED', 'There are no cloud files left to clean up for this archive.');
  end if;
  update hrms.cleanup_jobs c set
    total_items = (select count(*) from hrms.cleanup_items i where i.cleanup_job_id = c.id),
    total_bytes = (select coalesce(sum(i.size_bytes), 0) from hrms.cleanup_items i where i.cleanup_job_id = c.id)
  where c.id = v_cleanup.id
  returning * into v_cleanup;
  update hrms.file_versions v set state = 'deletion_pending'
  from hrms.cleanup_items i where i.cleanup_job_id = v_cleanup.id and v.id = i.file_version_id;
  update hrms.archive_periods set cleanup_job_id = v_cleanup.id where id = v_period.id;
  update hrms.export_jobs set cleanup_consumed_at = now(), version = version + 1 where id = v_job.id;
  perform set_config('hrms.cleanup_worker', 'off', true);

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'archive.cleanup_started', 'cleanup_job', v_cleanup.id,
    jsonb_build_object('export_job_id', v_job.id, 'items', v_cleanup.total_items, 'bytes', v_cleanup.total_bytes,
                       'period', hrms.period_label(v_job.period_start, v_job.period_end)), 'security');
  return hrms.ok(hrms.cleanup_job_json(v_cleanup), v_cleanup.version);
end;
$$;

create or replace function public.get_cleanup_job(p_cleanup_job_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_c hrms.cleanup_jobs;
begin
  perform hrms.require_admin(v_actor);
  select * into v_c from hrms.cleanup_jobs where id = p_cleanup_job_id and org_id = v_actor.org_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok(hrms.cleanup_job_json(v_c) || jsonb_build_object(
    'is_driver', v_c.driver_id = v_actor.employee_id,
    'failed', (select coalesce(jsonb_agg(jsonb_build_object('path', i.path, 'attempts', i.attempts,
                 'error', i.last_error) order by i.id), '[]'::jsonb)
               from hrms.cleanup_items i where i.cleanup_job_id = v_c.id and i.state = 'failed')), v_c.version);
end;
$$;

-- Marks a finished cleanup and clears the period gate.
create or replace function hrms.finish_cleanup(p_cleanup_job_id uuid, p_actor uuid) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c hrms.cleanup_jobs;
begin
  update hrms.cleanup_jobs set state = 'completed', finished_at = now(), lease_token = null, lease_until = null,
                               version = version + 1
  where id = p_cleanup_job_id and state = 'running'
  returning * into v_c;
  if found then
    update hrms.archive_periods set cleanup_job_id = null where cleanup_job_id = v_c.id;
    perform hrms.audit(v_c.org_id, p_actor, 'archive.cleanup_completed', 'cleanup_job', v_c.id,
      jsonb_build_object('deleted_items', v_c.deleted_items, 'deleted_bytes', v_c.deleted_bytes), 'security');
  end if;
end;
$$;

-- Claims one bounded batch under an exclusive lease for the CURRENT driver
-- Admin. Items left in flight by an expired lease are handed to the new
-- worker first (deletion is idempotent). p_reconcile_only claims only those.
create or replace function public.internal_cleanup_claim(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_cleanup_job_id uuid, p_worker uuid, p_limit integer,
  p_reconcile_only boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_c hrms.cleanup_jobs;
  v_items jsonb;
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  perform hrms.require_admin(v_actor);
  select * into v_c from hrms.cleanup_jobs where id = p_cleanup_job_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_c.state <> 'running' then
    return jsonb_build_object('done', true, 'job', hrms.cleanup_job_json(v_c));
  end if;
  if v_c.driver_id <> v_actor.employee_id then
    perform hrms.raise_error('ACCESS_DENIED', 'Another Admin is running this cleanup. Resume it to take over.');
  end if;
  if v_c.lease_until > now() and v_c.lease_token is distinct from p_worker then
    return jsonb_build_object('busy', true,
      'retry_after_seconds', ceil(extract(epoch from (v_c.lease_until - now())))::integer);
  end if;

  update hrms.cleanup_jobs set lease_token = p_worker, lease_until = now() + interval '90 seconds'
  where id = v_c.id;
  update hrms.cleanup_items set claimed_by = p_worker, updated_at = now()
  where cleanup_job_id = v_c.id and state = 'deleting' and claimed_by is distinct from p_worker;

  with claim as (
    select id from hrms.cleanup_items
    where cleanup_job_id = v_c.id and state = 'pending' and not coalesce(p_reconcile_only, false)
    order by id limit v_limit
    for update skip locked
  )
  update hrms.cleanup_items ci set state = 'deleting', claimed_by = p_worker, attempts = ci.attempts + 1,
                                   updated_at = now()
  from claim where ci.id = claim.id;

  select coalesce(jsonb_agg(jsonb_build_object('item_id', i.id, 'file_version_id', i.file_version_id,
           'bucket', i.bucket, 'object_key', i.object_key) order by i.id), '[]'::jsonb)
    into v_items
  from hrms.cleanup_items i where i.cleanup_job_id = v_c.id and i.state = 'deleting' and i.claimed_by = p_worker;

  if v_items = '[]'::jsonb then
    update hrms.cleanup_jobs set lease_token = null, lease_until = null where id = v_c.id;
    if not coalesce(p_reconcile_only, false) and not exists (
         select 1 from hrms.cleanup_items where cleanup_job_id = v_c.id and state in ('pending', 'deleting', 'failed')) then
      perform hrms.finish_cleanup(v_c.id, v_actor.employee_id);
    end if;
    select * into v_c from hrms.cleanup_jobs where id = v_c.id;
    return jsonb_build_object('done', v_c.state <> 'running', 'items', '[]'::jsonb,
      'stalled', v_c.state = 'running' and exists (
        select 1 from hrms.cleanup_items where cleanup_job_id = v_c.id and state = 'failed'),
      'job', hrms.cleanup_job_json(v_c));
  end if;
  return jsonb_build_object('done', false, 'items', v_items);
end;
$$;

-- Records batch outcomes. Results are accepted for items this worker claimed
-- even if its lease has since lapsed or its Admin lost the role: a delete
-- that already happened must be recorded truthfully (tombstone + audit).
create or replace function public.internal_cleanup_complete(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_cleanup_job_id uuid, p_worker uuid, p_results jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_c hrms.cleanup_jobs;
  r record;
  v_item hrms.cleanup_items;
  v_export uuid;
begin
  select * into v_c from hrms.cleanup_jobs where id = p_cleanup_job_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  perform set_config('hrms.cleanup_worker', 'on', true);
  for r in select * from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb)) as x(item_id bigint, ok boolean, error text)
  loop
    select * into v_item from hrms.cleanup_items
    where id = r.item_id and cleanup_job_id = v_c.id and state = 'deleting' and claimed_by = p_worker for update;
    continue when not found;
    if coalesce(r.ok, false) then
      update hrms.cleanup_items set state = 'deleted', last_error = null, updated_at = now() where id = v_item.id;
      update hrms.file_versions set state = 'deleted', deleted_at = now(), deleted_by = v_c.driver_id,
             tombstone = jsonb_build_object('sha256', sha256, 'size_bytes', size_bytes, 'archive_path', v_item.path,
                                            'export_job_id', v_c.export_job_id, 'cleanup_job_id', v_c.id,
                                            'deleted_at', now())
      where id = v_item.file_version_id and state = 'deletion_pending';
      update hrms.storage_ledger set used_bytes = greatest(0, used_bytes - v_item.size_bytes), updated_at = now()
      where org_id = v_c.org_id;
      update hrms.cleanup_jobs set deleted_items = deleted_items + 1, deleted_bytes = deleted_bytes + v_item.size_bytes
      where id = v_c.id;
      perform hrms.audit(v_c.org_id, v_c.driver_id, 'file.deleted_by_cleanup', 'file_version', v_item.file_version_id,
        jsonb_build_object('cleanup_job_id', v_c.id, 'path', v_item.path, 'size_bytes', v_item.size_bytes), 'security');
    else
      update hrms.cleanup_items
         set state = case when attempts >= 5 then 'failed' else 'pending' end,
             last_error = left(coalesce(r.error, 'Storage error'), 300), updated_at = now()
       where id = v_item.id;
    end if;
  end loop;
  update hrms.cleanup_jobs set lease_token = null, lease_until = null, version = version + 1
  where id = v_c.id and lease_token = p_worker;
  if not exists (select 1 from hrms.cleanup_items where cleanup_job_id = v_c.id
                 and state in ('pending', 'deleting', 'failed')) then
    perform hrms.finish_cleanup(v_c.id, v_actor.employee_id);
  end if;
  perform set_config('hrms.cleanup_worker', 'off', true);
  select * into v_c from hrms.cleanup_jobs where id = v_c.id;
  return jsonb_build_object('done', v_c.state <> 'running', 'job', hrms.cleanup_job_json(v_c));
end;
$$;

-- Another (or the same) recently reauthenticated Admin takes over the same
-- verified inventory; failed items get new attempts.
create or replace function public.resume_cleanup(p_cleanup_job_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_c hrms.cleanup_jobs;
begin
  perform hrms.require_admin(v_actor);
  select * into v_c from hrms.cleanup_jobs where id = p_cleanup_job_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_c.state <> 'running' then
    perform hrms.raise_error('VALIDATION_FAILED', 'This cleanup is no longer running.');
  end if;
  perform hrms.require_reauth(v_actor, 'archive.cleanup', v_c.id, true);
  update hrms.cleanup_items set state = 'pending', attempts = 0, updated_at = now()
  where cleanup_job_id = v_c.id and state = 'failed';
  update hrms.cleanup_jobs set driver_id = v_actor.employee_id, version = version + 1
  where id = v_c.id
  returning * into v_c;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'archive.cleanup_resumed', 'cleanup_job', v_c.id, null,
                     'security');
  return hrms.ok(hrms.cleanup_job_json(v_c), v_c.version);
end;
$$;

-- Stops a partial cleanup: remaining files are released (restored to their
-- previous state), deleted ones stay tombstoned, the period gate clears. A
-- new cleanup needs a new complete archive (the old one stays consumed).
create or replace function public.abandon_cleanup(p_cleanup_job_id uuid, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_c hrms.cleanup_jobs;
  v_reason text := hrms.clean_text(p_reason, 500);
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_c from hrms.cleanup_jobs where id = p_cleanup_job_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_c.state <> 'running' then
    return hrms.ok(hrms.cleanup_job_json(v_c), v_c.version);
  end if;
  if v_c.lease_until > now() then
    perform hrms.raise_error('PERIOD_BUSY', 'A deletion batch is still running. Try again in a minute.', null, true);
  end if;
  if exists (select 1 from hrms.cleanup_items where cleanup_job_id = v_c.id and state = 'deleting') then
    perform hrms.raise_error('PERIOD_BUSY', 'An interrupted batch must be reconciled first.',
      '{"reconcile":"Required"}'::jsonb, true);
  end if;
  perform set_config('hrms.cleanup_worker', 'on', true);
  update hrms.file_versions v set state = i.prev_state
  from hrms.cleanup_items i
  where i.cleanup_job_id = v_c.id and i.state in ('pending', 'failed') and v.id = i.file_version_id
    and v.state = 'deletion_pending';
  update hrms.cleanup_items set state = 'released', updated_at = now()
  where cleanup_job_id = v_c.id and state in ('pending', 'failed');
  update hrms.cleanup_jobs
     set state = case when deleted_items > 0 then 'abandoned_with_partial_deletions' else 'abandoned' end,
         abandoned_by = v_actor.employee_id, abandoned_at = now(), abandon_reason = v_reason, finished_at = now(),
         lease_token = null, lease_until = null, version = version + 1
   where id = v_c.id
  returning * into v_c;
  update hrms.archive_periods set cleanup_job_id = null where cleanup_job_id = v_c.id;
  perform set_config('hrms.cleanup_worker', 'off', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'archive.cleanup_abandoned', 'cleanup_job', v_c.id,
    jsonb_build_object('deleted_items', v_c.deleted_items, 'reason', v_reason), 'security');
  return hrms.ok(hrms.cleanup_job_json(v_c), v_c.version);
end;
$$;

-- -----------------------------------------------------------------------------
-- Assisted restore (DEL-010): an Admin re-uploads a verified original from a
-- local archive; the server accepts it only if its hash equals the tombstone.
-- -----------------------------------------------------------------------------

create or replace function public.list_archived_files(p_period_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_period hrms.archive_periods;
begin
  perform hrms.require_admin(v_actor);
  select * into v_period from hrms.archive_periods where id = p_period_id and org_id = v_actor.org_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok((select coalesce(jsonb_agg(jsonb_build_object(
      'file_version_id', v.id, 'class', r.class, 'employee_id', r.owner_employee_id,
      'employee', jsonb_build_object('code', e.employee_code, 'name', e.full_name),
      'salary_month', r.period_start, 'document_date', r.document_date, 'title', r.title,
      'mime', coalesce(v.detected_mime, v.declared_mime), 'version_no', v.version_no,
      'sha256', v.sha256, 'size_bytes', v.size_bytes, 'archive_path', v.tombstone ->> 'archive_path',
      'export_job_id', v.tombstone ->> 'export_job_id', 'deleted_at', v.deleted_at,
      'restored_version_id', v.tombstone ->> 'restored_version_id')
      order by e.employee_code, coalesce(r.period_start, r.document_date), v.version_no), '[]'::jsonb)
    from hrms.file_versions v
    join hrms.file_records r on r.id = v.file_record_id
    join hrms.employees e on e.id = r.owner_employee_id
    where v.org_id = v_actor.org_id and v.state = 'deleted'
      and coalesce(r.period_start, r.document_date) between v_period.period_start and v_period.period_end));
end;
$$;

create or replace function public.restore_archived_file(p_deleted_version_id uuid, p_new_version_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_old hrms.file_versions;
  v_new hrms.file_versions;
  v_old_rec hrms.file_records;
  v_new_rec hrms.file_records;
  v_slip hrms.payslips;
  v_reason text := hrms.clean_text(p_reason, 500);
begin
  perform hrms.require_admin(v_actor);
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_old from hrms.file_versions where id = p_deleted_version_id and org_id = v_actor.org_id for update;
  select * into v_new from hrms.file_versions where id = p_new_version_id and org_id = v_actor.org_id for update;
  if v_old.id is null or v_new.id is null then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_old.state <> 'deleted' or v_old.tombstone ? 'restored_version_id' then
    perform hrms.raise_error('VALIDATION_FAILED', 'This file is not an archived original awaiting restore.');
  end if;
  if v_new.state <> 'validated' or v_new.uploaded_by <> v_actor.employee_id then
    perform hrms.raise_error('VALIDATION_FAILED', 'Upload the original file first.');
  end if;
  if v_new.sha256 is distinct from v_old.sha256 or v_new.size_bytes is distinct from v_old.size_bytes then
    perform hrms.raise_error('VALIDATION_FAILED', 'This file does not match the archived original.',
      '{"file":"Hash mismatch"}'::jsonb);
  end if;
  select * into v_old_rec from hrms.file_records where id = v_old.file_record_id;
  select * into v_new_rec from hrms.file_records where id = v_new.file_record_id for update;
  if v_new_rec.class <> v_old_rec.class or v_new_rec.owner_employee_id is distinct from v_old_rec.owner_employee_id then
    perform hrms.raise_error('VALIDATION_FAILED', 'Restore only to the original employee and document kind.');
  end if;

  if v_old_rec.class = 'payslip' then
    if v_new_rec.id <> v_old_rec.id then
      perform hrms.raise_error('VALIDATION_FAILED', 'Restore a payslip to its original salary month.');
    end if;
    select * into v_slip from hrms.payslips where file_record_id = v_old_rec.id for update;
    if v_slip.current_file_version_id = v_old.id then
      update hrms.file_versions set state = 'published', published_at = now(), published_by = v_actor.employee_id,
             supersedes_version_id = v_old.id, replace_reason = 'Restored from archive: ' || v_reason
      where id = v_new.id;
      update hrms.file_records set current_version_id = v_new.id where id = v_old_rec.id;
      update hrms.payslips set current_file_version_id = v_new.id, version = version + 1 where id = v_slip.id;
    else
      update hrms.file_versions set state = 'superseded', replace_reason = 'Restored revision: ' || v_reason
      where id = v_new.id;
    end if;
  else
    if v_new_rec.document_date is distinct from v_old_rec.document_date then
      perform hrms.raise_error('VALIDATION_FAILED', 'Use the original document date.', '{"document_date":"Mismatch"}'::jsonb);
    end if;
    update hrms.file_versions set state = 'published', published_at = now(), published_by = v_actor.employee_id,
           replace_reason = 'Restored from archive: ' || v_reason
    where id = v_new.id;
    update hrms.file_records set current_version_id = v_new.id,
           title = coalesce(v_old_rec.title, v_new_rec.title) || ' (restored)'
    where id = v_new_rec.id;
  end if;
  perform set_config('hrms.cleanup_worker', 'on', true);
  update hrms.file_versions set tombstone = tombstone || jsonb_build_object('restored_version_id', v_new.id,
         'restored_at', now(), 'restored_by', v_actor.employee_id)
  where id = v_old.id;
  perform set_config('hrms.cleanup_worker', 'off', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.restored_from_archive', 'file_version', v_new.id,
    jsonb_build_object('original_version_id', v_old.id, 'reason', v_reason), 'security', v_old_rec.owner_employee_id);
  return hrms.ok(jsonb_build_object('restored_version_id', v_new.id, 'original_version_id', v_old.id));
end;
$$;

-- Publishing over a month whose current version was cleaned up must not try
-- to change the terminal deleted version (the old one stays tombstoned).
create or replace function public.publish_payslip(p_file_version_id uuid, p_reason text, p_expected_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_ver hrms.file_versions;
  v_rec hrms.file_records;
  v_slip hrms.payslips;
  v_reason text := hrms.clean_text(p_reason, 500);
  v_replacing boolean;
begin
  if not hrms.can_manage_payroll(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  select * into v_ver from hrms.file_versions where id = p_file_version_id for update;
  if not found or v_ver.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_rec from hrms.file_records where id = v_ver.file_record_id;
  if v_rec.class <> 'payslip' then perform hrms.raise_error('INVALID_FILE_TYPE', 'Not a payslip upload.'); end if;
  if v_ver.state <> 'validated' then
    perform hrms.raise_error('VALIDATION_FAILED', 'Only a validated upload can be published.');
  end if;
  select * into v_slip from hrms.payslips where file_record_id = v_rec.id for update;
  if v_slip.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This payslip changed. Reload and try again.', null, true);
  end if;
  v_replacing := v_slip.current_file_version_id is not null;
  if v_replacing and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Give a reason for replacing the published payslip.',
      '{"reason":"Required for a replacement"}'::jsonb);
  end if;
  if v_replacing then
    update hrms.file_versions set state = 'superseded'
    where id = v_slip.current_file_version_id and state = 'published';
  end if;
  update hrms.file_versions
     set state = 'published', published_at = now(), published_by = v_actor.employee_id,
         supersedes_version_id = v_slip.current_file_version_id, replace_reason = v_reason
   where id = v_ver.id;
  update hrms.file_records set current_version_id = v_ver.id where id = v_rec.id;
  update hrms.payslips
     set current_file_version_id = v_ver.id, published_at = now(), published_by = v_actor.employee_id,
         version = version + 1
   where id = v_slip.id
  returning * into v_slip;

  perform hrms.notify(v_actor.org_id, v_slip.employee_id, 'payslip.published', 'Payslip available',
    'A payslip has been published. Open the app to view it.', '/payslips',
    jsonb_build_object('salary_month', v_slip.salary_month), md5(v_ver.id::text || ':published')::uuid);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when v_replacing then 'payslip.replaced' else 'payslip.published' end,
    'payslip', v_slip.id, jsonb_build_object('file_version_id', v_ver.id, 'salary_month', v_slip.salary_month,
                                             'reason', v_reason), 'business', v_slip.employee_id);
  return hrms.ok(jsonb_build_object('payslip_id', v_slip.id, 'salary_month', v_slip.salary_month,
                                    'file_version_id', v_ver.id), v_slip.version);
end;
$$;

-- Replaces the files-migration version: a person who could open a file
-- before it was cleaned up now gets the "archived locally — contact HR"
-- answer (no link) instead of a generic denial (FILE-010). Everyone else is
-- still denied, and no signed link is ever issued for removed bytes.
create or replace function public.internal_authorize_file_access(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_file_version_id uuid, p_purpose text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_ver hrms.file_versions;
  v_rec hrms.file_records;
  v_slip hrms.payslips;
  v_ok boolean := false;
  v_grant uuid;
  v_req hrms.requests;
  v_gone boolean;
begin
  if p_purpose not in ('view', 'download', 'review') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown purpose');
  end if;
  select * into v_ver from hrms.file_versions where id = p_file_version_id;
  if not found or v_ver.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_rec from hrms.file_records where id = v_ver.file_record_id;
  v_gone := v_ver.state in ('deleted', 'deletion_pending', 'archived');

  if v_rec.class = 'payslip' then
    if hrms.can_manage_payroll(v_actor) then
      v_ok := v_ver.state in ('validated', 'published', 'superseded') or v_gone;
    elsif v_rec.owner_employee_id = v_actor.employee_id then
      select * into v_slip from hrms.payslips where file_record_id = v_rec.id;
      -- Member window: by salary month (business period), never upload date.
      v_ok := (v_ver.state = 'published' or v_gone) and v_slip.current_file_version_id = v_ver.id
              and v_slip.salary_month >= hrms.payslip_window_start(v_actor.org_id)
              and v_slip.salary_month <= date_trunc('month', hrms.org_today(v_actor.org_id))::date;
    end if;
  elsif v_rec.class = 'avatar' then
    v_ok := v_ver.state = 'published';
  elsif v_rec.class = 'company_policy' then
    v_ok := v_ver.state = 'published' or hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'policy.draft');
  elsif v_rec.class = 'employee_document' then
    v_ok := (v_ver.state in ('validated', 'published') or v_gone) and (
              v_rec.owner_employee_id = v_actor.employee_id
              or hrms.has_perm(v_actor, 'hr.employees.view'));
  else
    -- Request attachments: owner, or the reviewer through the CURRENT review
    -- lock of the revision that references this file. Medical attachments
    -- additionally need the documents.medical grant (or Admin).
    if v_rec.owner_employee_id = v_actor.employee_id then
      v_ok := v_ver.state in ('validated', 'published');
    else
      select r.* into v_req from hrms.requests r
      join hrms.request_revisions rv on rv.request_id = r.id and rv.revision_no = r.current_revision
      where r.employee_id = v_rec.owner_employee_id
        and rv.payload ->> 'attachment_file_version_id' = v_ver.id::text
        and r.state in ('under_review', 'approved', 'rejected', 'withdrawal_pending', 'cancellation_pending')
        and r.locked_revision = r.current_revision
      limit 1;
      v_ok := v_req.id is not null and hrms.review_authority(v_actor, v_req) is not null
              and (v_rec.class <> 'medical_attachment' or hrms.is_admin(v_actor)
                   or hrms.has_perm(v_actor, 'documents.medical'));
    end if;
  end if;

  if not v_ok then
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.access_denied', 'file_version', v_ver.id,
      jsonb_build_object('class', v_rec.class, 'purpose', p_purpose), 'access', v_rec.owner_employee_id);
    perform hrms.raise_error('ACCESS_DENIED');
  end if;

  if v_gone or v_ver.object_key is null then
    return jsonb_build_object('available', false, 'reason', 'archived',
      'message', 'This file was archived locally. Contact HR for a copy.');
  end if;

  insert into hrms.file_access_grants (org_id, actor_id, file_version_id, purpose, link_ttl_seconds)
  values (v_actor.org_id, v_actor.employee_id, v_ver.id, p_purpose, 60)
  returning id into v_grant;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.access_granted', 'file_version', v_ver.id,
    jsonb_build_object('class', v_rec.class, 'purpose', p_purpose, 'grant_id', v_grant), 'access',
    v_rec.owner_employee_id);
  return jsonb_build_object('available', true, 'grant_id', v_grant, 'bucket', 'hrms-files',
    'object_key', v_ver.object_key, 'ttl_seconds', 60, 'mime', coalesce(v_ver.detected_mime, v_ver.declared_mime),
    'filename', v_ver.original_filename, 'size_bytes', v_ver.size_bytes);
end;
$$;

-- Member payslip slots: current salary month + previous 11 (period-based).
-- Replaces the earlier version, which returned salary months as timestamps.
create or replace function public.list_my_payslips() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_start date := hrms.payslip_window_start(v_actor.org_id);
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'salary_month', m.month,
           'status', case
             when p.current_file_version_id is null then 'missing'
             when v.state = 'published' then 'available'
             when v.state in ('deleted', 'deletion_pending', 'archived') then 'archived'
             else 'missing' end,
           'file_version_id', case when v.state = 'published' then v.id end,
           'published_at', p.published_at,
           'revision_no', v.version_no,
           'replaced', v.supersedes_version_id is not null) order by m.month desc), '[]'::jsonb)
    into v_rows
  from (select g::date as month
        from generate_series(v_start, date_trunc('month', hrms.org_today(v_actor.org_id))::date, interval '1 month') g) m
  left join hrms.payslips p on p.employee_id = v_actor.employee_id and p.salary_month = m.month
  left join hrms.file_versions v on v.id = p.current_file_version_id;
  return hrms.ok(jsonb_build_object('window_start', v_start, 'slots', v_rows));
end;
$$;

-- -----------------------------------------------------------------------------
-- HR view of an employee's documents (S26) and payslips (payroll grant only)
-- -----------------------------------------------------------------------------

create or replace function public.list_employee_files(p_employee_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_payroll boolean := hrms.can_manage_payroll(v_actor);
begin
  if not (hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'hr.employees.view')) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if not exists (select 1 from hrms.employees where id = p_employee_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'employee.files_viewed', 'employee', p_employee_id, null,
                     'access', p_employee_id);
  return hrms.ok(jsonb_build_object(
    'documents', (select coalesce(jsonb_agg(jsonb_build_object(
        'record_id', r.id, 'title', r.title, 'document_date', r.document_date, 'file_version_id', v.id,
        'version_no', v.version_no, 'state', v.state, 'mime', coalesce(v.detected_mime, v.declared_mime),
        'size_bytes', v.size_bytes, 'created_at', v.created_at) order by v.created_at desc), '[]'::jsonb)
      from hrms.file_records r
      join lateral (select * from hrms.file_versions fv where fv.file_record_id = r.id
                      and fv.state in ('validated', 'published', 'superseded', 'deletion_pending', 'deleted')
                    order by fv.version_no desc limit 1) v on true
      where r.owner_employee_id = p_employee_id and r.class = 'employee_document'),
    'payslips', case when v_payroll then (select coalesce(jsonb_agg(jsonb_build_object(
        'salary_month', p.salary_month, 'file_version_id', p.current_file_version_id, 'state', v.state,
        'published_at', p.published_at, 'version', p.version) order by p.salary_month desc), '[]'::jsonb)
      from hrms.payslips p left join hrms.file_versions v on v.id = p.current_file_version_id
      where p.employee_id = p_employee_id) end,
    'can_upload', hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'hr.master_data'),
    'can_manage_payroll', v_payroll));
end;
$$;

-- -----------------------------------------------------------------------------
-- Admin tasks, Home extras and the daily obligation check
-- -----------------------------------------------------------------------------

create or replace function hrms.admin_tasks(p_org uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(t), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'maintenance_stale',
                              'title', 'Background maintenance has not run recently') as t
    where coalesce((select started_at < now() - interval '1 hour' from hrms.maintenance_runs
                    where kind = 'tick' order by started_at desc limit 1), true)
    union all
    select jsonb_build_object('kind', 'reviewer_missing', 'title', 'Requests waiting for an approver',
                              'count', count(*))
    from hrms.requests r where r.org_id = p_org and r.assigned_reviewer_id is null
      and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'storage', 'title', 'Storage use is high',
                              'percent', round(100.0 * l.used_bytes / o.storage_budget_bytes))
    from hrms.storage_ledger l join hrms.organizations o on o.id = l.org_id
    where l.org_id = p_org and l.used_bytes * 100 >= o.storage_budget_bytes * o.storage_alert_percents[1]
    union all
    select jsonb_build_object('kind', 'archive_due', 'period_id', p.id,
                              'title', 'Annual archive due: ' || hrms.period_label(p.period_start, p.period_end),
                              'since', p.period_end + 1)
    from hrms.archive_periods p
    where p.org_id = p_org and p.period_end < hrms.org_today(p_org)
      and not exists (select 1 from hrms.export_jobs j where j.period_id = p.id and j.state in ('acknowledged', 'partial')
                        and j.stale_at is null)
      and exists (select 1 from hrms.employees e where e.org_id = p_org and e.status <> 'pending'
                    and e.join_date <= p.period_end and (e.end_date is null or e.end_date >= p.period_start))
    union all
    select jsonb_build_object('kind', 'cleanup_running', 'cleanup_job_id', c.id,
                              'title', 'File cleanup in progress: ' || hrms.period_label(p.period_start, p.period_end))
    from hrms.cleanup_jobs c join hrms.archive_periods p on p.id = c.period_id
    where c.org_id = p_org and c.state = 'running'
  ) s;
$$;

create or replace function hrms.home_extras(p_actor hrms.actor, p_today date) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'latest_payslip', (select jsonb_build_object('salary_month', p.salary_month, 'published_at', p.published_at)
                       from hrms.payslips p join hrms.file_versions v on v.id = p.current_file_version_id
                       where p.employee_id = p_actor.employee_id and v.state = 'published'
                         and p.salary_month >= hrms.payslip_window_start(p_actor.org_id)
                       order by p.salary_month desc limit 1),
    'admin_tasks', case when hrms.is_admin(p_actor) then hrms.admin_tasks(p_actor.org_id) end);
$$;

-- Daily: keep annual periods materialised so due archives surface as tasks
-- even before an Admin opens the archive screen.
create or replace function hrms.daily_extras() returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org record;
begin
  for v_org in select id from hrms.organizations loop
    perform hrms.ensure_archive_periods(v_org.id);
  end loop;
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
