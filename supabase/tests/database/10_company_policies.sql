-- POL-001..003: everyone reads company policies; Admin and `policy.draft`
-- holders (HR by default) rename and remove them; removal hides the policy,
-- releases storage and queues the bytes for deletion.
begin;
select test.standard_org();

create or replace function pg_temp.policy(p_by text, p_title text) returns uuid
language plpgsql security definer as $$
declare v_rec uuid; v_ver uuid; v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, title, created_by)
  values (v_org, null, 'company_policy', p_title, test.emp(p_by)) returning id into v_rec;
  insert into hrms.file_versions (org_id, file_record_id, version_no, state, object_key, original_filename, declared_mime,
                                  detected_mime, declared_size_bytes, size_bytes, sha256, validated_at, published_at)
  values (v_org, v_rec, 1, 'published', v_org || '/' || gen_random_uuid(), 'policy.pdf', 'application/pdf',
          'application/pdf', 2000, 2000, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'), now(), now())
  returning id into v_ver;
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  insert into hrms.storage_ledger (org_id, used_bytes) values (v_org, 2000)
  on conflict (org_id) do update set used_bytes = hrms.storage_ledger.used_bytes + 2000;
  return v_rec;
end $$;
create or replace function pg_temp.used() returns bigint language sql security definer as $$
  select used_bytes from hrms.storage_ledger where org_id = test.org('TEST_ORG') $$;
create or replace function pg_temp.vstate(p_rec uuid) returns text language sql security definer as $$
  select string_agg(state, ',') from hrms.file_versions where file_record_id = p_rec $$;
create or replace function pg_temp.queued(p_rec uuid) returns integer language sql security definer as $$
  select count(*)::integer from hrms.file_purge_queue q join hrms.file_versions v on v.id = q.file_version_id
  where v.file_record_id = p_rec $$;
create or replace function pg_temp.listed(p_rec uuid) returns jsonb language sql as $$
  select d from jsonb_array_elements(public.list_my_documents() -> 'data' -> 'company') d
  where d ->> 'record_id' = p_rec::text $$;

select test.as_admin_db();
create temporary table pol as select pg_temp.policy('ADMIN01', 'Leave policy 2026') as id;
grant select on pol to authenticated, service_role;

-- POL-001 everyone sees it; only Admin and policy.draft may edit or publish.
select test.login('EMP01');
select test.ok(pg_temp.listed((select id from pol)) is not null, 'POL-001 employees see company policies');
select test.eq(pg_temp.listed((select id from pol)) ->> 'can_edit', 'false', 'POL-001 employee cannot edit');
select test.eq(public.list_my_documents() -> 'data' ->> 'can_publish_policy', 'false', 'POL-001 employee cannot publish');
select test.login('MGR01');
select test.eq(pg_temp.listed((select id from pol)) ->> 'can_edit', 'false', 'POL-001 manager cannot edit');
select test.login('HR01');
select test.eq(pg_temp.listed((select id from pol)) ->> 'can_edit', 'true', 'POL-001 HR (policy.draft) can edit');
select test.eq(public.list_my_documents() -> 'data' ->> 'can_publish_policy', 'true', 'POL-001 HR can publish');
select test.login('ADMIN01');
select test.eq(pg_temp.listed((select id from pol)) ->> 'can_edit', 'true', 'POL-001 Admin can edit');

-- POL-002 rename and remove are refused without policy rights.
select test.login('EMP01');
select test.throws(format('select public.rename_employee_document(%L, %L)', (select id from pol), 'Mine'),
  'ACCESS_DENIED', 'POL-002 employee cannot rename a policy');
select test.throws(format('select public.remove_employee_document(%L)', (select id from pol)),
  'ACCESS_DENIED', 'POL-002 employee cannot remove a policy');
select test.login('MGR01');
select test.throws(format('select public.remove_employee_document(%L)', (select id from pol)),
  'ACCESS_DENIED', 'POL-002 manager cannot remove a policy');
select test.login('EMP09');
select test.throws(format('select public.remove_employee_document(%L)', (select id from pol)),
  'ACCESS_DENIED', 'POL-002 other organisation denied');

-- POL-003 HR renames; Admin removes, which hides it and frees storage.
select test.login('HR01');
select test.eq(public.rename_employee_document((select id from pol), ' Leave policy 2027 ') -> 'data' ->> 'title',
  'Leave policy 2027', 'POL-003 HR renames a policy (trimmed)');
select test.login('ADMIN01');
create temporary table before as select pg_temp.used() as b;
grant select on before to authenticated, service_role;
select test.eq(public.remove_employee_document((select id from pol)) -> 'data' ->> 'record_id', (select id from pol)::text,
  'POL-003 Admin removes a policy');
select test.eq(pg_temp.vstate((select id from pol)), 'deleted', 'POL-003 versions are deleted');
select test.eq(pg_temp.queued((select id from pol)), 1, 'POL-003 stored bytes queued for deletion');
select test.eq(pg_temp.used(), (select b from before) - 2000, 'POL-003 storage usage released');
select test.ok(pg_temp.listed((select id from pol)) is null, 'POL-003 hidden from the list');
select test.throws(format('select public.remove_employee_document(%L)', (select id from pol)),
  'ACCESS_DENIED', 'POL-003 removing twice is refused');
select test.login('EMP01');
select test.ok(pg_temp.listed((select id from pol)) is null, 'POL-003 hidden from employees too');

rollback;
