-- =============================================================================
-- Private files, payslips and storage accounting (architecture.md §7.1).
--
-- Lifecycle: requested -> quarantined -> validated -> published ->
--            superseded/archived -> deletion_pending -> deleted (| rejected)
-- The client uploads ONLY to a staging object through a short-lived signed
-- upload URL. finish_upload copies it (server credentials) to a NEW
-- immutable final object, validates and hashes THOSE bytes, and only then
-- marks the version validated. Clients have no Storage policies at all: no
-- select/list/sign on either bucket. Downloads go through
-- internal_authorize_file_access (audited) and a <=60 s signed URL.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hrms-staging', 'hrms-staging', false, 5000000,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']),
       ('hrms-files', 'hrms-files', false, 5000000,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table hrms.file_records (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  owner_employee_id uuid,
  class text not null check (class in ('payslip', 'avatar', 'employee_document', 'company_policy',
                                       'leave_attachment', 'medical_attachment', 'correction_attachment')),
  period_start date,
  period_end date,
  document_date date,
  title text check (char_length(title) <= 200),
  current_version_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version integer not null default 1,
  unique (org_id, id),
  foreign key (org_id, owner_employee_id) references hrms.employees(org_id, id) on delete restrict,
  check (period_end is null or period_start is null or period_end >= period_start)
);
create index file_records_owner_idx on hrms.file_records (owner_employee_id, class, period_start);
create trigger file_records_touch before update on hrms.file_records
  for each row execute function hrms.touch_updated_at();

create table hrms.file_versions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  file_record_id uuid not null references hrms.file_records(id) on delete restrict,
  version_no integer not null,
  state text not null check (state in ('requested', 'quarantined', 'validated', 'published', 'superseded',
                                       'archived', 'deletion_pending', 'deleted', 'rejected')),
  staging_object_key text,
  object_key text unique,
  original_filename text check (char_length(original_filename) <= 200),
  declared_mime text,
  detected_mime text,
  declared_size_bytes bigint check (declared_size_bytes between 1 and 5000000),
  size_bytes bigint check (size_bytes between 1 and 5000000),
  sha256 text check (sha256 ~ '^[0-9a-f]{64}$'),
  validation_error text check (char_length(validation_error) <= 300),
  supersedes_version_id uuid references hrms.file_versions(id) on delete restrict,
  replace_reason text check (char_length(replace_reason) <= 500),
  uploaded_by uuid,
  upload_expires_at timestamptz,
  reserved_bytes bigint not null default 0 check (reserved_bytes >= 0),
  created_at timestamptz not null default now(),
  validated_at timestamptz,
  published_at timestamptz,
  published_by uuid,
  deleted_at timestamptz,
  deleted_by uuid,
  tombstone jsonb,
  pinned_until timestamptz,
  unique (file_record_id, version_no),
  unique (org_id, id)
);
create index file_versions_record_idx on hrms.file_versions (file_record_id, version_no desc);
create index file_versions_state_idx on hrms.file_versions (org_id, state, id);
create index file_versions_expiry_idx on hrms.file_versions (upload_expires_at) where state = 'requested';
create trigger file_versions_no_delete before delete on hrms.file_versions
  for each row execute function hrms.forbid_mutation();

-- Immutable facts of a validated version cannot change afterwards.
create or replace function hrms.file_versions_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state not in ('requested', 'quarantined') and (
       new.object_key is distinct from old.object_key or new.sha256 is distinct from old.sha256
       or new.size_bytes is distinct from old.size_bytes or new.file_record_id is distinct from old.file_record_id) then
    raise exception 'HRMS: validated file bytes are immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger file_versions_guard before update on hrms.file_versions
  for each row execute function hrms.file_versions_guard();

alter table hrms.file_records add constraint file_records_current_fk
  foreign key (current_version_id) references hrms.file_versions(id) on delete restrict;
alter table hrms.employees add constraint employees_avatar_fk
  foreign key (avatar_file_version_id) references hrms.file_versions(id) on delete restrict;

create table hrms.payslips (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  salary_month date not null check (extract(day from salary_month) = 1),
  file_record_id uuid not null references hrms.file_records(id) on delete restrict,
  current_file_version_id uuid references hrms.file_versions(id) on delete restrict,
  published_at timestamptz,
  published_by uuid,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, salary_month),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create trigger payslips_touch before update on hrms.payslips
  for each row execute function hrms.touch_updated_at();

-- Approximate storage accounting with reservations (never auto-deletes).
create table hrms.storage_ledger (
  org_id uuid primary key references hrms.organizations(id) on delete restrict,
  used_bytes bigint not null default 0 check (used_bytes >= 0),
  reserved_bytes bigint not null default 0 check (reserved_bytes >= 0),
  updated_at timestamptz not null default now()
);

create table hrms.file_access_grants (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  actor_id uuid not null,
  file_version_id uuid not null references hrms.file_versions(id) on delete restrict,
  purpose text not null check (purpose in ('view', 'download', 'review', 'export')),
  issued_at timestamptz not null default now(),
  link_ttl_seconds integer not null check (link_ttl_seconds between 1 and 60),
  opened_reported_at timestamptz
);
create index file_access_grants_actor_idx on hrms.file_access_grants (actor_id, issued_at desc);

-- Link attachments on requests to real file versions.
-- (leave/correction revisions reference them inside their payload JSON)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

create or replace function hrms.allowed_mimes(p_class text) returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_class
    when 'payslip' then array['application/pdf']
    when 'avatar' then array['image/jpeg', 'image/png', 'image/webp']
    else array['application/pdf', 'image/jpeg', 'image/png'] end;
$$;

-- Sanitised display filename (no paths, control chars or reserved names).
create or replace function hrms.safe_filename(p_name text) returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(left(regexp_replace(
           regexp_replace(coalesce(p_name, ''), '^.*[\\/]', ''),      -- strip any path
           '[^A-Za-z0-9 ._()-]', '_', 'g'), 120), ''), 'file');
$$;

-- Salary-month window for members: current month and the previous 11.
create or replace function hrms.payslip_window_start(p_org uuid) returns date
language sql
stable
set search_path = ''
as $$
  select (date_trunc('month', hrms.org_today(p_org)) - interval '11 months')::date;
$$;

create or replace function hrms.can_manage_payroll(p_actor hrms.actor) returns boolean
language sql
immutable
set search_path = ''
as $$ select hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'payroll.manage'); $$;

-- Who may upload a file of a class for an owner.
create or replace function hrms.can_upload(p_actor hrms.actor, p_class text, p_owner uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_class
    when 'payslip' then hrms.can_manage_payroll(p_actor)
    when 'avatar' then p_owner = p_actor.employee_id or hrms.has_perm(p_actor, 'hr.master_data')
    when 'employee_document' then hrms.has_perm(p_actor, 'hr.master_data')
    when 'company_policy' then hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'policy.draft')
    else p_owner = p_actor.employee_id end;
$$;

-- -----------------------------------------------------------------------------
-- Upload lifecycle (called by the `files` Edge Function)
-- -----------------------------------------------------------------------------

create or replace function public.internal_begin_upload(
  p_auth_user_id uuid, p_session_id uuid, p_email text,
  p_class text, p_owner_employee_id uuid, p_salary_month date, p_document_date date, p_title text,
  p_filename text, p_declared_size bigint, p_declared_mime text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_owner uuid := coalesce(p_owner_employee_id, case when p_class = 'company_policy' then null else v_actor.employee_id end);
  v_org hrms.organizations;
  v_ledger hrms.storage_ledger;
  v_rec hrms.file_records;
  v_ver hrms.file_versions;
  v_month date;
  v_reserve bigint;
  v_emp hrms.employees;
begin
  if p_class is null or p_class not in ('payslip', 'avatar', 'employee_document', 'company_policy',
                                        'leave_attachment', 'medical_attachment', 'correction_attachment') then
    perform hrms.raise_error('INVALID_FILE_TYPE', 'Unsupported document kind.');
  end if;
  if v_owner is not null then
    select * into v_emp from hrms.employees where id = v_owner and org_id = v_actor.org_id;
    if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  end if;
  if not hrms.can_upload(v_actor, p_class, v_owner) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_declared_size is null or p_declared_size < 1 then
    perform hrms.raise_error('INVALID_FILE_TYPE', 'The file is empty.', '{"file":"Empty files are not allowed"}'::jsonb);
  end if;
  if p_declared_size > 5000000 then
    perform hrms.raise_error('FILE_TOO_LARGE', 'Files must be at most 5 MB (5,000,000 bytes).',
      '{"file":"Larger than 5,000,000 bytes"}'::jsonb);
  end if;
  if p_declared_mime is null or not (p_declared_mime = any(hrms.allowed_mimes(p_class))) then
    perform hrms.raise_error('INVALID_FILE_TYPE', 'This file type is not allowed here.',
      jsonb_build_object('file', 'Allowed: ' || array_to_string(hrms.allowed_mimes(p_class), ', ')));
  end if;
  if hrms.rate_limit_hit('upload:' || v_actor.employee_id::text, interval '1 hour') > 60 then
    perform hrms.raise_error('RATE_LIMITED', 'Too many uploads. Try again later.', null, true);
  end if;

  if p_class = 'payslip' then
    if p_salary_month is null then
      perform hrms.raise_error('VALIDATION_FAILED', 'Choose the salary month.', '{"salary_month":"Required"}'::jsonb);
    end if;
    v_month := date_trunc('month', p_salary_month)::date;
    if v_month > date_trunc('month', hrms.org_today(v_actor.org_id))::date then
      perform hrms.raise_error('VALIDATION_FAILED', 'Salary month cannot be in the future.',
        '{"salary_month":"Future month"}'::jsonb);
    end if;
    if v_month < date_trunc('month', v_emp.join_date)::date
       or (v_emp.end_date is not null and v_month > date_trunc('month', v_emp.end_date)::date) then
      perform hrms.raise_error('VALIDATION_FAILED', 'Month is outside this employee''s employment.',
        '{"salary_month":"Outside employment dates"}'::jsonb);
    end if;
  end if;

  -- Storage budget: reserve staging + final-copy overhead.
  v_reserve := p_declared_size * 2;
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  insert into hrms.storage_ledger (org_id) values (v_actor.org_id) on conflict (org_id) do nothing;
  select * into v_ledger from hrms.storage_ledger where org_id = v_actor.org_id for update;
  if v_ledger.used_bytes + v_ledger.reserved_bytes + v_reserve > v_org.storage_budget_bytes then
    perform hrms.raise_error('STORAGE_BUDGET_EXCEEDED',
      'Storage budget reached. Ask an Admin to review storage before uploading more.');
  end if;
  update hrms.storage_ledger set reserved_bytes = reserved_bytes + v_reserve, updated_at = now()
  where org_id = v_actor.org_id;

  -- Payslips reuse one record per employee+month (new versions supersede).
  if p_class = 'payslip' then
    select fr.* into v_rec from hrms.payslips p join hrms.file_records fr on fr.id = p.file_record_id
    where p.employee_id = v_owner and p.salary_month = v_month;
    if not found then
      insert into hrms.file_records (org_id, owner_employee_id, class, period_start, period_end, title, created_by)
      values (v_actor.org_id, v_owner, 'payslip', v_month, (v_month + interval '1 month - 1 day')::date,
              to_char(v_month, 'Mon YYYY') || ' payslip', v_actor.employee_id)
      returning * into v_rec;
      insert into hrms.payslips (org_id, employee_id, salary_month, file_record_id)
      values (v_actor.org_id, v_owner, v_month, v_rec.id);
    end if;
  else
    insert into hrms.file_records (org_id, owner_employee_id, class, document_date, title, created_by)
    values (v_actor.org_id, v_owner, p_class, p_document_date, hrms.clean_text(p_title, 200), v_actor.employee_id)
    returning * into v_rec;
  end if;

  insert into hrms.file_versions (org_id, file_record_id, version_no, state, original_filename, declared_mime,
                                  declared_size_bytes, uploaded_by, upload_expires_at, reserved_bytes)
  values (v_actor.org_id, v_rec.id,
          coalesce((select max(version_no) from hrms.file_versions where file_record_id = v_rec.id), 0) + 1,
          'requested', hrms.safe_filename(p_filename), p_declared_mime, p_declared_size, v_actor.employee_id,
          now() + interval '15 minutes', v_reserve)
  returning * into v_ver;
  update hrms.file_versions
     set staging_object_key = v_actor.org_id::text || '/' || v_ver.id::text || '/' || gen_random_uuid()::text
   where id = v_ver.id
  returning * into v_ver;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.upload_started', 'file_version', v_ver.id,
    jsonb_build_object('class', p_class, 'declared_size', p_declared_size, 'salary_month', v_month),
    'business', v_owner);
  return jsonb_build_object('file_version_id', v_ver.id, 'file_record_id', v_rec.id,
                            'staging_bucket', 'hrms-staging', 'staging_key', v_ver.staging_object_key,
                            'expires_at', v_ver.upload_expires_at, 'version_no', v_ver.version_no);
end;
$$;

-- Step 1 of finish: reauthorise and pin the server-chosen final key. Retries
-- reuse the same final key; a replayed staging token cannot change it.
create or replace function public.internal_finish_upload_prepare(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_file_version_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_ver hrms.file_versions;
  v_rec hrms.file_records;
begin
  select * into v_ver from hrms.file_versions where id = p_file_version_id for update;
  if not found or v_ver.org_id <> v_actor.org_id or v_ver.uploaded_by <> v_actor.employee_id then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  select * into v_rec from hrms.file_records where id = v_ver.file_record_id;
  if not hrms.can_upload(v_actor, v_rec.class, v_rec.owner_employee_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_ver.state in ('validated', 'published') then
    return jsonb_build_object('already_complete', true, 'state', v_ver.state, 'sha256', v_ver.sha256,
                              'size_bytes', v_ver.size_bytes);
  end if;
  if v_ver.state not in ('requested', 'quarantined') then
    perform hrms.raise_error('VALIDATION_FAILED', 'This upload can no longer be completed.');
  end if;
  if v_ver.state = 'requested' and v_ver.upload_expires_at < now() then
    perform hrms.raise_error('VALIDATION_FAILED', 'Upload expired. Start again.', null, true);
  end if;
  if v_ver.object_key is null then
    update hrms.file_versions
       set state = 'quarantined',
           object_key = v_ver.org_id::text || '/' || gen_random_uuid()::text
     where id = v_ver.id
    returning * into v_ver;
  end if;
  return jsonb_build_object('already_complete', false, 'staging_bucket', 'hrms-staging',
    'staging_key', v_ver.staging_object_key, 'final_bucket', 'hrms-files', 'final_key', v_ver.object_key,
    'class', v_rec.class, 'declared_mime', v_ver.declared_mime, 'declared_size', v_ver.declared_size_bytes);
end;
$$;

-- Step 2 of finish: record validation of the FINAL bytes and settle the
-- storage reservation exactly once.
create or replace function public.internal_finish_upload_complete(
  p_auth_user_id uuid, p_session_id uuid, p_email text, p_file_version_id uuid,
  p_valid boolean, p_detected_mime text, p_size_bytes bigint, p_sha256 text, p_error text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.resolve_actor(p_auth_user_id, p_session_id, p_email, 'business');
  v_ver hrms.file_versions;
begin
  select * into v_ver from hrms.file_versions where id = p_file_version_id for update;
  if not found or v_ver.org_id <> v_actor.org_id or v_ver.uploaded_by <> v_actor.employee_id then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_ver.state in ('validated', 'published') then
    return jsonb_build_object('state', v_ver.state, 'sha256', v_ver.sha256, 'size_bytes', v_ver.size_bytes);
  end if;
  if v_ver.state <> 'quarantined' then
    perform hrms.raise_error('VALIDATION_FAILED', 'This upload can no longer be completed.');
  end if;

  update hrms.storage_ledger
     set reserved_bytes = greatest(0, reserved_bytes - v_ver.reserved_bytes),
         used_bytes = used_bytes + case when p_valid then coalesce(p_size_bytes, 0) else 0 end,
         updated_at = now()
   where org_id = v_ver.org_id;

  if p_valid then
    update hrms.file_versions
       set state = 'validated', detected_mime = p_detected_mime, size_bytes = p_size_bytes,
           sha256 = lower(p_sha256), validated_at = now(), reserved_bytes = 0
     where id = v_ver.id
    returning * into v_ver;
  else
    update hrms.file_versions
       set state = 'rejected', validation_error = left(coalesce(p_error, 'Validation failed'), 300),
           reserved_bytes = 0
     where id = v_ver.id
    returning * into v_ver;
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_valid then 'file.validated' else 'file.rejected' end, 'file_version', v_ver.id,
    jsonb_build_object('size_bytes', p_size_bytes, 'detected_mime', p_detected_mime, 'error', p_error), 'business');
  return jsonb_build_object('state', v_ver.state, 'sha256', v_ver.sha256, 'size_bytes', v_ver.size_bytes,
                            'error', v_ver.validation_error);
end;
$$;

-- Publish a validated payslip for its employee+month. Replacement requires a
-- reason and keeps the old version (superseded) for audit/export. The member
-- is notified only after publication succeeds.
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
  if v_slip.current_file_version_id is not null and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Give a reason for replacing the published payslip.',
      '{"reason":"Required for a replacement"}'::jsonb);
  end if;
  if v_slip.current_file_version_id is not null then
    update hrms.file_versions set state = 'superseded' where id = v_slip.current_file_version_id;
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
    case when v_ver.supersedes_version_id is null then 'payslip.published' else 'payslip.replaced' end,
    'payslip', v_slip.id, jsonb_build_object('file_version_id', v_ver.id, 'salary_month', v_slip.salary_month,
                                             'reason', v_reason), 'business', v_slip.employee_id);
  return hrms.ok(jsonb_build_object('payslip_id', v_slip.id, 'salary_month', v_slip.salary_month,
                                    'file_version_id', v_ver.id), v_slip.version);
end;
$$;

-- Decides whether the actor may read a file version and returns where the
-- Edge Function should sign a <=60 s URL. Records an audited access grant.
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
begin
  if p_purpose not in ('view', 'download', 'review') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown purpose');
  end if;
  select * into v_ver from hrms.file_versions where id = p_file_version_id;
  if not found or v_ver.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_rec from hrms.file_records where id = v_ver.file_record_id;

  if v_rec.class = 'payslip' then
    if hrms.can_manage_payroll(v_actor) then
      v_ok := v_ver.state in ('validated', 'published', 'superseded');
    elsif v_rec.owner_employee_id = v_actor.employee_id then
      select * into v_slip from hrms.payslips where file_record_id = v_rec.id;
      -- Member window: by salary month (business period), never upload date.
      v_ok := v_ver.state = 'published' and v_slip.current_file_version_id = v_ver.id
              and v_slip.salary_month >= hrms.payslip_window_start(v_actor.org_id)
              and v_slip.salary_month <= date_trunc('month', hrms.org_today(v_actor.org_id))::date;
    end if;
  elsif v_rec.class = 'avatar' then
    v_ok := v_ver.state = 'published';
  elsif v_rec.class = 'company_policy' then
    v_ok := v_ver.state = 'published' or hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'policy.draft');
  elsif v_rec.class = 'employee_document' then
    v_ok := v_ver.state in ('validated', 'published') and (
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

  if v_ver.state in ('deleted', 'deletion_pending', 'archived') or v_ver.object_key is null then
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

-- App-reported open/download, recorded separately from link issuance.
create or replace function public.report_file_opened(p_grant_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_grant hrms.file_access_grants;
begin
  update hrms.file_access_grants set opened_reported_at = coalesce(opened_reported_at, now())
  where id = p_grant_id and actor_id = v_actor.employee_id
  returning * into v_grant;
  if found then
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'file.opened_reported', 'file_version',
      v_grant.file_version_id, jsonb_build_object('grant_id', p_grant_id), 'access');
  end if;
  return hrms.ok(jsonb_build_object('recorded', found));
end;
$$;

-- Member payslip slots: current salary month + previous 11 (period-based).
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
  from generate_series(v_start, date_trunc('month', hrms.org_today(v_actor.org_id))::date, interval '1 month') m(month)
  left join hrms.payslips p on p.employee_id = v_actor.employee_id and p.salary_month = m.month::date
  left join hrms.file_versions v on v.id = p.current_file_version_id;
  return hrms.ok(jsonb_build_object('window_start', v_start, 'slots', v_rows));
end;
$$;

-- Payroll uploads listing for HR/Admin with payroll permission.
create or replace function public.list_payslip_uploads(
  p_employee_id uuid default null, p_salary_month date default null, p_limit integer default 25,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 10000);
  v_rows jsonb;
  v_total integer;
begin
  if not hrms.can_manage_payroll(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select count(*) into v_total
  from hrms.payslips p
  where p.org_id = v_actor.org_id and (p_employee_id is null or p.employee_id = p_employee_id)
    and (p_salary_month is null or p.salary_month = date_trunc('month', p_salary_month)::date);
  select coalesce(jsonb_agg(x.j order by x.salary_month desc, x.code), '[]'::jsonb) into v_rows
  from (
    select p.salary_month, e.employee_code as code, jsonb_build_object(
      'payslip_id', p.id, 'salary_month', p.salary_month, 'version', p.version,
      'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name),
      'published_at', p.published_at, 'current_file_version_id', p.current_file_version_id,
      'versions', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', v.id, 'version_no', v.version_no, 'state', v.state, 'size_bytes', v.size_bytes,
                     'filename', v.original_filename, 'created_at', v.created_at, 'published_at', v.published_at,
                     'validation_error', v.validation_error, 'replace_reason', v.replace_reason)
                     order by v.version_no desc), '[]'::jsonb)
                   from hrms.file_versions v where v.file_record_id = p.file_record_id)) as j
    from hrms.payslips p
    join hrms.employees e on e.id = p.employee_id
    where p.org_id = v_actor.org_id and (p_employee_id is null or p.employee_id = p_employee_id)
      and (p_salary_month is null or p.salary_month = date_trunc('month', p_salary_month)::date)
    order by p.salary_month desc, e.employee_code
    limit v_limit offset v_offset
  ) x;
  return hrms.ok(jsonb_build_object('rows', v_rows, 'total', v_total, 'limit', v_limit, 'offset', v_offset));
end;
$$;

-- Documents: company policies (published) + own documents.
create or replace function public.list_my_documents() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  return hrms.ok(jsonb_build_object(
    'company', (select coalesce(jsonb_agg(jsonb_build_object(
                  'record_id', r.id, 'title', r.title, 'document_date', r.document_date,
                  'file_version_id', v.id, 'version_no', v.version_no, 'published_at', v.published_at,
                  'mime', coalesce(v.detected_mime, v.declared_mime), 'size_bytes', v.size_bytes)
                  order by v.published_at desc), '[]'::jsonb)
                from hrms.file_records r join hrms.file_versions v on v.id = r.current_version_id
                where r.org_id = v_actor.org_id and r.class = 'company_policy' and v.state = 'published'),
    'mine', (select coalesce(jsonb_agg(jsonb_build_object(
               'record_id', r.id, 'title', r.title, 'class', r.class, 'document_date', r.document_date,
               'file_version_id', v.id, 'version_no', v.version_no, 'state', v.state,
               'mime', coalesce(v.detected_mime, v.declared_mime), 'size_bytes', v.size_bytes,
               'created_at', v.created_at) order by v.created_at desc), '[]'::jsonb)
             from hrms.file_records r
             join lateral (select * from hrms.file_versions fv where fv.file_record_id = r.id
                           order by fv.version_no desc limit 1) v on true
             where r.owner_employee_id = v_actor.employee_id and r.class = 'employee_document'
               and v.state in ('validated', 'published', 'archived', 'deleted'))));
end;
$$;

-- Publish a validated document (company policy / employee document / avatar).
create or replace function public.publish_document(p_file_version_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_ver hrms.file_versions;
  v_rec hrms.file_records;
begin
  select * into v_ver from hrms.file_versions where id = p_file_version_id for update;
  if not found or v_ver.org_id <> v_actor.org_id then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_rec from hrms.file_records where id = v_ver.file_record_id for update;
  if v_rec.class not in ('company_policy', 'employee_document', 'avatar')
     or not hrms.can_upload(v_actor, v_rec.class, v_rec.owner_employee_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_ver.state <> 'validated' then
    perform hrms.raise_error('VALIDATION_FAILED', 'Only a validated upload can be published.');
  end if;
  if v_rec.current_version_id is not null then
    update hrms.file_versions set state = 'superseded' where id = v_rec.current_version_id and state = 'published';
  end if;
  update hrms.file_versions set state = 'published', published_at = now(), published_by = v_actor.employee_id,
                                supersedes_version_id = v_rec.current_version_id
  where id = v_ver.id;
  update hrms.file_records set current_version_id = v_ver.id, version = version + 1 where id = v_rec.id;
  if v_rec.class = 'avatar' then
    update hrms.employees set avatar_file_version_id = v_ver.id, version = version + 1
    where id = v_rec.owner_employee_id;
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'document.published', 'file_version', v_ver.id,
    jsonb_build_object('class', v_rec.class), 'business', v_rec.owner_employee_id);
  return hrms.ok(jsonb_build_object('file_version_id', v_ver.id, 'record_id', v_rec.id));
end;
$$;

-- Home extras: payslip availability card (no amounts are ever stored).
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
                       order by p.salary_month desc limit 1));
$$;

do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'hrms' loop
    execute format('alter table hrms.%I enable row level security', r.tablename);
  end loop;
end $$;

select hrms.apply_api_grants();
