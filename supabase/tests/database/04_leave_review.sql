-- LEAVE-001..014, REVIEW-001..013, CORR-001..007 against the real state
-- machine, called as the actual API role with Supabase-style JWT claims.
begin;
select test.standard_org();

-- Dates relative to today so the suite runs on any day: the Monday of the
-- week after next, always in the future and a working day.
create or replace function pg_temp.mon() returns date language sql as $$
  select current_date + ((7 - extract(isodow from current_date)::integer) + 1) + 7;
$$;
create or replace function pg_temp.d(p_offset integer) returns date language sql as $$ select pg_temp.mon() + p_offset $$;
create or replace function pg_temp.yr() returns integer language sql as $$ select extract(year from pg_temp.mon())::integer $$;

insert into hrms.leave_types (org_id, code, name, paid, half_day_allowed, backdate_days)
values (test.org('TEST_ORG'), 'CL', 'Casual Leave', true, true, 7),
       (test.org('TEST_ORG'), 'LOP', 'Unpaid Leave', false, true, 7);
create or replace function pg_temp.cl() returns uuid language sql security definer as $$ select id from hrms.leave_types where code = 'CL' $$;
create or replace function pg_temp.lop() returns uuid language sql security definer as $$ select id from hrms.leave_types where code = 'LOP' $$;

select test.grant_leave(c, pg_temp.cl(), pg_temp.yr()) from unnest(array['EMP01', 'EMP02', 'EMP03', 'HR01', 'ADMIN01']) c;
-- Cover requests that fall into the following calendar year as well.
select test.grant_leave(c, pg_temp.cl(), pg_temp.yr() + 1) from unnest(array['EMP01']) c;

create or replace function pg_temp.avail(p_code text, p_year integer default null) returns integer language sql security definer as $$
  select coalesce(sum(av.available), 0)::integer
  from hrms.leave_accounts a cross join lateral hrms.allocation_availability(array[a.id]) av
  where a.employee_id = test.emp(p_code) and a.leave_type_id = pg_temp.cl()
    and a.leave_year = coalesce(p_year, pg_temp.yr());
$$;

create or replace function pg_temp.apply(p_start date, p_end date, p_start_slot text default 'FULL',
  p_end_slot text default 'FULL', p_type uuid default null) returns jsonb language sql as $$
  select public.save_leave_request(null, coalesce(p_type, pg_temp.cl()), p_start, p_end, p_start_slot, p_end_slot,
                                   'Family function', null, true, null, gen_random_uuid());
$$;

-- ============================================================ LEAVE-001 happy path
select test.login('EMP01');
create temporary table r1 as select pg_temp.apply(pg_temp.d(0), pg_temp.d(1)) as res;
select test.eq((select res -> 'data' ->> 'state' from r1), 'submitted', 'LEAVE-001 request submitted');
select test.eq((select (res -> 'data' ->> 'units')::integer from r1), 4, 'LEAVE-001 two full days = 4 units');
select test.eq((select (res -> 'data' ->> 'reserved_units')::integer from r1), 4, 'LEAVE-001 4 units reserved');
select test.eq(pg_temp.avail('EMP01'), 20, 'LEAVE-001 available 24 - 4 reserved = 20');
select test.eq((select res -> 'data' -> 'reviewer' ->> 'code' from r1), 'MGR01', 'routed to Team1 manager');

-- REVIEW-001: reviewer listing never locks.
select test.login('MGR01');
select test.eq((select jsonb_array_length(public.list_review_queue() -> 'data')), 1, 'REVIEW-001 queue shows request');
select test.ok((select not ((public.list_review_queue() -> 'data' -> 0) ? 'revisions')),
  'REVIEW-011 queue projection has no revisions/reason');
select test.as_admin_db();
select test.eq((select state from hrms.requests where id = (select (res -> 'data' ->> 'id')::uuid from r1)), 'submitted',
  'REVIEW-001 listing did not lock');

-- Owner edits before first open: version increments, Edited badge, swap.
select test.login('EMP01');
create temporary table r1e as select public.save_leave_request((res -> 'data' ->> 'id')::uuid, pg_temp.cl(),
  pg_temp.d(0), pg_temp.d(2), 'FULL', 'FULL', 'Extended trip', null, true, (res ->> 'version')::integer,
  gen_random_uuid()) as res from r1;
select test.eq((select (res -> 'data' ->> 'edited')::boolean from r1e), true, 'REVIEW-001 Edited badge set');
select test.eq((select (res -> 'data' ->> 'current_revision')::integer from r1e), 2, 'REVIEW-001 revision 2 saved');
select test.eq(pg_temp.avail('EMP01'), 18, 'edit swapped reservation 4 -> 6 units');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.leave_day_slots
                where request_id = (select (res -> 'data' ->> 'id')::uuid from r1) and state = 'reserved'), 3,
  'no duplicate day locks after edit');

-- REVIEW-004: unauthorised read reveals nothing and does not lock.
select test.login('EMP02');
select test.throws(format('select public.open_request_for_review(%L)', (select res -> 'data' ->> 'id' from r1)),
  'ACCESS_DENIED', 'REVIEW-004 unassigned employee cannot open');
select test.login('MGR02');
select test.throws(format('select public.open_request_for_review(%L)', (select res -> 'data' ->> 'id' from r1)),
  'ACCESS_DENIED', 'REVIEW-004 other team manager cannot open');
-- Owner view does not lock.
select test.login('EMP01');
select public.get_my_request((res -> 'data' ->> 'id')::uuid) from r1;
select test.as_admin_db();
select test.eq((select state from hrms.requests where id = (select (res -> 'data' ->> 'id')::uuid from r1)), 'submitted',
  'REVIEW-004 unauthorised/owner reads did not lock');

-- REVIEW-002: reviewer opens -> locks the latest revision; owner edit fails.
select test.login('MGR01');
create temporary table o1 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from r1;
select test.eq((select res -> 'data' ->> 'state' from o1), 'under_review', 'REVIEW-002 open locks request');
select test.eq((select (res -> 'data' ->> 'locked_revision')::integer from o1), 2, 'REVIEW-002 latest revision locked');
select test.ok((select (res -> 'data') ? 'revisions' from o1), 'REVIEW-011 detail only via locking path');
select test.login('EMP01');
select test.throws(format('select public.save_leave_request(%L, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, %s, gen_random_uuid())',
  (select res -> 'data' ->> 'id' from r1), pg_temp.cl(), pg_temp.d(0), pg_temp.d(0), (select res ->> 'version' from o1)),
  'REQUEST_LOCKED', 'REVIEW-002 owner edit after open gets REQUEST_LOCKED');

-- REVIEW-006: one winner for concurrent decisions on the same version.
select test.login('MGR01');
select test.throws(format('select public.decide_request(%L, ''reject'', null, %s)',
  (select res -> 'data' ->> 'id' from o1), (select res ->> 'version' from o1)), 'VALIDATION_FAILED',
  'REVIEW-010 rejection requires a reason');
create temporary table d1 as select public.decide_request((res -> 'data' ->> 'id')::uuid, 'approve', null,
  (res ->> 'version')::integer) as res from o1;
select test.eq((select res -> 'data' ->> 'state' from d1), 'approved', 'LEAVE-001 approved');
select test.login('ADMIN01');
select test.throws(format('select public.decide_request(%L, ''reject'', ''late'', %s)',
  (select res -> 'data' ->> 'id' from o1), (select res ->> 'version' from o1)), 'STALE_VERSION',
  'REVIEW-006 losing concurrent decision gets STALE_VERSION');
select test.as_admin_db();
select test.eq(pg_temp.avail('EMP01'), 18, 'LEAVE-001 approval converts reservation to debit without double deduction');
select test.eq((select -sum(units)::integer from hrms.leave_ledger
                where request_id = (select (res -> 'data' ->> 'id')::uuid from r1) and entry_kind = 'debit'), 6,
  'LEAVE-001 debited exactly once');
select test.eq(hrms.approved_leave_slots(test.emp('EMP01'), pg_temp.d(1)), 3, 'TIME-018 approved full leave occupies the day');
select test.eq((select count(*)::integer from hrms.notifications where recipient_id = test.emp('EMP01')
                and kind = 'request.approved'), 1, 'one approval notification');

-- LEAVE-009: cancellation pending keeps the debit; approval credits once.
select test.login('EMP01');
create temporary table c1 as select public.request_leave_cancellation((res -> 'data' ->> 'id')::uuid,
  (res ->> 'version')::integer, 'Plans changed') as res from d1;
select test.eq(pg_temp.avail('EMP01'), 18, 'LEAVE-009 pending cancellation still occupies leave');
select test.login('MGR01');
create temporary table c2 as select public.resolve_cancellation((res -> 'data' ->> 'id')::uuid, false, 'Busy week',
  (res ->> 'version')::integer) as res from c1;
select test.eq((select res -> 'data' ->> 'state' from c2), 'approved', 'LEAVE-009 declined cancellation restores Approved');
select test.eq(pg_temp.avail('EMP01'), 18, 'LEAVE-009 decline changes no balance');
select test.login('EMP01');
create temporary table c3 as select public.request_leave_cancellation((res -> 'data' ->> 'id')::uuid,
  (res ->> 'version')::integer, 'Plans changed again') as res from c2;
select test.login('MGR01');
create temporary table c4 as select public.resolve_cancellation((res -> 'data' ->> 'id')::uuid, true, null,
  (res ->> 'version')::integer) as res from c3;
select test.eq((select res -> 'data' ->> 'state' from c4), 'cancelled', 'LEAVE-009 accepted cancellation');
select test.as_admin_db();
select test.eq(pg_temp.avail('EMP01'), 24, 'LEAVE-009 credited back exactly once');
select test.eq((select count(*)::integer from hrms.leave_ledger
                where request_id = (select (res -> 'data' ->> 'id')::uuid from r1) and entry_kind = 'credit_back'), 1,
  'LEAVE-013 one credit to the original allocation');
select test.eq(hrms.approved_leave_slots(test.emp('EMP01'), pg_temp.d(1)), 0, 'cancelled leave frees the day');
-- Repeating the credit is a no-op (idempotent ledger key).
select hrms.credit_back_request((res -> 'data' ->> 'id')::uuid, 2, test.emp('MGR01')) from r1;
select test.eq(pg_temp.avail('EMP01'), 24, 'LEAVE-008 repeated credit has no effect');

-- ============================================================ balance, overlap, slots
select test.login('EMP01');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), pg_temp.d(7), pg_temp.d(7 + 18)), 'INSUFFICIENT_BALANCE', 'LEAVE-003 paid request beyond balance rejected');
select test.eq(pg_temp.avail('EMP01'), 24, 'LEAVE-003 failed request reserved nothing');
select test.eq((select (pg_temp.apply(pg_temp.d(7), pg_temp.d(7 + 18), 'FULL', 'FULL', pg_temp.lop()) -> 'data' ->> 'state')), 'submitted',
  'LEAVE-003 explicitly chosen unpaid leave accepted');
select test.eq(pg_temp.avail('EMP01'), 24, 'unpaid leave consumes no paid balance');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), pg_temp.d(8), pg_temp.d(8)), 'OVERLAPPING_LEAVE', 'LEAVE-005 overlapping day rejected');
-- Complementary half days on the same day are allowed.
select test.eq((select pg_temp.apply(pg_temp.d(3), pg_temp.d(3), 'AM') -> 'data' ->> 'state'), 'submitted', 'LEAVE-005 AM half accepted');
select test.eq((select pg_temp.apply(pg_temp.d(3), pg_temp.d(3), 'PM') -> 'data' ->> 'state'), 'submitted', 'LEAVE-005 PM half accepted');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''AM'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), pg_temp.d(3), pg_temp.d(3)), 'OVERLAPPING_LEAVE', 'LEAVE-005 third overlapping half rejected');
select test.eq(pg_temp.avail('EMP01'), 22, 'two half days reserve 2 units');

-- LEAVE-014: weekend-only and pre-joining ranges.
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), pg_temp.d(5), pg_temp.d(6)), 'VALIDATION_FAILED', 'LEAVE-014 weekend-only request rejected (zero units)');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), current_date - 8, current_date - 8), 'VALIDATION_FAILED', 'LEAVE-007 backdating beyond 7 days rejected');

-- LEAVE-002: holidays inside a range are not deducted.
select test.as_admin_db();
insert into hrms.holidays (org_id, holiday_date, name, state) values (test.org('TEST_ORG'), pg_temp.d(32), 'Fixture Holiday', 'published');
select test.login('EMP02');
create temporary table h1 as select pg_temp.apply(pg_temp.d(30), pg_temp.d(34)) as res;   -- Wed..Sun with Fri holiday
select test.eq((select (res -> 'data' ->> 'units')::integer from h1), 4, 'LEAVE-002 Wed+Thu counted; holiday and weekend excluded');

-- ============================================================ return / resubmit (LEAVE-011)
select test.login('MGR01');
create temporary table o2 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from h1;
create temporary table ret as select public.decide_request((res -> 'data' ->> 'id')::uuid, 'return', 'Pick other dates',
  (res ->> 'version')::integer) as res from o2;
select test.eq((select res -> 'data' ->> 'state' from ret), 'returned', 'LEAVE-011 returned for changes');
select test.eq(pg_temp.avail('EMP02'), 24, 'LEAVE-011 return released the reservation once');
-- Employee spends the released balance elsewhere, then resubmits: revalidated.
select test.login('EMP02');
select pg_temp.apply(pg_temp.d(40), pg_temp.d(40 + 13));   -- 10 working days = 20 units
select test.eq(pg_temp.avail('EMP02'), 4, 'released balance used elsewhere');
create temporary table resub_fail as select 1;
select test.throws(format('select public.save_leave_request(%L, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, %s, gen_random_uuid())',
  (select res -> 'data' ->> 'id' from ret), pg_temp.cl(), pg_temp.d(56), pg_temp.d(60), (select res ->> 'version' from ret)),
  'INSUFFICIENT_BALANCE', 'LEAVE-011 resubmission revalidates balance');
select test.eq(pg_temp.avail('EMP02'), 4, 'LEAVE-011 no negative units after failed resubmission');
create temporary table resub as select public.save_leave_request((res -> 'data' ->> 'id')::uuid, pg_temp.cl(),
  pg_temp.d(56), pg_temp.d(56), 'FULL', 'FULL', 'One day only', null, true, (res ->> 'version')::integer,
  gen_random_uuid()) as res from ret;
select test.eq((select res -> 'data' ->> 'state' from resub), 'submitted', 'REVIEW-005 resubmitted as new revision');
select test.eq((select (res -> 'data' ->> 'current_revision')::integer from resub), 2, 'REVIEW-005 revision 2 awaits review');
select test.eq(pg_temp.avail('EMP02'), 2, 'REVIEW-005 resubmission re-reserved');

-- LEAVE-012: failed edit of an unviewed request leaves the old one intact.
select test.throws(format('select public.save_leave_request(%L, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, %s, gen_random_uuid())',
  (select res -> 'data' ->> 'id' from resub), pg_temp.cl(), pg_temp.d(56), pg_temp.d(62), (select res ->> 'version' from resub)),
  'INSUFFICIENT_BALANCE', 'LEAVE-012 edit beyond balance rejected');
select test.as_admin_db();
select test.eq((select current_revision from hrms.requests where id = (select (res -> 'data' ->> 'id')::uuid from resub)), 2,
  'LEAVE-012 failed edit kept revision');
select test.eq(pg_temp.avail('EMP02'), 2, 'LEAVE-012 failed edit kept reservation');

-- ============================================================ REVIEW-013 withdrawal
select test.login('MGR01');
create temporary table o3 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from resub;
select test.login('EMP02');
create temporary table w1 as select public.withdraw_request((res -> 'data' ->> 'id')::uuid, (res ->> 'version')::integer,
  'No longer needed') as res from o3;
select test.eq((select res -> 'data' ->> 'state' from w1), 'withdrawal_pending', 'REVIEW-013 withdrawal pending during review');
select test.login('MGR01');
select test.throws(format('select public.decide_request(%L, ''approve'', null, %s)', (select res -> 'data' ->> 'id' from w1),
  (select res ->> 'version' from w1)), 'STALE_VERSION', 'REVIEW-013 approve blocked while withdrawal pending');
create temporary table w2 as select public.resolve_withdrawal((res -> 'data' ->> 'id')::uuid, true, null,
  (res ->> 'version')::integer) as res from w1;
select test.eq((select res -> 'data' ->> 'state' from w2), 'cancelled', 'REVIEW-013 withdrawal accepted');
select test.eq(pg_temp.avail('EMP02'), 4, 'REVIEW-013 reservation released once on withdrawal');

-- ============================================================ REVIEW-007 self approval
select test.login('HR01');
create temporary table s1 as select pg_temp.apply(pg_temp.d(14), pg_temp.d(14)) as res;
select test.eq((select res -> 'data' -> 'reviewer' ->> 'code' from s1), 'ADMIN01',
  'REVIEW-007 HR''s own leave routes to the non-self fallback');
select test.throws(format('select public.open_request_for_review(%L)', (select res -> 'data' ->> 'id' from s1)),
  'ACCESS_DENIED', 'REVIEW-007 HR cannot open own request as reviewer');
select test.throws(format('select public.decide_request(%L, ''approve'', null, 1)', (select res -> 'data' ->> 'id' from s1)),
  'SELF_APPROVAL_FORBIDDEN', 'REVIEW-007 direct self-approval denied');
select test.login('ADMIN01');
create temporary table s2 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from s1;
select test.eq((select public.decide_request((res -> 'data' ->> 'id')::uuid, 'approve', null, (res ->> 'version')::integer)
                -> 'data' ->> 'state' from s2), 'approved', 'REVIEW-007 designated other reviewer approves');
-- ADMIN-SELF: Admin's own leave needs no approver and is approved at once.
select test.as_admin_db();
create temporary table a0 as select pg_temp.avail('ADMIN01') as v;
select test.login('ADMIN01');
create temporary table s3 as select pg_temp.apply(pg_temp.d(15), pg_temp.d(15)) as res;
select test.eq((select res -> 'data' ->> 'state' from s3), 'approved', 'ADMIN-SELF-001 Admin''s leave approved at once');
select test.eq((select (res -> 'data' ->> 'reviewer_assigned')::boolean from s3), false,
  'ADMIN-SELF-001 no approver assigned');
select test.eq((select jsonb_array_length(public.list_review_queue(null, 'unassigned') -> 'data')
                from (select 1) x), 0, 'ADMIN-SELF-002 nothing left waiting for an approver');
select test.as_admin_db();
select test.eq(pg_temp.avail('ADMIN01'), (select v from a0) - 2, 'ADMIN-SELF-001 debited once');
select test.eq((select count(*)::integer from hrms.notifications where kind = 'setup.reviewer_missing'
                and data ->> 'request_id' = (select res -> 'data' ->> 'id' from s3)), 0,
  'ADMIN-SELF-001 no missing-approver alert');
-- Admin revokes their own approved leave with a reason; it is credited back.
select test.login('ADMIN01');
select test.throws(format('select public.request_leave_cancellation(%L, %s, null)',
  (select res -> 'data' ->> 'id' from s3), (select res ->> 'version' from s3)), 'VALIDATION_FAILED',
  'ADMIN-SELF-003 revoking needs a reason');
create temporary table s4 as select public.request_leave_cancellation((res -> 'data' ->> 'id')::uuid,
  (res ->> 'version')::integer, 'Applied by mistake') as res from s3;
select test.eq((select res -> 'data' ->> 'state' from s4), 'cancelled', 'ADMIN-SELF-003 revoked immediately');
select test.eq((select res -> 'data' -> 'events' -> -1 ->> 'reason' from s4), 'Applied by mistake',
  'ADMIN-SELF-003 reason recorded');
select test.as_admin_db();
select test.eq(pg_temp.avail('ADMIN01'), (select v from a0), 'ADMIN-SELF-003 credited back');
select test.eq(hrms.approved_leave_slots(test.emp('ADMIN01'), pg_temp.d(15)), 0, 'ADMIN-SELF-003 day freed');

-- REVIEW-008: no eligible reviewer -> pending with setup alert, never auto-approved.
select test.as_admin_db();
update hrms.approval_routes set fallback_reviewer_id = null where team_id = (select id from hrms.teams where name = 'Team2');
update hrms.team_managers set effective_to = current_date where team_id = (select id from hrms.teams where name = 'Team2');
select test.login('EMP03');
create temporary table n1 as select pg_temp.apply(pg_temp.d(16), pg_temp.d(16)) as res;
select test.eq((select res -> 'data' ->> 'state' from n1), 'submitted', 'REVIEW-008 stays pending without approver');
select test.eq((select (res -> 'data' ->> 'reviewer_assigned')::boolean from n1), false, 'REVIEW-008 no reviewer assigned');
select test.as_admin_db();
select test.ok((select count(*) >= 1 from hrms.notifications where kind = 'setup.reviewer_missing'
                and recipient_id = test.emp('ADMIN01')), 'REVIEW-008 Admin gets setup alert');
select test.login('ADMIN01');
create temporary table n2 as select public.reassign_request((res -> 'data' ->> 'id')::uuid, test.emp('HR01'), 'Team2 manager left',
  (res ->> 'version')::integer) as res from n1;
select test.login('HR01');
select test.ok((select jsonb_array_length(public.list_review_queue() -> 'data') >= 1), 'REVIEW-008 reassigned reviewer sees it');

-- ============================================================ LEAVE-006 cross-year atomicity
select test.as_admin_db();
insert into hrms.shifts (org_id, name) values (test.org('TEST_ORG'), 'Everyday');
insert into hrms.shift_versions (org_id, shift_id, version_no, effective_from, start_local, end_local, weekly_mask, state, published_at)
select test.org('TEST_ORG'), id, 1, date '2025-01-01', time '10:00', time '19:00', 127, 'published', now()
from hrms.shifts where name = 'Everyday';
update hrms.shift_assignments set effective_to = make_date(pg_temp.yr(), 12, 1) where employee_id = test.emp('EMP03');
insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from)
select test.org('TEST_ORG'), test.emp('EMP03'), id, make_date(pg_temp.yr(), 12, 1) from hrms.shifts where name = 'Everyday';
select test.grant_leave('EMP03', pg_temp.cl(), pg_temp.yr() + 1, 0 + 1);   -- only a half day next year
select test.login('EMP03');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), make_date(pg_temp.yr(), 12, 31), make_date(pg_temp.yr() + 1, 1, 1)), 'INSUFFICIENT_BALANCE',
  'LEAVE-006 cross-year request fails when second year is short');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.leave_reservations r join hrms.leave_accounts a on a.id = r.account_id
                where a.employee_id = test.emp('EMP03') and r.day = make_date(pg_temp.yr(), 12, 31) and r.state = 'active'), 0,
  'LEAVE-006 no partial reservation in the first year');

-- ============================================================ corrections
-- CORR-006: no punches at all on a past scheduled day -> manual session.
select test.as_admin_db();
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP01')], current_date - 10, current_date - 1);
create temporary table cd as select shift_date, start_at, end_at from hrms.work_schedule_instances
  where employee_id = test.emp('EMP01') and shift_date between current_date - 10 and current_date - 1 and is_required
  order by shift_date limit 2;
grant select on cd to authenticated;
select test.login('EMP01');
create temporary table k1 as select public.save_correction_request(null, shift_date, start_at, end_at, 'Forgot my phone',
  true, null, gen_random_uuid()) as res from (select * from cd order by shift_date limit 1) x;
select test.eq((select res -> 'data' ->> 'state' from k1), 'submitted', 'CORR-006 correction submitted');
select test.throws(format('select public.save_correction_request(null, %L, %L, %L, ''reason'', true, null, gen_random_uuid())',
  (select shift_date from cd order by shift_date limit 1), (select end_at from cd order by shift_date limit 1),
  (select start_at from cd order by shift_date limit 1)), 'VALIDATION_FAILED', 'CORR-002 OUT before IN rejected');
select test.login('MGR01');
create temporary table k2 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from k1;
select public.decide_request((res -> 'data' ->> 'id')::uuid, 'approve', null, (res ->> 'version')::integer) from k2;
select test.as_admin_db();
select test.eq((select effective_source from hrms.attendance_sessions where employee_id = test.emp('EMP01')
                and shift_date = (select shift_date from cd order by shift_date limit 1)), 'manual',
  'CORR-006 manual session labelled manual, not GPS');
select test.eq((select count(*)::integer from hrms.attendance_events e join hrms.attendance_sessions s on s.id = e.session_id
                where s.employee_id = test.emp('EMP01') and s.shift_date = (select shift_date from cd order by shift_date limit 1)), 0,
  'CORR-006 no fabricated GPS events');

-- CORR-003 / CORR-007: two corrections against the same revision -> second conflicts.
select test.login('EMP01');
create temporary table k3 as select public.save_correction_request(null, shift_date, start_at + interval '30 minutes', end_at,
  'Arrived later', true, null, gen_random_uuid()) as res from (select * from cd order by shift_date limit 1) x;
create temporary table k4 as select public.save_correction_request(null, shift_date, start_at, end_at - interval '1 hour',
  'Left early', true, null, gen_random_uuid()) as res from (select * from cd order by shift_date limit 1) x;
select test.login('MGR01');
create temporary table k5 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from k3;
create temporary table k6 as select public.open_request_for_review((res -> 'data' ->> 'id')::uuid) as res from k4;
select public.decide_request((res -> 'data' ->> 'id')::uuid, 'approve', null, (res ->> 'version')::integer) from k5;
select test.throws(format('select public.decide_request(%L, ''approve'', null, %s)', (select res -> 'data' ->> 'id' from k6),
  (select res ->> 'version' from k6)), 'STALE_VERSION', 'CORR-003 second approval on same revision conflicts');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.attendance_adjustments a join hrms.attendance_sessions s on s.id = a.session_id
                where s.employee_id = test.emp('EMP01') and s.shift_date = (select shift_date from cd order by shift_date limit 1)), 2,
  'CORR-007 corrections append revisions; history retained');
select test.throws($$delete from hrms.attendance_adjustments$$, '42501', 'CORR-007 approved correction cannot be erased');

-- TIME-018: approving leave over accepted attendance is a conflict (no debit).
select test.as_admin_db();
update hrms.leave_types set backdate_days = 30 where code = 'CL';
select test.login('EMP01');
select test.throws(format('select public.save_leave_request(null, %L, %L, %L, ''FULL'', ''FULL'', ''x'', null, true, null, gen_random_uuid())',
  pg_temp.cl(), (select shift_date from cd order by shift_date limit 1), (select shift_date from cd order by shift_date limit 1)),
  'LEAVE_ATTENDANCE_CONFLICT', 'TIME-018 leave over recorded attendance rejected');
rollback;
