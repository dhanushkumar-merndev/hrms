-- DOC-001..006: employee documents are PDF only, named (<= 50 chars), capped
-- at 10 per employee; employees manage their own uploads, HR manages all;
-- removal hides the document, frees the slot and queues the bytes for deletion.
begin;
select test.standard_org();

-- A published employee document created by p_by for p_owner.
create or replace function pg_temp.doc(p_owner text, p_by text, p_title text) returns uuid
language plpgsql security definer as $$
declare v_rec uuid; v_ver uuid; v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, title, created_by)
  values (v_org, test.emp(p_owner), 'employee_document', p_title, test.emp(p_by)) returning id into v_rec;
  insert into hrms.file_versions (org_id, file_record_id, version_no, state, object_key, original_filename, declared_mime,
                                  detected_mime, declared_size_bytes, size_bytes, sha256, validated_at, published_at)
  values (v_org, v_rec, 1, 'published', v_org || '/' || gen_random_uuid(), 'doc.pdf', 'application/pdf',
          'application/pdf', 1000, 1000, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now(), now())
  returning id into v_ver;
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  insert into hrms.storage_ledger (org_id, used_bytes) values (v_org, 1000)
  on conflict (org_id) do update set used_bytes = hrms.storage_ledger.used_bytes + 1000;
  return v_rec;
end $$;
create or replace function pg_temp.begin(p_code text, p_owner text, p_title text, p_mime text default 'application/pdf')
returns jsonb language sql as $$
  select public.internal_begin_upload(p.auth_user_id, p.session_id, p.alias, 'employee_document',
                                      case when p_owner is null then null else test.emp(p_owner) end,
                                      null, null, p_title, 'file.pdf', 1000, p_mime)
  from test.people p where p.code = p_code $$;
create or replace function pg_temp.used() returns bigint language sql security definer as $$
  select used_bytes from hrms.storage_ledger where org_id = test.org('TEST_ORG') $$;
create or replace function pg_temp.vstate(p_rec uuid) returns text language sql security definer as $$
  select string_agg(state, ',') from hrms.file_versions where file_record_id = p_rec $$;
create or replace function pg_temp.queued(p_rec uuid) returns integer language sql security definer as $$
  select count(*)::integer from hrms.file_purge_queue q join hrms.file_versions v on v.id = q.file_version_id
  where v.file_record_id = p_rec $$;

-- DOC-001 employees upload their own named PDFs; nothing else.
select test.as_service();
select test.ok((pg_temp.begin('EMP01', null, 'Aadhaar card') ->> 'file_version_id') is not null,
  'DOC-001 employee starts an upload of their own document');
select test.throws($q$select pg_temp.begin('EMP01', null, 'Photo', 'image/jpeg')$q$, 'INVALID_FILE_TYPE',
  'DOC-001 images are no longer accepted, PDF only');
select test.throws($q$select pg_temp.begin('EMP01', 'EMP02', 'Not mine')$q$, 'ACCESS_DENIED',
  'DOC-001 employee cannot upload for a colleague');
select test.throws(format('select pg_temp.begin(%L, null, %L)', 'EMP01', repeat('x', 51)), 'VALIDATION_FAILED',
  'DOC-001 names longer than 50 characters rejected');
select test.throws($q$select pg_temp.begin('EMP01', null, '   ')$q$, 'VALIDATION_FAILED', 'DOC-001 a name is required');
select test.ok((pg_temp.begin('HR01', 'EMP02', 'Offer letter') ->> 'file_version_id') is not null,
  'DOC-001 HR uploads for any employee');

-- DOC-002 at most 10 live documents per employee (uploads in progress count).
select test.as_admin_db();
select pg_temp.doc('EMP01', 'EMP01', 'Doc ' || g) from generate_series(1, 8) g;
create temporary table hr_doc as select pg_temp.doc('EMP01', 'HR01', 'Appointment letter') as id;
grant select on hr_doc to authenticated, service_role;
select test.eq(hrms.live_document_count(test.emp('EMP01')), 10, 'DOC-002 1 uploading + 9 published = 10');
select test.as_service();
select test.throws($q$select pg_temp.begin('EMP01', null, 'Eleventh')$q$, 'VALIDATION_FAILED',
  'DOC-002 the 11th document is refused');
select test.throws($q$select pg_temp.begin('HR01', 'EMP01', 'Eleventh')$q$, 'VALIDATION_FAILED',
  'DOC-002 the cap applies to HR too');
select test.ok((pg_temp.begin('EMP02', null, 'Own doc') ->> 'file_version_id') is not null,
  'DOC-002 the cap is per employee');
select test.login('EMP01');
select test.eq((public.list_my_documents() -> 'data' ->> 'count')::integer, 10, 'DOC-002 my list reports the count');
select test.eq((public.list_my_documents() -> 'data' ->> 'limit')::integer, 10, 'DOC-002 my list reports the limit');

-- DOC-003 rename: own uploads by the employee, everything by HR.
create temporary table own_doc as
  select (d ->> 'record_id')::uuid as id from jsonb_array_elements(public.list_my_documents() -> 'data' -> 'mine') d
  where d ->> 'title' = 'Doc 1';
grant select on own_doc to authenticated, service_role;
select test.eq((public.rename_employee_document((select id from own_doc), '  PAN card ') -> 'data' ->> 'title'),
  'PAN card', 'DOC-003 employee renames their own upload (trimmed)');
select test.throws(format('select public.rename_employee_document(%L, %L)', (select id from own_doc), repeat('y', 51)),
  'VALIDATION_FAILED', 'DOC-003 rename respects the 50 character limit');
select test.throws(format('select public.rename_employee_document(%L, %L)', (select id from hr_doc), 'Mine now'),
  'ACCESS_DENIED', 'DOC-003 employee cannot rename a document HR added');
select test.eq((select bool_and(d ->> 'can_edit' = (d ->> 'added_by_me'))
                from jsonb_array_elements(public.list_my_documents() -> 'data' -> 'mine') d), true,
  'DOC-003 can_edit only on own uploads');
select test.login('EMP02');
select test.throws(format('select public.rename_employee_document(%L, %L)', (select id from own_doc), 'x'),
  'ACCESS_DENIED', 'DOC-003 colleague cannot rename');
select test.login('HR01');
select test.eq((public.rename_employee_document((select id from hr_doc), 'Appointment letter 2025') -> 'data' ->> 'title'),
  'Appointment letter 2025', 'DOC-003 HR renames any document');

-- DOC-004 remove frees the slot, hides the document and queues the bytes.
select test.login('EMP01');
select test.throws(format('select public.remove_employee_document(%L)', (select id from hr_doc)), 'ACCESS_DENIED',
  'DOC-004 employee cannot remove a document HR added');
create temporary table before as select pg_temp.used() as b;
grant select on before to authenticated, service_role;
select test.eq((public.remove_employee_document((select id from own_doc)) -> 'data' ->> 'count')::integer, 9,
  'DOC-004 removal frees a slot');
select test.eq(pg_temp.vstate((select id from own_doc)), 'deleted', 'DOC-004 versions are deleted');
select test.eq(pg_temp.queued((select id from own_doc)), 1, 'DOC-004 stored bytes queued for deletion');
select test.eq(pg_temp.used(), (select b from before) - 1000, 'DOC-004 storage usage released');
select test.ok(not exists (select 1 from jsonb_array_elements(public.list_my_documents() -> 'data' -> 'mine') d
                           where d ->> 'record_id' = (select id from own_doc)::text), 'DOC-004 hidden from my list');
select test.throws(format('select public.remove_employee_document(%L)', (select id from own_doc)), 'ACCESS_DENIED',
  'DOC-004 removing twice is refused');
select test.login('HR01');
select test.ok(not exists (select 1 from jsonb_array_elements(public.list_employee_files(test.emp('EMP01')) -> 'data' -> 'documents') d
                           where d ->> 'record_id' = (select id from own_doc)::text), 'DOC-004 hidden from HR too');
select test.eq((public.list_employee_files(test.emp('EMP01')) -> 'data' ->> 'document_count')::integer, 9,
  'DOC-004 HR sees the new count');
select test.eq((public.remove_employee_document((select id from hr_doc)) -> 'data' ->> 'count')::integer, 8,
  'DOC-004 HR removes any document');
select test.as_service();
select test.ok((pg_temp.begin('EMP01', null, 'Degree certificate') ->> 'file_version_id') is not null,
  'DOC-004 a freed slot can be used again');
select test.login('EMP09');
select test.throws(format('select public.remove_employee_document(%L)', (select id from own_doc)), 'ACCESS_DENIED',
  'DOC-004 other organisation denied');

-- DOC-005 the purge queue is service only and confirms what Storage deleted.
select test.login('ADMIN01');
select test.throws('select public.internal_file_purge_claim()', 'permission denied', 'DOC-005 clients cannot claim');
select test.as_service();
create temporary table claimed as select public.internal_file_purge_claim() as c;
grant select on claimed to authenticated, service_role;
select test.eq((select jsonb_array_length(c) from claimed), 2, 'DOC-005 both removed files claimed');
select test.eq((public.internal_file_purge_done(array[(select (c -> 0 ->> 'id')::bigint from claimed)]) ->> 'purged')::integer, 1,
  'DOC-005 confirmed item leaves the queue');
select test.eq(jsonb_array_length(public.internal_file_purge_claim()), 1, 'DOC-005 unconfirmed item is retried');

-- DOC-006 removed documents never enter an annual archive export.
select test.as_admin_db();
insert into hrms.archive_periods (org_id, period_start, period_end, kind, start_month)
values (test.org('TEST_ORG'), date '2026-01-01', date '2026-12-31', 'annual', 1);
insert into hrms.export_jobs (org_id, period_id, period_start, period_end, timezone, revision, state, as_of,
                              manifest_hash, ready_expires_at, created_by)
select test.org('TEST_ORG'), p.id, p.period_start, p.period_end, 'Asia/Kolkata', 1, 'ready', now(), '',
       now() + interval '1 day', test.emp('ADMIN01')
from hrms.archive_periods p where p.org_id = test.org('TEST_ORG') and p.period_start = date '2026-01-01';
create temporary table ej as select j.id from hrms.export_jobs j where j.org_id = test.org('TEST_ORG')
  and j.period_start = date '2026-01-01';
insert into hrms.export_items (job_id, file_version_id, employee_id, class, business_date, path, size_bytes, sha256,
                               version_state, source)
select (select id from ej), v.id, test.emp('EMP01'), 'employee_document', date '2026-06-01', 'x/' || v.id, 1000, v.sha256,
       v.state, 'local_base'
from hrms.file_versions v where v.file_record_id in ((select id from own_doc), (select id from hr_doc))
union all
select (select id from ej), v.id, test.emp('EMP01'), 'employee_document', date '2026-06-01', 'x/' || v.id, 1000, v.sha256,
       v.state, 'cloud'
from hrms.file_records r join hrms.file_versions v on v.id = r.current_version_id
where r.owner_employee_id = test.emp('EMP01') and r.removed_at is null and v.state = 'published' and r.title = 'Doc 2';
select test.eq((select count(*)::integer from hrms.export_items where job_id = (select id from ej)), 1,
  'DOC-006 only the live document is exported');

rollback;
