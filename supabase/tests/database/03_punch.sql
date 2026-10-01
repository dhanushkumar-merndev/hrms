-- LOC-001..009, PUNCH-001/003/007/011/012, API-004: the transactional punch
-- commit against a real PostGIS geodesic fixture. Test coordinates only.
begin;
select test.standard_org();

create or replace function pg_temp.o1() returns uuid language sql as
$$ select id from hrms.offices where name = 'O1' and org_id = test.org('TEST_ORG') $$;

-- Point exactly p_m metres from O1 (spheroidal geodesic).
create or replace function pg_temp.at(p_m double precision, p_az double precision default 0.785398)
returns table (lat double precision, lng double precision) language sql as $$
  select extensions.st_y(g::extensions.geometry), extensions.st_x(g::extensions.geometry)
  from (select extensions.st_project(location, p_m, p_az) as g from hrms.offices where id = pg_temp.o1()) s;
$$;

create or replace function pg_temp.device(p_code text, p_biometric boolean default true) returns uuid language sql as $$
  insert into hrms.devices (org_id, employee_id, installation_id, platform, public_key_spki, attestation_level,
                            biometric_bound)
  values (test.org('TEST_ORG'), test.emp(p_code), gen_random_uuid(), 'android', repeat('A', 91), 'hardware', p_biometric)
  returning id;
$$;

-- Schedule instance around NOW (labelled with a synthetic date so it never
-- collides with materialised days). Window: start-30m .. end+120m.
create or replace function pg_temp.instance(p_code text, p_day date, p_start_offset interval default '-1 hour',
                                            p_len interval default '9 hours') returns uuid language sql as $$
  insert into hrms.work_schedule_instances (org_id, employee_id, shift_date, kind, is_required, office_id,
    shift_version_id, timezone, start_at, end_at, lunch_paid, grace_seconds, early_entry_seconds, early_credit,
    checkout_extension_seconds, expected_seconds, half_split_at)
  select test.org('TEST_ORG'), test.emp(p_code), p_day, 'workday', true, pg_temp.o1(), sv.id, 'Asia/Kolkata',
         now() + p_start_offset, now() + p_start_offset + p_len, true, 1800, 1800, false, 7200,
         extract(epoch from p_len)::integer, now() + p_start_offset + p_len / 2
  from hrms.shift_versions sv join hrms.shifts s on s.id = sv.shift_id and s.name = 'General'
  returning id;
$$;

create or replace function pg_temp.challenge(p_code text, p_device uuid, p_action text, p_target uuid,
                                             p_ttl interval default '60 seconds') returns uuid language sql as $$
  insert into hrms.punch_challenges (org_id, employee_id, device_id, action, target_id, nonce, expires_at)
  values (test.org('TEST_ORG'), test.emp(p_code), p_device, p_action, p_target, hrms.random_token(), clock_timestamp() + p_ttl)
  returning id;
$$;

create or replace function pg_temp.punch(p_code text, p_action text, p_target uuid, p_device uuid,
  p_lat double precision, p_lng double precision, p_acc double precision default 5,
  p_age interval default '2 seconds', p_key uuid default null, p_hash text default null,
  p_challenge uuid default null, p_receipt timestamptz default null,
  p_integrity jsonb default '{"level":"hardware","mock_location":false}') returns jsonb language plpgsql as $$
declare p test.people; v_key uuid := coalesce(p_key, gen_random_uuid()); v_receipt timestamptz;
begin
  select * into p from test.people where code = p_code;
  v_receipt := coalesce(p_receipt, clock_timestamp());
  return public.internal_commit_punch(p.auth_user_id, p.session_id, p.alias, v_key,
    coalesce(p_hash, 'hash-' || v_key::text),
    coalesce(p_challenge, pg_temp.challenge(p_code, p_device, p_action, p_target)),
    p_action, p_target, p_device, pg_temp.o1(), p_lat, p_lng, p_acc, v_receipt - p_age, v_receipt, p_integrity);
end $$;

-- ---------------------------------------------------------------- EMP01 happy path
create temporary table t as select pg_temp.device('EMP01') as dev, pg_temp.instance('EMP01', date '2030-01-01') as inst;
create temporary table r1 as
  select pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '2 seconds',
                       '11111111-1111-1111-1111-111111111111', 'hash-A') as res from t;
select test.eq((select (res ->> 'ok')::boolean from r1), true, 'LOC-001 valid IN 10 m away accepted');
select test.eq((select res -> 'data' -> 'session' ->> 'state' from r1), 'open', 'LOC-001 session open');
select test.ok((select abs((res -> 'data' ->> 'distance_m')::numeric - 10) < 0.1 from r1), 'LOC-001 server distance ~10 m');
select test.eq((select count(*)::integer from hrms.attendance_events where employee_id = test.emp('EMP01')), 1,
  'LOC-001 exactly one accepted event');

-- PUNCH-003 / PUNCH-012: same key + same payload returns the ORIGINAL result,
-- even though the old challenge is consumed and the sample is now stale.
create temporary table r2 as
  select pg_temp.punch('EMP01', 'IN', inst, dev, 0, 0, 999, '1 hour',
                       '11111111-1111-1111-1111-111111111111', 'hash-A') as res from t;
select test.eq((select res -> 'data' ->> 'event_id' from r2), (select res -> 'data' ->> 'event_id' from r1),
  'PUNCH-012 committed replay returns original result before freshness checks');
select test.eq((select count(*)::integer from hrms.attendance_events where employee_id = test.emp('EMP01')), 1,
  'PUNCH-003 replay adds no event');
select test.eq((select test.err(pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng,
                 5, '2 seconds', '11111111-1111-1111-1111-111111111111', 'hash-B')) from t),
  'IDEMPOTENCY_CONFLICT', 'PUNCH-003 same key + different payload conflicts');

-- PUNCH-001: a second IN for the same shift is an invalid sequence.
select test.eq((select test.err(pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t),
  'INVALID_PUNCH_SEQUENCE', 'PUNCH-001 duplicate IN rejected');

-- OUT closes exactly the open session.
create temporary table sess as select id from hrms.attendance_sessions where employee_id = test.emp('EMP01') and state = 'open';
create temporary table r3 as
  select pg_temp.punch('EMP01', 'OUT', (select id from sess), dev, (pg_temp.at(3)).lat, (pg_temp.at(3)).lng) as res from t;
select test.eq((select (res ->> 'ok')::boolean from r3), true, 'PUNCH-001 valid OUT accepted');
select test.eq((select state from hrms.attendance_sessions where id = (select id from sess)), 'closed', 'session closed after OUT');
select test.eq((select test.err(pg_temp.punch('EMP01', 'OUT', (select id from sess), dev, (pg_temp.at(3)).lat,
                 (pg_temp.at(3)).lng)) from t), 'INVALID_PUNCH_SEQUENCE', 'PUNCH-001 second OUT rejected');
select test.ok((select count(*) = 2 from hrms.attendance_events where employee_id = test.emp('EMP01')),
  'normal pair stored once');

-- ---------------------------------------------------------------- EMP02 geofence/accuracy/freshness
delete from hrms.rate_limit_buckets;
create temporary table t2 as select pg_temp.device('EMP02') as dev, pg_temp.instance('EMP02', date '2030-01-02') as inst;
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(20.001)).lat, (pg_temp.at(20.001)).lng)) from t2),
  'OUTSIDE_ZONE', 'LOC-002 20.001 m rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 15.001)) from t2),
  'LOCATION_INACCURATE', 'LOC-003 accuracy 15.001 rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 0)) from t2),
  'LOCATION_INACCURATE', 'LOC-003 accuracy 0 rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, -1)) from t2),
  'LOCATION_INACCURATE', 'LOC-003 negative accuracy rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 'NaN'::float8)) from t2),
  'LOCATION_REQUIRED', 'LOC-003 NaN accuracy rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, 91, 77.59)) from t2),
  'LOCATION_REQUIRED', 'LOC-005 latitude out of range rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '10.001 seconds')) from t2),
  'LOCATION_STALE', 'LOC-004 sample 10.001 s old rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '-2.001 seconds')) from t2),
  'LOCATION_STALE', 'LOC-004 sample 2.001 s in future rejected');
delete from hrms.rate_limit_buckets;
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '2 seconds',
                 null, null, null, clock_timestamp() - interval '31 seconds')) from t2),
  'VERIFICATION_FAILED', 'API-004 commit later than 30 s after receipt rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '2 seconds',
                 null, null, null, clock_timestamp() + interval '1 minute')) from t2),
  'VERIFICATION_FAILED', 'API-004 future receipt time rejected');
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(10)).lat, (pg_temp.at(10)).lng, 5, '2 seconds',
                 null, null, null, null, '{"level":"hardware","mock_location":true}')) from t2),
  'VERIFICATION_FAILED', 'LOC-010 mock location evidence rejected');
select test.eq((select count(*)::integer from hrms.attendance_events where employee_id = test.emp('EMP02')), 0,
  'no event from any rejected attempt');
select test.ok((select count(*) >= 10 from hrms.punch_rejections where employee_id = test.emp('EMP02')),
  'rejected attempts logged separately from accepted events');
-- Boundary accept last (after rejections): 19.999 m, accuracy exactly 15, sample exactly 10 s old.
delete from hrms.rate_limit_buckets;
select test.eq((select (pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(19.999)).lat, (pg_temp.at(19.999)).lng, 15,
                 '10 seconds') ->> 'ok')::boolean from t2), true, 'LOC-002/003/004 19.999 m, 15 m accuracy, 10 s age accepted');

-- ---------------------------------------------------------------- EMP03 challenge binding
delete from hrms.rate_limit_buckets;
create temporary table t3 as select pg_temp.device('EMP03') as dev, pg_temp.instance('EMP03', date '2030-01-03') as inst;
create temporary table c3 as select pg_temp.challenge('EMP03', dev, 'OUT', inst) as ch from t3;
select test.eq((select test.err(pg_temp.punch('EMP03', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5, '2 seconds',
                 null, null, (select ch from c3))) from t3), 'VERIFICATION_FAILED', 'LOC-009 challenge bound to action');
create temporary table c4 as select pg_temp.challenge('EMP03', dev, 'IN', inst, '-1 second') as ch from t3;
select test.eq((select test.err(pg_temp.punch('EMP03', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5, '2 seconds',
                 null, null, (select ch from c4))) from t3), 'VERIFICATION_FAILED', 'LOC-009 expired challenge rejected');
create temporary table c5 as select pg_temp.challenge('EMP02', (select dev from t2), 'IN', (select inst from t3)) as ch;
select test.eq((select test.err(pg_temp.punch('EMP03', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5, '2 seconds',
                 null, null, (select ch from c5))) from t3), 'VERIFICATION_FAILED', 'LOC-009 another actor''s challenge rejected');
create temporary table c6 as select pg_temp.challenge('EMP03', dev, 'IN', inst) as ch from t3;
select test.eq((select (pg_temp.punch('EMP03', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5, '2 seconds',
                 null, null, (select ch from c6)) ->> 'ok')::boolean from t3), true, 'fresh bound challenge accepted');
select test.eq((select test.err(pg_temp.punch('EMP03', 'OUT', (select id from hrms.attendance_sessions where employee_id = test.emp('EMP03')),
                 dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5, '2 seconds', null, null, (select ch from c6))) from t3),
  'VERIFICATION_FAILED', 'LOC-009 consumed challenge cannot be replayed');

-- ---------------------------------------------------------------- MGR01: office policy rechecked (LOC-008)
delete from hrms.rate_limit_buckets;
create temporary table t4 as select pg_temp.device('MGR01') as dev, pg_temp.instance('MGR01', date '2030-01-04') as inst;
update hrms.offices set active = false where id = pg_temp.o1();
select test.eq((select test.err(pg_temp.punch('MGR01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t4),
  'OUTSIDE_ZONE', 'LOC-008 deactivated office rejected at commit');
update hrms.offices set active = true where id = pg_temp.o1();
update hrms.devices set revoked_at = now() where id = (select dev from t4);
select test.eq((select test.err(pg_temp.punch('MGR01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t4),
  'VERIFICATION_FAILED', 'LOC-011 revoked device rejected');

-- ---------------------------------------------------------------- MGR02: PUNCH-011 stale session rollover
delete from hrms.rate_limit_buckets;
create temporary table t5 as select pg_temp.device('MGR02') as dev,
  pg_temp.instance('MGR02', date '2030-01-05', '-20 hours', '9 hours') as old_inst,
  pg_temp.instance('MGR02', date '2030-01-06', '-1 hour', '9 hours') as new_inst;
-- An old session left open (checked in yesterday, never checked out).
insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state, effective_in_at)
select test.org('TEST_ORG'), test.emp('MGR02'), old_inst, date '2030-01-05', 'open', now() - interval '20 hours' from t5;
create temporary table old_sess as select id from hrms.attendance_sessions where schedule_instance_id = (select old_inst from t5);
select test.eq((select (pg_temp.punch('MGR02', 'IN', new_inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng) ->> 'ok')::boolean from t5),
  true, 'PUNCH-011 today''s IN accepted despite yesterday''s open session');
select test.eq((select state from hrms.attendance_sessions where id = (select id from old_sess)), 'needs_correction',
  'PUNCH-011 stale session became needs_correction');
select test.eq((select count(*)::integer from hrms.attendance_events where session_id = (select id from old_sess)), 0,
  'PUNCH-011 no fabricated OUT event');
select test.eq((select test.err(pg_temp.punch('MGR02', 'OUT', (select id from old_sess), dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t5),
  'INVALID_PUNCH_SEQUENCE', 'PUNCH-011 stale OUT cannot close the old session');
select test.eq((select state from hrms.attendance_sessions where schedule_instance_id = (select new_inst from t5)), 'open',
  'PUNCH-011 stale OUT did not touch today''s session');

-- ---------------------------------------------------------------- PUNCH-007 rate limit
delete from hrms.rate_limit_buckets;
select pg_temp.punch('EMP02', 'IN', inst, dev, 0, 0) from t2, generate_series(1, 10);
select test.eq((select test.err(pg_temp.punch('EMP02', 'IN', inst, dev, 0, 0)) from t2), 'RATE_LIMITED',
  'PUNCH-007 eleventh attempt within a minute is rate limited');

-- ---------------------------------------------------------------- biometric-bound policy
delete from hrms.rate_limit_buckets;
create temporary table t6 as select pg_temp.device('ADMIN01', false) as dev, pg_temp.instance('ADMIN01', date '2030-01-07') as inst;
select test.eq((select test.err(pg_temp.punch('ADMIN01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t6),
  'VERIFICATION_FAILED', 'hardware key without biometric binding rejected while policy is on');
update hrms.organizations set require_biometric_punch = false where code = 'TEST_ORG';
select test.eq((select (pg_temp.punch('ADMIN01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng) ->> 'ok')::boolean from t6),
  true, 'Admin can turn the biometric requirement off');
update hrms.organizations set require_biometric_punch = true where code = 'TEST_ORG';

-- ---------------------------------------------------------------- holiday instance
delete from hrms.rate_limit_buckets;
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('HR02')], date '2026-10-02', date '2026-10-02');
select test.eq((select test.err(pg_temp.punch('HR02', 'IN',
                  (select id from hrms.work_schedule_instances where employee_id = test.emp('HR02') and shift_date = date '2026-10-02'),
                  pg_temp.device('HR02'), (pg_temp.at(5)).lat, (pg_temp.at(5)).lng))),
  'INVALID_SHIFT', 'PUNCH-009 holiday disables ordinary IN');
-- HOME-002: the morning after a completed day, Home offers TODAY's shift (it
-- returned yesterday's closed one: NULL sorted after false with NULLS LAST).
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('HR01')],
  hrms.org_today(test.org('TEST_ORG')) - 1, hrms.org_today(test.org('TEST_ORG')));
insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state,
                                      effective_in_at, effective_out_at)
select org_id, employee_id, id, shift_date, 'closed', start_at, start_at + interval '1 minute'
from hrms.work_schedule_instances
where employee_id = test.emp('HR01') and shift_date = hrms.org_today(test.org('TEST_ORG')) - 1;
create temporary table home_day as select hrms.org_today(test.org('TEST_ORG'))::text as d;
grant select on home_day to authenticated;
select test.login('HR01');
select test.eq(public.get_home_summary() -> 'data' -> 'shift' ->> 'shift_date', (select d from home_day), 'HOME-002 next morning Home shows today, not yesterday''s closed shift');
rollback;
