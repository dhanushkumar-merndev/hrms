-- POL-001: company policies can be renamed and removed by the people who
-- publish them (Admin, or `policy.draft`), through the same audited rename /
-- remove path as employee documents. Removal hides the policy from everyone,
-- releases its storage and queues the bytes for deletion.

create or replace function hrms.can_edit_document(p_actor hrms.actor, p_rec hrms.file_records)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select hrms.can_edit_employee_document(p_actor, p_rec)
      or (p_rec.class = 'company_policy' and p_rec.org_id = p_actor.org_id and p_rec.removed_at is null
          and (hrms.is_admin(p_actor) or hrms.has_perm(p_actor, 'policy.draft')));
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
  if not found or not hrms.can_edit_document(v_actor, v_rec) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_title is null or char_length(v_title) > hrms.employee_document_title_max() then
    perform hrms.raise_error('VALIDATION_FAILED',
      format('Give the document a name of at most %s characters.', hrms.employee_document_title_max()),
      jsonb_build_object('title', format('1 to %s characters', hrms.employee_document_title_max())));
  end if;
  if v_title is distinct from v_rec.title then
    update hrms.file_records set title = v_title, version = version + 1 where id = v_rec.id returning * into v_rec;
    perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'document.renamed', 'file_record', v_rec.id,
                       jsonb_build_object('class', v_rec.class), 'business', v_rec.owner_employee_id);
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
  if not found or not hrms.can_edit_document(v_actor, v_rec) then
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
                     jsonb_build_object('bytes', v_bytes, 'class', v_rec.class), 'business', v_rec.owner_employee_id);
  return hrms.ok(jsonb_build_object('record_id', v_rec.id,
                                    'count', hrms.live_document_count(v_rec.owner_employee_id)));
end;
$$;

-- Same lists as before; company policies now carry `can_edit` and exclude
-- removed records.
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
                  'mime', coalesce(v.detected_mime, v.declared_mime), 'size_bytes', v.size_bytes,
                  'can_edit', hrms.can_edit_document(v_actor, r))
                  order by v.published_at desc), '[]'::jsonb)
                from hrms.file_records r join hrms.file_versions v on v.id = r.current_version_id
                where r.org_id = v_actor.org_id and r.class = 'company_policy' and r.removed_at is null
                  and v.state = 'published'),
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
    'can_upload', v_actor.employee_id is not null,
    'can_publish_policy', hrms.is_admin(v_actor) or hrms.has_perm(v_actor, 'policy.draft')));
end;
$$;

select hrms.apply_api_grants();
