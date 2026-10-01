-- EXP-001..019 and DEL-001..012 against the real archive/cleanup functions,
-- called as the actual API roles. The closed period is the previous calendar
-- year in the organisation's zone, so the suite runs on any date.
begin;
select test.standard_org();
select test.person('TEST_ORG', 'ADMIN02', 'Admin B', array['admin']);
select test.person('TEST_ORG', 'EMPOLD', 'Old Timer', '{}', date '2020-01-01');

create or replace function pg_temp.y() returns integer language sql security definer as $$
  select extract(year from hrms.org_today(test.org('TEST_ORG')))::integer $$;
create or replace function pg_temp.period(p_year integer) returns uuid language sql security definer as $$
  select id from hrms.archive_periods where org_id = test.org('TEST_ORG') and period_start = make_date(p_year, 1, 1) $$;
create or replace function pg_temp.tasks() returns jsonb language sql security definer as $$
  select hrms.admin_tasks(test.org('TEST_ORG')) $$;
create or replace function pg_temp.dec_visible() returns integer language sql security definer as $$
  select case when make_date(pg_temp.y() - 1, 12, 1) >= hrms.payslip_window_start(test.org('TEST_ORG')) then 1 else 0 end $$;
create or replace function pg_temp.sha(p text) returns text language sql security definer as $$ select hrms.sha256_hex(p) $$;
create or replace function pg_temp.local_ids(p_job uuid) returns uuid[] language sql security definer as $$
  select array_agg(file_version_id) from hrms.export_items where job_id = p_job and source = 'local_base' $$;
create or replace function pg_temp.local_bytes(p_job uuid) returns bigint language sql security definer as $$
  select coalesce(sum(size_bytes), 0)::bigint from hrms.export_items where job_id = p_job and source = 'local_base' $$;
create or replace function pg_temp.current_ver(p_record uuid) returns uuid language sql security definer as $$
  select current_version_id from hrms.file_records where id = p_record $$;
create or replace function pg_temp.org_version() returns integer language sql security definer as $$
  select version from hrms.organizations where id = test.org('TEST_ORG') $$;
create or replace function pg_temp.reauth(p_code text, p_action text, p_target uuid) returns void
language sql security definer as $$
  insert into hrms.reauthentication_grants (org_id, employee_id, session_id, action, target_id, issued_at, expires_at)
  select p.org_id, p.employee_id, p.session_id, p_action, p_target, now(), now() + interval '4 minutes'
  from test.people p where p.code = p_code;
$$;

-- File fixtures (fake bytes metadata only; hashes are random but well formed).
create or replace function pg_temp.version(p_record uuid, p_no integer, p_state text) returns uuid
language sql security definer as $$
  insert into hrms.file_versions (org_id, file_record_id, version_no, state, object_key, original_filename, declared_mime,
                                  detected_mime, declared_size_bytes, size_bytes, sha256, validated_at, published_at)
  select r.org_id, r.id, p_no, p_state, r.org_id || '/' || gen_random_uuid(), 'file.pdf', 'application/pdf',
         'application/pdf', 1000 + p_no, 1000 + p_no, encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'),
         now(), now()
  from hrms.file_records r where r.id = p_record
  returning id;
$$;
create or replace function pg_temp.slip(p_code text, p_month date, p_versions integer) returns uuid
language plpgsql security definer as $$
declare v_rec uuid; v_ver uuid; v_org uuid := test.org('TEST_ORG');
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, period_start, period_end, title)
  values (v_org, test.emp(p_code), 'payslip', p_month, (p_month + interval '1 month - 1 day')::date, 'Payslip')
  returning id into v_rec;
  for i in 1 .. p_versions loop
    v_ver := pg_temp.version(v_rec, i, case when i = p_versions then 'published' else 'superseded' end);
  end loop;
  insert into hrms.payslips (org_id, employee_id, salary_month, file_record_id, current_file_version_id, published_at)
  values (v_org, test.emp(p_code), p_month, v_rec, v_ver, now());
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  return v_rec;
end $$;
create or replace function pg_temp.doc(p_code text, p_class text, p_date date, p_title text) returns uuid
language plpgsql security definer as $$
declare v_rec uuid; v_ver uuid;
begin
  insert into hrms.file_records (org_id, owner_employee_id, class, document_date, title)
  values (test.org('TEST_ORG'), test.emp(p_code), p_class, p_date, p_title) returning id into v_rec;
  v_ver := pg_temp.version(v_rec, 1, 'published');
  update hrms.file_records set current_version_id = v_ver where id = v_rec;
  return v_rec;
end $$;
create or replace function pg_temp.session_on(p_code text, p_day date) returns uuid
language plpgsql security definer as $$
declare v_inst hrms.work_schedule_instances; v_id uuid;
begin
  perform hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp(p_code)], p_day, p_day);
  select * into v_inst from hrms.work_schedule_instances where employee_id = test.emp(p_code) and shift_date = p_day;
  insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state,
                                        effective_in_at, effective_out_at, effective_source)
  values (v_inst.org_id, v_inst.employee_id, v_inst.id, p_day, 'closed', v_inst.start_at, v_inst.end_at, 'manual')
  returning id into v_id;
  return v_id;
end $$;
create or replace function pg_temp.claim(p_code text, p_job uuid, p_worker uuid, p_limit integer,
                                         p_reconcile boolean default false) returns jsonb language sql as $$
  select public.internal_cleanup_claim(p.auth_user_id, p.session_id, p.alias, p_job, p_worker, p_limit, p_reconcile)
  from test.people p where p.code = p_code;
$$;
create or replace function pg_temp.complete(p_code text, p_job uuid, p_worker uuid, p_results jsonb) returns jsonb
language sql as $$
  select public.internal_cleanup_complete(p.auth_user_id, p.session_id, p.alias, p_job, p_worker, p_results)
  from test.people p where p.code = p_code;
$$;
create or replace function pg_temp.ok_results(p_claim jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object('item_id', (i ->> 'item_id')::bigint, 'ok', true)), '[]'::jsonb)
  from jsonb_array_elements(p_claim -> 'items') i;
$$;
create or replace function pg_temp.vstate(p_version uuid) returns text language sql security definer as $$
  select state from hrms.file_versions where id = p_version $$;
create or replace function pg_temp.current_slip_version(p_record uuid) returns uuid language sql security definer as $$
  select current_file_version_id from hrms.payslips where file_record_id = p_record $$;

-- Fixtures in the closed previous year (Y-1), the current year and Y-2.
create temporary table fx as select
  pg_temp.slip('EMP01', make_date(pg_temp.y() - 1, 3, 1), 2) as mar,
  pg_temp.slip('EMP01', make_date(pg_temp.y() - 1, 12, 1), 1) as dec,
  pg_temp.slip('EMP01', make_date(pg_temp.y(), 1, 1), 1) as cur,
  pg_temp.doc('EMP01', 'employee_document', make_date(pg_temp.y() - 1, 6, 15), 'Offer letter.pdf') as letter,
  pg_temp.doc('EMP01', 'avatar', null, 'Photo') as avatar,
  pg_temp.doc('EMP01', 'employee_document', null, 'Undated contract') as undated,
  pg_temp.slip('EMPOLD', make_date(pg_temp.y() - 2, 1, 1), 1) as old1,
  pg_temp.slip('EMPOLD', make_date(pg_temp.y() - 2, 2, 1), 1) as old2,
  pg_temp.slip('EMPOLD', make_date(pg_temp.y() - 2, 3, 1), 1) as old3,
  pg_temp.session_on('EMP01', make_date(pg_temp.y() - 1, 7, 1)) as past_session;
grant select on fx to authenticated, service_role;

-- ============================================================ periods (S34)
select test.login('ADMIN01');
create temporary table ov as select public.get_archive_overview() -> 'data' as d;
grant select on ov to authenticated, service_role;
select test.ok((select jsonb_array_length(d -> 'periods') >= 3 from ov), 'periods materialised back to earliest joining');
select test.eq((select (p ->> 'closed')::boolean from ov, jsonb_array_elements(d -> 'periods') p
                where p ->> 'period_start' = make_date(pg_temp.y() - 1, 1, 1)::text), true, 'EXP-001 previous year closed');
select test.eq((select (p ->> 'closed')::boolean from ov, jsonb_array_elements(d -> 'periods') p
                where p ->> 'period_start' = make_date(pg_temp.y(), 1, 1)::text), false, 'EXP-001 current year open');
select test.eq((select p ->> 'label' from ov, jsonb_array_elements(d -> 'periods') p
                where p ->> 'period_start' = make_date(pg_temp.y() - 1, 1, 1)::text), (pg_temp.y() - 1)::text,
  'Jan–Dec period label is the year');
select test.ok((select (select jsonb_agg(t ->> 'kind') from jsonb_array_elements(
                  pg_temp.tasks()) t) ? 'archive_due'), 'EXP-014 archive due task after year end');

-- EXP-001 / EXP-013: gates before any snapshot.
select test.throws(format('select public.create_archive_export(%L)', pg_temp.period(pg_temp.y())),
  'PERIOD_NOT_CLOSED', 'EXP-001 current period cannot be archived');
select test.throws(format('select public.create_archive_export(%L)', pg_temp.period(pg_temp.y() - 1)),
  'REAUTH_REQUIRED', 'annual export needs recent password confirmation');
select test.login('HR01');
select test.throws(format('select public.create_archive_export(%L)', pg_temp.period(pg_temp.y() - 1)),
  'ACCESS_DENIED', 'EXP-013 HR cannot export');
select test.login('EMP01');
select test.throws('select public.get_archive_overview()', 'ACCESS_DENIED', 'EXP-013 member denied overview');

-- ============================================================ snapshot r1
select test.as_admin_db();
select pg_temp.reauth('ADMIN01', 'export.annual', pg_temp.period(pg_temp.y() - 1));
select test.login('ADMIN01');
create temporary table r1 as select public.create_archive_export(pg_temp.period(pg_temp.y() - 1)) -> 'data' as j;
grant select on r1 to authenticated, service_role;
select test.eq((select j ->> 'state' from r1), 'ready', 'snapshot r1 ready');
select test.eq((select (j ->> 'revision')::integer from r1), 1, 'revision 1');
select test.eq((select (j ->> 'file_count')::integer from r1), 4, 'EXP-003 only Y-1 business-dated files (2 revisions + 1 slip + 1 doc)');
select test.eq((select (j ->> 'requires_local_base')::boolean from r1), false, 'no local base needed yet');
select test.ok((select (j ->> 'manifest_hash') ~ '^[0-9a-f]{64}$' from r1), 'manifest hash recorded');
select test.ok((select (j -> 'row_counts' ->> 'attendance_rows')::integer > 200 from r1), 'attendance rows frozen for the year');
select test.eq((select count(*)::integer from jsonb_array_elements((select j -> 'exclusions' from r1)) x
                where x ->> 'kind' in ('avatar', 'undated_document') and (x ->> 'count')::integer >= 1), 2,
  'DEL-006 avatars and undated documents listed as exclusions');

create temporary table m1 as select public.get_export_manifest((select (j ->> 'id')::uuid from r1)) -> 'data' as m;
grant select on m1 to authenticated, service_role;
select test.ok((select bool_or(i ->> 'path' like '%/Payslips/' || (pg_temp.y() - 1) || '/' || (pg_temp.y() - 1) || '-03.pdf')
                from m1, jsonb_array_elements(m -> 'items') i), 'EXP-007 current revision at Payslips/YYYY/YYYY-MM.pdf');
select test.ok((select bool_or(i ->> 'path' like '%/Revisions/' || (pg_temp.y() - 1) || '-03_v1.pdf')
                from m1, jsonb_array_elements(m -> 'items') i), 'EXP-007 superseded revision included under Revisions/');
select test.ok((select bool_and(i ->> 'path' like 'Employees/EMP01_Employee E1/%')
                from m1, jsonb_array_elements(m -> 'items') i), 'EXP-008 employee-code folder, safe relative paths');
select test.ok((select not bool_or(i ->> 'path' like '%..%' or i ->> 'path' like '/%')
                from m1, jsonb_array_elements(m -> 'items') i), 'EXP-008 no traversal or absolute paths');
-- The canonical manifest recomputes to the stored hash (app mirrors this).
select test.eq((select pg_temp.sha(concat_ws(E'\n', 'hrms-archive-v1', 'job:' || (m ->> 'id'),
                  'period:' || (m ->> 'period_start') || '..' || (m ->> 'period_end'), 'revision:' || (m ->> 'revision'),
                  (select string_agg('file:' || (i ->> 'path') || '|' || (i ->> 'size_bytes') || '|' || (i ->> 'sha256')
                                     || '|' || (i ->> 'file_version_id') || '|' || (i ->> 'source'), E'\n'
                                     order by i ->> 'path' collate "C") from jsonb_array_elements(m -> 'items') i),
                  (select string_agg('employee:' || (e ->> 'employee_id') || '|' || (e ->> 'attendance_count') || '|'
                                     || (e ->> 'leave_count'), E'\n' order by e ->> 'employee_id' collate "C")
                   from jsonb_array_elements(m -> 'employees') e))) from m1),
  (select j ->> 'manifest_hash' from r1), 'canonical manifest recomputes to the stored hash');
select test.ok((select jsonb_array_length(public.get_export_employee((select (j ->> 'id')::uuid from r1), test.emp('EMP01'))
                  -> 'data' -> 'attendance') > 200), 'per-employee frozen rows readable');

-- Export file link: only inventoried cloud files, Admin only.
select test.as_service();
select test.eq((select (public.internal_authorize_export_file(p.auth_user_id, p.session_id, p.alias,
                  (select (j ->> 'id')::uuid from r1), (select (m -> 'items' -> 0 ->> 'file_version_id')::uuid from m1))
                  ->> 'available')::boolean from test.people p where p.code = 'ADMIN01'), true,
  'export link issued for an inventoried file');
select test.throws(format($q$select public.internal_authorize_export_file(p.auth_user_id, p.session_id, p.alias, %L, %L)
                            from test.people p where p.code = 'ADMIN01'$q$,
                          (select j ->> 'id' from r1), pg_temp.current_ver((select avatar from fx))),
  'ACCESS_DENIED', 'no export link for a file outside the inventory');
select test.throws(format($q$select public.internal_authorize_export_file(p.auth_user_id, p.session_id, p.alias, %L, %L)
                            from test.people p where p.code = 'HR01'$q$,
                          (select j ->> 'id' from r1), (select m -> 'items' -> 0 ->> 'file_version_id' from m1)),
  'ACCESS_DENIED', 'EXP-013 HR cannot fetch archive files');

-- ============================================================ staleness
select test.as_admin_db();
select pg_temp.session_on('EMP02', hrms.org_today(test.org('TEST_ORG')));
select test.eq((select stale_at is null from hrms.export_jobs where id = (select (j ->> 'id')::uuid from r1)), true,
  'EXP-006 current-period attendance does not invalidate the closed-year snapshot');
update hrms.attendance_sessions set effective_out_at = effective_out_at - interval '1 hour', version = version + 1
where id = (select past_session from fx);
select test.eq((select stale_at is not null from hrms.export_jobs where id = (select (j ->> 'id')::uuid from r1)), true,
  'EXP-005 a later change to the period marks the snapshot stale');
select test.login('ADMIN01');
select test.throws(format('select public.acknowledge_export(%L, %L, %s, %s, false, null, true)',
                          (select j ->> 'id' from r1), (select j ->> 'manifest_hash' from r1),
                          (select j ->> 'file_count' from r1), (select j ->> 'total_bytes' from r1)),
  'ARCHIVE_STALE', 'EXP-005 stale archive cannot be acknowledged');

-- ============================================================ r2, verify + acknowledge
select test.as_admin_db();
select pg_temp.reauth('ADMIN01', 'export.annual', pg_temp.period(pg_temp.y() - 1));
select test.login('ADMIN01');
create temporary table r2 as select public.create_archive_export(pg_temp.period(pg_temp.y() - 1)) -> 'data' as j;
grant select on r2 to authenticated, service_role;
select test.eq((select (j ->> 'revision')::integer from r2), 2, 'EXP-005 re-export creates revision 2');
select test.as_admin_db();
select test.eq((select state from hrms.export_jobs where id = (select (j ->> 'id')::uuid from r1)), 'superseded',
  'older unacknowledged export superseded');
select test.login('ADMIN01');
select test.throws(format('select public.acknowledge_export(%L, %L, %s, %s, false, null, true)',
                          (select j ->> 'id' from r2), repeat('0', 64), (select j ->> 'file_count' from r2),
                          (select j ->> 'total_bytes' from r2)),
  'ARCHIVE_INCOMPLETE', 'EXP-010 wrong manifest hash never acknowledged');
select test.throws(format('select public.acknowledge_export(%L, %L, %s, %s, false, null, true)',
                          (select j ->> 'id' from r2), (select j ->> 'manifest_hash' from r2),
                          (select (j ->> 'file_count')::integer - 1 from r2), (select j ->> 'total_bytes' from r2)),
  'ARCHIVE_INCOMPLETE', 'EXP-010 missing file count never acknowledged');
select test.throws(format('select public.acknowledge_export(%L, %L, %s, %s, false, null, false)',
                          (select j ->> 'id' from r2), (select j ->> 'manifest_hash' from r2),
                          (select j ->> 'file_count' from r2), (select j ->> 'total_bytes' from r2)),
  'VALIDATION_FAILED', 'EXP-011 no local-save confirmation, no acknowledgment');
select test.throws(format('select public.acknowledge_export(%L, %L, %s, %s, true, array[%L]::uuid[], true)',
                          (select j ->> 'id' from r2), (select j ->> 'manifest_hash' from r2),
                          (select j ->> 'file_count' from r2), (select j ->> 'total_bytes' from r2), gen_random_uuid()),
  'VALIDATION_FAILED', 'EXP-017 partial only for archives needing earlier originals');
select test.eq((select public.acknowledge_export((j ->> 'id')::uuid, j ->> 'manifest_hash', (j ->> 'file_count')::integer,
                  (j ->> 'total_bytes')::bigint, false, null, true) -> 'data' ->> 'state' from r2), 'acknowledged',
  'verified archive acknowledged');

-- ============================================================ cleanup gates (DEL-001/004)
create temporary table pv as select public.preview_cleanup((select (j ->> 'id')::uuid from r2)) -> 'data' as p;
grant select on pv to authenticated, service_role;
select test.eq((select count(*)::integer from pv, jsonb_array_elements(p -> 'checks') c where not (c ->> 'ok')::boolean), 0,
  'DEL-001 all gates satisfied after verified acknowledgment');
select test.eq((select (p ->> 'item_count')::integer from pv), 4, 'DEL-002 preview lists exactly the inventoried cloud files');
select test.eq((select (p ->> 'visible_payslips')::integer from pv),
               pg_temp.dec_visible(), 'preview counts payslips still inside the 12-month window');
select test.throws(format('select public.begin_cleanup(%L, %L, %L, true)', (select j ->> 'id' from r2), repeat('a', 64),
                          (pg_temp.y() - 1)::text),
  'ARCHIVE_INCOMPLETE', 'DEL-004 tampered manifest hash rejected');
select test.throws(format('select public.begin_cleanup(%L, %L, %L, true)', (select j ->> 'id' from r2),
                          (select j ->> 'manifest_hash' from r2), 'wrong'),
  'VALIDATION_FAILED', 'typed period label must match');
select test.throws(format('select public.begin_cleanup(%L, %L, %L, true)', (select j ->> 'id' from r2),
                          (select j ->> 'manifest_hash' from r2), (pg_temp.y() - 1)::text),
  'REAUTH_REQUIRED', 'DEL-001 cleanup needs recent password confirmation');
select test.login('HR01');
select test.throws(format('select public.begin_cleanup(%L, %L, %L, true)', (select j ->> 'id' from r2),
                          (select j ->> 'manifest_hash' from r2), (pg_temp.y() - 1)::text),
  'ACCESS_DENIED', 'EXP-013 HR cannot clean up');

-- DEL-008: cancelling the confirmation is simply not calling begin: zero mutation.
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.file_versions where state = 'deletion_pending'), 0,
  'DEL-008 no mutation before confirmation');
create temporary table counts_before as select
  (select count(*) from hrms.employees) as employees, (select count(*) from hrms.attendance_sessions) as sessions,
  (select count(*) from hrms.leave_ledger) as ledger, (select count(*) from hrms.requests) as requests,
  (select count(*) from hrms.export_items) as items;
grant select on counts_before to authenticated, service_role;

-- ============================================================ run cleanup (DEL-002/003/005/011)
select pg_temp.reauth('ADMIN01', 'archive.cleanup', (select (j ->> 'id')::uuid from r2));
select test.login('ADMIN01');
create temporary table c1 as select public.begin_cleanup((j ->> 'id')::uuid, j ->> 'manifest_hash',
  (pg_temp.y() - 1)::text, true) -> 'data' as c from r2;
grant select on c1 to authenticated, service_role;
select test.eq((select c ->> 'state' from c1), 'running', 'cleanup running');
select test.eq((select (c ->> 'total_items')::integer from c1), 4, 'DEL-002 immutable inventory of 4 files');
select test.eq((select (public.begin_cleanup((j ->> 'id')::uuid, j ->> 'manifest_hash', (pg_temp.y() - 1)::text, true)
                  -> 'data' ->> 'id') from r2), (select c ->> 'id' from c1), 'DEL-008 replayed begin returns the same job');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.file_versions where state = 'deletion_pending'), 4,
  'inventory marked deletion pending');
select test.eq(pg_temp.vstate((select current_file_version_id from hrms.payslips where file_record_id = (select cur from fx))),
  'published', 'DEL-002 other-year files untouched');

-- DEL-003: the period is write-gated while cleanup runs (retryable).
select test.as_service();
select test.throws(format($q$select public.internal_begin_upload(p.auth_user_id, p.session_id, p.alias, 'payslip', %L,
                              %L, null, null, 'late.pdf', 1000, 'application/pdf') from test.people p where p.code = 'HR01'$q$,
                          test.emp('EMP02'), make_date(pg_temp.y() - 1, 11, 1)),
  'PERIOD_BUSY', 'DEL-003 late upload for the period is period-busy during cleanup');
select test.ok((select (public.internal_begin_upload(p.auth_user_id, p.session_id, p.alias, 'payslip', test.emp('EMP02'),
                  make_date(pg_temp.y(), 1, 1), null, null, 'jan.pdf', 1000, 'application/pdf') ->> 'file_version_id') is not null
                from test.people p where p.code = 'HR01'), 'uploads for other periods continue');
select test.login('ADMIN01');
select test.throws(format('select public.create_archive_export(%L)', pg_temp.period(pg_temp.y() - 1)),
  'PERIOD_BUSY', 'no new export while cleanup runs');

-- Leased batches: one worker at a time.
select test.as_service();
create temporary table w as select gen_random_uuid() as w1, gen_random_uuid() as w2, gen_random_uuid() as w3;
grant select on w to service_role;
create temporary table b1 as select pg_temp.claim('ADMIN01', (select (c ->> 'id')::uuid from c1), (select w1 from w), 2) as r;
grant select on b1 to authenticated, service_role;
select test.eq((select jsonb_array_length(r -> 'items') from b1), 2, 'worker 1 claims a bounded batch');
select test.eq((select (pg_temp.claim('ADMIN01', (select (c ->> 'id')::uuid from c1), (select w2 from w), 2) ->> 'busy')::boolean),
  true, 'DEL-011 exclusive lease: second worker is told to wait');
select test.throws(format('select pg_temp.claim(%L, %L, %L, 2)', 'ADMIN02', (select c ->> 'id' from c1), (select w2 from w)),
  'ACCESS_DENIED', 'another Admin cannot run batches without taking over');

-- Worker 1 "crashes" after deleting (no completion). Admin 2 takes over.
select test.login('ADMIN02');
select test.throws(format('select public.resume_cleanup(%L)', (select c ->> 'id' from c1)),
  'REAUTH_REQUIRED', 'takeover needs recent password confirmation');
select test.as_admin_db();
select pg_temp.reauth('ADMIN02', 'archive.cleanup', (select (c ->> 'id')::uuid from c1));
select test.login('ADMIN02');
select test.eq((select public.resume_cleanup((c ->> 'id')::uuid) -> 'data' -> 'driver' ->> 'id' from c1),
  test.emp('ADMIN02')::text, 'DEL-011 second Admin now drives the same inventory');
select test.as_service();
select test.throws(format('select pg_temp.claim(%L, %L, %L, 2)', 'ADMIN01', (select c ->> 'id' from c1), (select w1 from w)),
  'ACCESS_DENIED', 'DEL-011 stale driver cannot dispatch new deletes');
select test.eq((select (pg_temp.claim('ADMIN02', (select (c ->> 'id')::uuid from c1), (select w2 from w), 10) ->> 'busy')::boolean),
  true, 'takeover waits for the old lease to expire');
select test.as_admin_db();
update hrms.cleanup_jobs set lease_until = now() - interval '1 second' where id = (select (c ->> 'id')::uuid from c1);
select test.as_service();
create temporary table b2 as select pg_temp.claim('ADMIN02', (select (c ->> 'id')::uuid from c1), (select w2 from w), 1) as r;
grant select on b2 to authenticated, service_role;
select test.eq((select jsonb_array_length(r -> 'items') from b2), 3, 'in-flight items reassigned first, plus one new');
-- The stale worker's late report is ignored for items now owned by worker 2.
select pg_temp.complete('ADMIN01', (select (c ->> 'id')::uuid from c1), (select w1 from w), pg_temp.ok_results((select r from b1)));
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.cleanup_items where cleanup_job_id = (select (c ->> 'id')::uuid from c1)
                and state = 'deleting'), 3, 'stale worker cannot complete reassigned items');
select test.as_service();
-- DEL-005: one object fails; it retries without touching unrelated objects.
create temporary table b2r as select jsonb_build_array(
  jsonb_build_object('item_id', (r -> 'items' -> 0 ->> 'item_id')::bigint, 'ok', true),
  jsonb_build_object('item_id', (r -> 'items' -> 1 ->> 'item_id')::bigint, 'ok', true),
  jsonb_build_object('item_id', (r -> 'items' -> 2 ->> 'item_id')::bigint, 'ok', false, 'error', 'storage 503')) as res from b2;
grant select on b2r to authenticated, service_role;
select test.eq((select (pg_temp.complete('ADMIN02', (select (c ->> 'id')::uuid from c1), (select w2 from w),
                  (select res from b2r)) ->> 'done')::boolean), false, 'DEL-005 partial failure keeps the job running');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.file_versions where state = 'deleted'), 2, 'two objects tombstoned');
select test.ok((select bool_and(tombstone ? 'sha256' and tombstone ? 'archive_path') from hrms.file_versions
                where state = 'deleted'), 'tombstones keep hash and archive path');
select test.as_service();
create temporary table b3 as select pg_temp.claim('ADMIN02', (select (c ->> 'id')::uuid from c1), (select w3 from w), 10) as r;
grant select on b3 to authenticated, service_role;
select test.eq((select jsonb_array_length(r -> 'items') from b3), 2, 'retry batch: the failed item and the last pending one');
select test.eq((select (pg_temp.complete('ADMIN02', (select (c ->> 'id')::uuid from c1), (select w3 from w),
                  pg_temp.ok_results((select r from b3))) ->> 'done')::boolean), true, 'cleanup completes');
select test.as_admin_db();
select test.eq((select state from hrms.cleanup_jobs where id = (select (c ->> 'id')::uuid from c1)), 'completed',
  'job completed');
select test.eq((select cleanup_job_id is null from hrms.archive_periods where id = pg_temp.period(pg_temp.y() - 1)), true,
  'period write gate cleared');
select test.eq((select count(*)::integer from hrms.file_versions v join hrms.file_records r on r.id = v.file_record_id
                where v.state = 'deleted' and r.owner_employee_id = test.emp('EMP01')), 4,
  'DEL-002 exactly the four inventoried versions deleted');
select test.ok((select employees = (select count(*) from hrms.employees) and sessions = (select count(*) from hrms.attendance_sessions)
                  and ledger = (select count(*) from hrms.leave_ledger) and requests = (select count(*) from hrms.requests)
                  and items = (select count(*) from hrms.export_items) from counts_before),
  'DEL-009 employees, attendance, leave, requests and manifests unchanged');
select test.ok((select count(*) > 0 from hrms.audit_logs where action = 'file.deleted_by_cleanup'), 'deletions audited');

-- FILE-010: members see archived metadata, never a dead download.
select test.login('EMP01');
select test.eq((select count(*)::integer from jsonb_array_elements(public.list_my_payslips() -> 'data' -> 'slots') s
                where s ->> 'salary_month' = make_date(pg_temp.y() - 1, 12, 1)::text and s ->> 'status' = 'archived'
                  and s ->> 'file_version_id' is null),
               pg_temp.dec_visible(), 'FILE-010 cleaned month shows archived, no download id');
select test.as_service();
select test.eq((select public.internal_authorize_file_access(p.auth_user_id, p.session_id, p.alias,
                  pg_temp.current_slip_version((select dec from fx)), 'view') ->> 'available'
                from test.people p where p.code = 'HR01'), 'false', 'FILE-010 no signed link for deleted bytes');

-- ============================================================ re-export after cleanup (EXP-016/017)
select test.as_admin_db();
select pg_temp.reauth('ADMIN01', 'export.annual', pg_temp.period(pg_temp.y() - 1));
select test.login('ADMIN01');
create temporary table r3 as select public.create_archive_export(pg_temp.period(pg_temp.y() - 1)) -> 'data' as j;
grant select on r3 to authenticated, service_role;
select test.eq((select (j ->> 'requires_local_base')::boolean from r3), true, 'EXP-016 re-export needs the previous local archive');
select test.eq((select (j ->> 'local_base_count')::integer from r3), 4, 'all cleaned versions listed as local originals');
select test.eq((select j ->> 'base_export_id' from r3), (select j ->> 'id' from r2), 'base is the acknowledged archive r2');
select test.eq((select j -> 'base' ->> 'manifest_hash' from r3), (select j ->> 'manifest_hash' from r2),
  'base manifest identity exposed for validation');
select test.as_service();
select test.throws(format($q$select public.internal_authorize_export_file(p.auth_user_id, p.session_id, p.alias, %L, %L)
                            from test.people p where p.code = 'ADMIN01'$q$,
                          (select j ->> 'id' from r3), pg_temp.current_slip_version((select dec from fx))),
  'ACCESS_DENIED', 'EXP-016 local originals are never fetched from the cloud');
select test.login('ADMIN01');
-- Previous archive unavailable: a clearly partial acknowledgment that can never unlock cleanup.
create temporary table r3a as select public.acknowledge_export((j ->> 'id')::uuid, j ->> 'manifest_hash',
  (j ->> 'file_count')::integer - 4, (j ->> 'total_bytes')::bigint - pg_temp.local_bytes((j ->> 'id')::uuid),
  true, pg_temp.local_ids((j ->> 'id')::uuid),
  true) -> 'data' as j from r3;
grant select on r3a to authenticated, service_role;
select test.eq((select j ->> 'state' from r3a), 'partial', 'EXP-017 partial archive recorded as partial');
select test.eq((select c ->> 'ok' from jsonb_array_elements(public.preview_cleanup((select (j ->> 'id')::uuid from r3))
                  -> 'data' -> 'checks') c where c ->> 'key' = 'acknowledged'), 'false',
  'EXP-017 partial archive never cleanup eligible');
select test.as_admin_db();
select test.eq((select count(*)::integer from jsonb_array_elements(pg_temp.tasks()) t
                where t ->> 'kind' = 'archive_due' and t ->> 'period_id' = pg_temp.period(pg_temp.y() - 1)::text), 0,
  'EXP-014 due task clears once an archive is acknowledged');

-- ============================================================ assisted restore (DEL-010)
select pg_temp.version((select dec from fx), 2, 'validated');
select pg_temp.version((select dec from fx), 3, 'quarantined');
update hrms.file_versions set uploaded_by = test.emp('ADMIN01') where file_record_id = (select dec from fx) and version_no in (2, 3);
create temporary table rs as select
  (select id from hrms.file_versions where file_record_id = (select dec from fx) and version_no = 1) as old_v,
  (select id from hrms.file_versions where file_record_id = (select dec from fx) and version_no = 2) as bad_v,
  (select id from hrms.file_versions where file_record_id = (select dec from fx) and version_no = 3) as new_v;
grant select on rs to authenticated, service_role;
-- A real upload is hashed while quarantined, then validated.
update hrms.file_versions n set sha256 = o.sha256, size_bytes = o.size_bytes
from hrms.file_versions o where n.id = (select new_v from rs) and o.id = (select old_v from rs);
update hrms.file_versions set state = 'validated' where id = (select new_v from rs);
select test.login('ADMIN01');
select test.throws(format('select public.restore_archived_file(%L, %L, %L)', (select old_v from rs), (select bad_v from rs),
                          'From local archive'),
  'VALIDATION_FAILED', 'DEL-010 mismatched bytes are never restored');
select test.login('ADMIN01');
select test.eq((select public.restore_archived_file((select old_v from rs), (select new_v from rs), 'From local archive')
                  -> 'data' ->> 'restored_version_id'), (select new_v::text from rs), 'DEL-010 verified original restored');
select test.as_admin_db();
select test.eq(pg_temp.vstate((select new_v from rs)), 'published', 'restored version published as current');
select test.eq(pg_temp.vstate((select old_v from rs)), 'deleted', 'original stays tombstoned (no silent overwrite)');
select test.eq(pg_temp.current_slip_version((select dec from fx)), (select new_v from rs), 'payslip points to the restored copy');
select test.throws(format('update hrms.file_versions set state = %L where id = %L', 'published', (select old_v from rs)),
  '42501', 'deleted versions are terminal');

-- ============================================================ abandon (DEL-012) on Y-2
select pg_temp.reauth('ADMIN01', 'export.annual', pg_temp.period(pg_temp.y() - 2));
select test.login('ADMIN01');
create temporary table o1 as select public.create_archive_export(pg_temp.period(pg_temp.y() - 2)) -> 'data' as j;
grant select on o1 to authenticated, service_role;
select test.eq((select (j ->> 'file_count')::integer from o1), 3, 'Y-2 archive inventories three payslips');
select public.acknowledge_export((j ->> 'id')::uuid, j ->> 'manifest_hash', (j ->> 'file_count')::integer,
                                 (j ->> 'total_bytes')::bigint, false, null, true) from o1;
select test.as_admin_db();
select pg_temp.reauth('ADMIN01', 'archive.cleanup', (select (j ->> 'id')::uuid from o1));
select test.login('ADMIN01');
create temporary table oc as select public.begin_cleanup((j ->> 'id')::uuid, j ->> 'manifest_hash',
  (pg_temp.y() - 2)::text, true) -> 'data' as c from o1;
grant select on oc to authenticated, service_role;
select test.as_service();
create temporary table ob as select pg_temp.claim('ADMIN01', (select (c ->> 'id')::uuid from oc), (select w1 from w), 1) as r;
grant select on ob to authenticated, service_role;
select test.login('ADMIN01');
select test.throws(format('select public.abandon_cleanup(%L, %L)', (select c ->> 'id' from oc), 'Stopping'),
  'PERIOD_BUSY', 'abandon waits while a batch holds the lease');
select test.as_service();
select pg_temp.complete('ADMIN01', (select (c ->> 'id')::uuid from oc), (select w1 from w), pg_temp.ok_results((select r from ob)));
select test.login('ADMIN01');
select test.eq((select public.abandon_cleanup((c ->> 'id')::uuid, 'Stopping for review') -> 'data' ->> 'state' from oc),
  'abandoned_with_partial_deletions', 'DEL-012 abandon records partial deletion');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.file_versions v join hrms.file_records r on r.id = v.file_record_id
                where r.owner_employee_id = test.emp('EMPOLD') and v.state = 'published'), 2,
  'DEL-012 remaining files restored to their previous state');
select test.eq((select count(*)::integer from hrms.file_versions v join hrms.file_records r on r.id = v.file_record_id
                where r.owner_employee_id = test.emp('EMPOLD') and v.state = 'deleted'), 1, 'deleted file stays tombstoned');
select test.eq((select cleanup_job_id is null from hrms.archive_periods where id = pg_temp.period(pg_temp.y() - 2)), true,
  'DEL-012 period gate released');
select test.login('ADMIN01');
select test.eq((select c ->> 'ok' from jsonb_array_elements(public.preview_cleanup((select (j ->> 'id')::uuid from o1))
                  -> 'data' -> 'checks') c where c ->> 'key' = 'unused'), 'false',
  'DEL-012 the consumed archive cannot start a new cleanup');
select test.as_service();
select test.eq((select (pg_temp.claim('ADMIN01', (select (c ->> 'id')::uuid from oc), gen_random_uuid(), 5) ->> 'done')::boolean),
  true, 'DEL-012 old job cannot resume after abandon');

-- ============================================================ annual cycle change (EXP-019)
select test.login('ADMIN01');
select test.eq((select p -> 0 ->> 'kind' from (select public.preview_annual_cycle(4) -> 'data' -> 'next_periods' as p) x),
  'transition', 'EXP-019 switching to April starts with a transition period');
select test.eq((select p -> 0 ->> 'period_end' from (select public.preview_annual_cycle(4) -> 'data' -> 'next_periods' as p) x),
  make_date(pg_temp.y() + 1, 3, 31)::text, 'transition runs Jan–Mar');
select test.eq((select p -> 1 ->> 'label' from (select public.preview_annual_cycle(4) -> 'data' -> 'next_periods' as p) x),
  (pg_temp.y() + 1)::text || '-' || right((pg_temp.y() + 2)::text, 2), 'then an Apr–Mar year');
select public.update_org_settings('{"annual_start_month": 4}'::jsonb,
  pg_temp.org_version());
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.archive_periods where org_id = test.org('TEST_ORG')
                and period_start = make_date(pg_temp.y() - 1, 1, 1) and period_end = make_date(pg_temp.y() - 1, 12, 31)), 1,
  'EXP-019 existing period bounds are immutable after a cycle change');
select test.throws(format('update hrms.archive_periods set period_end = period_end + 1 where id = %L',
                          pg_temp.period(pg_temp.y() - 1)), '42501', 'period bounds cannot be edited');

-- ============================================================ HR view of employee files (S26)
select test.login('MGR01');
select test.throws(format('select public.list_employee_files(%L)', test.emp('EMP01')), 'ACCESS_DENIED',
  'ROLE-002 manager cannot list employee files');
select test.login('HR02');
select test.eq((select public.list_employee_files(test.emp('EMP01')) -> 'data' -> 'payslips'), 'null'::jsonb,
  'FILE-002 HR without payroll grant sees no payslips');
select test.login('HR01');
select test.ok((select jsonb_array_length(public.list_employee_files(test.emp('EMP01')) -> 'data' -> 'payslips') >= 3),
  'payroll HR sees payslip history');

rollback;
