-- SEC-002 / API-001 / PUNCH-008 / AUDIT-002: the API permission boundary.
begin;
select test.standard_org();

-- anon cannot execute business RPCs.
select test.as_anon();
select test.throws($$select public.get_leave_balances()$$, '42501', 'anon cannot call get_leave_balances');
select test.throws($$select public.list_review_queue()$$, '42501', 'anon cannot call list_review_queue');
select test.throws($$select * from hrms.employees$$, '42501', 'anon cannot read hrms schema');

-- authenticated cannot touch tables directly, even its own rows.
select test.login('EMP01');
select test.throws($$select * from hrms.employees$$, '42501', 'member cannot select employees table');
select test.throws($$select * from hrms.attendance_events$$, '42501', 'member cannot select attendance events');
select test.throws($$insert into hrms.attendance_events (org_id) values (gen_random_uuid())$$, '42501',
  'member cannot insert attendance events');
select test.throws($$select * from hrms.request_revisions$$, '42501', 'member cannot read raw revisions');
select test.throws($$select * from hrms.audit_logs$$, '42501', 'member cannot read audit table');
select test.throws($$select hrms.resolve_actor(gen_random_uuid(), gen_random_uuid(), 'x', 'business')$$, '42501',
  'member cannot execute hrms internals');

-- internal_* RPCs are service_role only.
select test.throws($$select public.internal_punch_lookup(gen_random_uuid(), gen_random_uuid(), 'x', gen_random_uuid(), 'h')$$,
  '42501', 'member cannot call internal_punch_lookup');
select test.throws($$select public.internal_commit_punch(null,null,null,null,null,null,null,null,null,null,null,null,null,null,now(),null)$$,
  '42501', 'member cannot call internal_commit_punch (no client receipt time)');

-- Admin role gives no direct table write either.
select test.login('ADMIN01');
select test.throws($$update hrms.attendance_sessions set state = 'closed'$$, '42501', 'admin cannot update sessions directly');
select test.throws($$delete from hrms.audit_logs$$, '42501', 'admin cannot delete audit rows');

-- Even the table owner cannot rewrite append-only evidence.
select test.as_admin_db();
insert into hrms.audit_logs (org_id, action) values (test.org('TEST_ORG'), 'test.row');
select test.throws($$update hrms.audit_logs set action = 'x'$$, '42501', 'audit rows are append-only for owner');
select test.throws($$delete from hrms.audit_logs$$, '42501', 'audit rows cannot be deleted by owner');

-- Every hrms table has RLS enabled.
select test.eq((select count(*)::integer from pg_tables where schemaname = 'hrms' and not rowsecurity), 0,
  'RLS enabled on every hrms table');

-- Every public SECURITY DEFINER function pins search_path.
select test.eq((select count(*)::integer from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname in ('public', 'hrms') and p.prosecdef
                  and not coalesce(array_to_string(p.proconfig, ',') like '%search_path=""%', false)), 0,
  'definer functions use an empty search_path');

-- No public function is executable by anon.
select test.eq((select count(*)::integer from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
                  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')), 0,
  'anon executes no public function');

-- SUPPORT-001..004: Admin-configured public login support is narrow and rate limited.
select test.login('EMP01');
select test.throws($$select public.update_org_settings('{"support_phone":"+91 98765 43210"}'::jsonb, 1)$$,
  'ACCESS_DENIED', 'SUPPORT-001 only Admin can change the HR support phone');
select test.throws($$select public.internal_login_support('TEST_ORG', 'member-ip')$$,
  '42501', 'SUPPORT-002 authenticated clients cannot call internal login support');

select test.login('ADMIN01');
create temporary table support_saved as
select public.update_org_settings('{"support_phone":"+91 98765 43210"}'::jsonb,
  (public.get_org_settings() ->> 'version')::integer) as res;
select test.eq((select res -> 'data' ->> 'support_phone' from support_saved), '+91 98765 43210',
  'SUPPORT-001 Admin saves the normalized display phone');
select test.throws($$select public.update_org_settings('{"support_phone":"javascript:alert(1)"}'::jsonb,
  (public.get_org_settings() ->> 'version')::integer)$$, 'VALIDATION_FAILED',
  'SUPPORT-001 arbitrary text and URI injection are rejected');

select test.as_admin_db();
create temporary table support_public as
select public.internal_login_support('test_org', 'support-ip') as res;
select test.eq((select res ->> 'display_phone' from support_public), '+91 98765 43210',
  'SUPPORT-002 lookup is case-insensitive and returns display phone');
select test.eq((select res ->> 'tel_uri' from support_public), 'tel:+919876543210',
  'SUPPORT-002 lookup returns a normalized telephone URI');
select test.eq((select array_agg(k order by k) from support_public, lateral jsonb_object_keys(res) k),
  array['allowed','display_phone','tel_uri']::text[], 'SUPPORT-002 internal projection contains no organisation or employee identity');
select test.eq((public.internal_login_support('UNKNOWN', 'unknown-ip') ->> 'display_phone')::text, null::text,
  'SUPPORT-003 an unknown organisation exposes no phone');

update hrms.organizations set support_phone = null where code = 'TEST_ORG';
select test.eq((public.internal_login_support('TEST_ORG', 'missing-ip') ->> 'display_phone')::text, null::text,
  'SUPPORT-003 missing configuration returns no phone');

select public.internal_login_support('UNKNOWN', 'limited-ip') from generate_series(1, 30);
select test.eq((public.internal_login_support('UNKNOWN', 'limited-ip') ->> 'allowed')::boolean, false,
  'SUPPORT-004 repeated signed-out lookup is rate limited');
rollback;
