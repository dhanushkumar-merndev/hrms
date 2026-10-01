-- =============================================================================
-- Employee documents: up to 10 named PDFs per employee.
--
-- * Employees add their own documents; HR (hr.master_data) and Admin add them
--   for anyone. New uploads are PDF only (older images stay readable).
-- * Every document needs a name of at most 50 characters.
-- * At most 10 live documents per employee, enforced when the upload starts
--   (serialised per employee, so parallel uploads cannot overshoot).
-- * Rename and remove: HR/Admin for any document, the employee only for the
--   ones they added themselves. Removal deletes the stored bytes (queued for
--   the maintenance tick) and leaves a tombstone + audit row without content.
-- =============================================================================

create or replace function hrms.employee_document_limit() returns integer
language sql immutable set search_path = '' as $$ select 10 $$;

create or replace function hrms.employee_document_title_max() returns integer
language sql immutable set search_path = '' as $$ select 50 $$;

alter table hrms.file_records
  add column removed_at timestamptz,
  add column removed_by uuid;

-- Bytes of removed documents waiting to be deleted from Storage.
create table hrms.file_purge_queue (
  id bigserial primary key,
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  file_version_id uuid not null references hrms.file_versions(id) on delete restrict,
  object_key text not null,
  attempts integer not null default 0,
  created_at timestamptz not null default now()
);
alter table hrms.file_purge_queue enable row level security;

create or replace function hrms.allowed_mimes(p_class text) returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_class
    when 'payslip' then array['application/pdf']
    when 'employee_document' then array['application/pdf']
    when 'avatar' then array['image/jpeg', 'image/png', 'image/webp']
    else array['application/pdf', 'image/jpeg', 'image/png'] end;
$$;

create or replace function hrms.can_upload(p_actor hrms.actor, p_class text, p_owner uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case p_class
    when 'payslip' then hrms.can_manage_payroll(p_actor)
    when 'avatar' then p_owner = p_actor.employee_id or hrms.has_perm(p_actor, 'hr.master_data')
    when 'employee_document' then p_owner = p_actor.employee_id or hrms.is_admin(p_actor)
                                  or hrms.has_perm(p_actor, 'hr.master_data')
    when 'company_policy' then hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'policy.draft')
    else p_owner = p_actor.employee_id end;
$$;

-- Live = not removed and its latest version is uploading or usable. Expired
-- or rejected uploads and documents already archived off the cloud do not
-- take a slot.
create or replace function hrms.live_document_count(p_employee uuid) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from hrms.file_records r
  join lateral (select fv.state from hrms.file_versions fv where fv.file_record_id = r.id
                order by fv.version_no desc limit 1) v on true
  where r.owner_employee_id = p_employee and r.class = 'employee_document' and r.removed_at is null
    and v.state in ('requested', 'quarantined', 'validated', 'published');
$$;

-- Name + cap check on every new employee document, whichever path creates it.
create or replace function hrms.employee_document_insert_guard() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.class <> 'employee_document' then
    return new;
  end if;
  if new.title is null or char_length(new.title) > hrms.employee_document_title_max() then
    perform hrms.raise_error('VALIDATION_FAILED',
      format('Give the document a name of at most %s characters.', hrms.employee_document_title_max()),
      jsonb_build_object('title', format('1 to %s characters', hrms.employee_document_title_max())));
  end if;
  perform pg_advisory_xact_lock(hashtext('hrms.employee_document'), hashtext(new.owner_employee_id::text));
  if hrms.live_document_count(new.owner_employee_id) >= hrms.employee_document_limit() then
    perform hrms.raise_error('VALIDATION_FAILED',
      format('There are already %s documents for this employee. Remove one to add another.',
             hrms.employee_document_limit()),
      jsonb_build_object('file', format('Limit of %s documents reached', hrms.employee_document_limit())));
  end if;
  return new;
end;
$$;
create trigger file_records_employee_document_guard before insert on hrms.file_records
  for each row execute function hrms.employee_document_insert_guard();

create or replace function hrms.can_edit_employee_document(p_actor hrms.actor, p_rec hrms.file_records)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_rec.class = 'employee_document' and p_rec.org_id = p_actor.org_id and p_rec.removed_at is null
     and (hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'hr.master_data')
          or (p_rec.owner_employee_id = p_actor.employee_id and p_rec.created_by = p_actor.employee_id));
$$;

create or replace function public.rename_employee_document(p_record_id uuid, p_title text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_rec hrms.file_records;
  v_title text := hrms.clean_text(p_title, 200);
begin
  select * into v_rec from hrms.file_records where id = p_record_id for update;
  if not found or not hrms.can_edit_employee_document(v_actor, v_rec) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_title is null or char_length(v_title) > hrms.employee_document_title_max() then
    perform hrms.raise_error('VALIDATION_FAILED',
      format('Give the document a name of at most %s characters.', hrms.employee_document_title_max()),
      jsonb_build_object('title', format('1 to %s characters', hrms.employee_document_title_max())));
  end if;
  if v_title is distinct from v_rec.title then
    update hrms.file_records set title = v_title, version = version + 1 where id = v_rec.id returning * into v_rec;
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'document.renamed', 'file_record', v_rec.id, null,
                       'business', v_rec.owner_employee_id);
  end if;
  return hrms.ok(jsonb_build_object('record_id', v_rec.id, 'title', v_rec.title), v_rec.version);
end;
$$;

create or replace function public.remove_employee_document(p_record_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_rec hrms.file_records;
  v_bytes bigint;
begin
  select * into v_rec from hrms.file_records where id = p_record_id for update;
  if not found or not hrms.can_edit_employee_document(v_actor, v_rec) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if exists (select 1 from hrms.file_versions where file_record_id = v_rec.id
             and state in ('requested', 'quarantined')) then
    perform hrms.raise_error('VALIDATION_FAILED', 'This document is still uploading. Try again in a minute.', null, true);
  end if;
  if exists (select 1 from hrms.file_versions where file_record_id = v_rec.id and state = 'deletion_pending') then
    perform hrms.raise_error('PERIOD_BUSY', 'Files for this period are being cleaned up. Try again later.', null, true);
  end if;

  insert into hrms.file_purge_queue (org_id, file_version_id, object_key)
  select v.org_id, v.id, v.object_key from hrms.file_versions v
  where v.file_record_id = v_rec.id and v.state in ('validated', 'published', 'superseded') and v.object_key is not null;

  with gone as (
    update hrms.file_versions v
       set state = 'deleted', deleted_at = now(), deleted_by = v_actor.employee_id,
           tombstone = jsonb_build_object('sha256', v.sha256, 'size_bytes', v.size_bytes, 'removed', true,
                                          'deleted_at', now())
     where v.file_record_id = v_rec.id and v.state in ('validated', 'published', 'superseded')
    returning v.size_bytes
  )
  select coalesce(sum(size_bytes), 0) into v_bytes from gone;
  update hrms.storage_ledger set used_bytes = greatest(0, used_bytes - v_bytes), updated_at = now()
  where org_id = v_rec.org_id;

  update hrms.file_records set removed_at = now(), removed_by = v_actor.employee_id, version = version + 1
  where id = v_rec.id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'document.removed', 'file_record', v_rec.id,
                     jsonb_build_object('bytes', v_bytes), 'business', v_rec.owner_employee_id);
  return hrms.ok(jsonb_build_object('record_id', v_rec.id,
                                    'count', hrms.live_document_count(v_rec.owner_employee_id)));
end;
$$;

-- Annual archives list deleted versions as "already in the local archive";
-- a removed document never was, so it is left out of every new export.
create or replace function hrms.export_items_skip_removed() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.file_version_id is not null and exists (
       select 1 from hrms.file_versions v join hrms.file_records r on r.id = v.file_record_id
       where v.id = new.file_version_id and r.removed_at is not null
         and coalesce((v.tombstone ->> 'removed')::boolean, false)) then
    return null;
  end if;
  return new;
end;
$$;
create trigger export_items_skip_removed before insert on hrms.export_items
  for each row execute function hrms.export_items_skip_removed();

-- Maintenance: claim queued objects; the worker deletes them from Storage
-- and confirms, so a failed delete is retried on the next tick.
create or replace function public.internal_file_purge_claim() returns jsonb
language sql
security definer
set search_path = ''
as $$
  with c as (
    update hrms.file_purge_queue q set attempts = q.attempts + 1
    where q.id in (select id from hrms.file_purge_queue where attempts < 10 order by id limit 200
                   for update skip locked)
    returning q.id, q.object_key
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'key', object_key)), '[]'::jsonb) from c;
$$;

create or replace function public.internal_file_purge_done(p_ids bigint[]) returns jsonb
language sql
security definer
set search_path = ''
as $$
  with d as (delete from hrms.file_purge_queue where id = any(coalesce(p_ids, '{}')) returning 1)
  select jsonb_build_object('purged', count(*)) from d;
$$;

-- Listings hide removed documents and report the slot count.
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
               'created_at', v.created_at, 'added_by_me', r.created_by = v_actor.employee_id,
               'can_edit', hrms.can_edit_employee_document(v_actor, r)) order by v.created_at desc), '[]'::jsonb)
             from hrms.file_records r
             join lateral (select * from hrms.file_versions fv where fv.file_record_id = r.id
                           order by fv.version_no desc limit 1) v on true
             where r.owner_employee_id = v_actor.employee_id and r.class = 'employee_document'
               and r.removed_at is null
               and v.state in ('validated', 'published', 'archived', 'deleted')),
    'count', hrms.live_document_count(v_actor.employee_id),
    'limit', hrms.employee_document_limit(),
    'title_max', hrms.employee_document_title_max(),
    'can_upload', v_actor.employee_id is not null));
end;
$$;

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
        'size_bytes', v.size_bytes, 'created_at', v.created_at,
        'added_by_employee', r.created_by = r.owner_employee_id,
        'can_edit', hrms.can_edit_employee_document(v_actor, r)) order by v.created_at desc), '[]'::jsonb)
      from hrms.file_records r
      join lateral (select * from hrms.file_versions fv where fv.file_record_id = r.id
                      and fv.state in ('validated', 'published', 'superseded', 'deletion_pending', 'deleted')
                    order by fv.version_no desc limit 1) v on true
      where r.owner_employee_id = p_employee_id and r.class = 'employee_document' and r.removed_at is null),
    'payslips', case when v_payroll then (select coalesce(jsonb_agg(jsonb_build_object(
        'salary_month', p.salary_month, 'file_version_id', p.current_file_version_id, 'state', v.state,
        'published_at', p.published_at, 'version', p.version) order by p.salary_month desc), '[]'::jsonb)
      from hrms.payslips p left join hrms.file_versions v on v.id = p.current_file_version_id
      where p.employee_id = p_employee_id) end,
    'can_upload', hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'hr.master_data'),
    'can_manage_payroll', v_payroll,
    'document_count', hrms.live_document_count(p_employee_id),
    'document_limit', hrms.employee_document_limit(),
    'title_max', hrms.employee_document_title_max()));
end;
$$;

select hrms.apply_api_grants();
