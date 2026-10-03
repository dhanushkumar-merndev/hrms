-- WIFI-001..004 and OUT-001..006: office Wi-Fi gate on punches and
-- Admin-granted outside work counted as a full working day.
begin;
select test.standard_org();

create or replace function pg_temp.o1() returns uuid language sql security definer as
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


-- ============================================================ office Wi-Fi
select test.login('HR01');
select test.throws(format('select public.set_office_wifi(%L, array[''x''])', pg_temp.o1()), 'ACCESS_DENIED',
  'WIFI-001 only Admin sets office Wi-Fi');
select test.login('ADMIN01');
create temporary table w0 as select public.set_office_wifi(pg_temp.o1(),
  array['Airtel abhi 3999', ' Airtel stargardens 5G ', '', 'Airtel abhi 3999']) as res;
select test.eq((select jsonb_array_length(res -> 'data' -> 'wifi_ssids') from w0), 2, 'WIFI-001 names cleaned and de-duplicated');

select test.as_admin_db();
create temporary table t as select pg_temp.device('EMP01') as dev, pg_temp.instance('EMP01', date '2030-01-01') as inst;
select test.eq((select test.err(pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng)) from t),
  'WIFI_REQUIRED', 'WIFI-002 no Wi-Fi reported: rejected even inside the area');
select test.eq((select test.err(pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5,
                 '2 seconds', null, null, null, null,
                 '{"level":"hardware","mock_location":false,"wifi_ssid":"Cafe WiFi"}')) from t),
  'WIFI_REQUIRED', 'WIFI-002 other Wi-Fi rejected');
select test.eq((select test.err(pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(500)).lat, (pg_temp.at(500)).lng, 5,
                 '2 seconds', null, null, null, null,
                 '{"level":"hardware","mock_location":false,"wifi_ssid":"Airtel abhi 3999"}')) from t),
  'OUTSIDE_ZONE', 'WIFI-003 office Wi-Fi alone is not enough: location still checked');
create temporary table w1 as select pg_temp.punch('EMP01', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5,
  '2 seconds', null, null, null, null,
  '{"level":"hardware","mock_location":false,"wifi_ssid":"airtel STARGARDENS 5g"}') as res from t;
select test.eq((select (res ->> 'ok')::boolean from w1), true, 'WIFI-004 office location + office Wi-Fi accepted (any case)');
-- WIFI-005: on mobile data, office Wi-Fi seen nearby in a scan is enough.
create temporary table t2 as select pg_temp.device('EMP02') as dev, pg_temp.instance('EMP02', date '2030-01-02') as inst;
create temporary table w2 as select pg_temp.punch('EMP02', 'IN', inst, dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5,
  '2 seconds', null, null, null, null,
  '{"level":"hardware","mock_location":false,"wifi_ssid":null,"wifi_nearby":["Neighbour","Airtel abhi 3999"]}') as res from t2;
select test.eq((select (res ->> 'ok')::boolean from w2), true, 'WIFI-005 office Wi-Fi nearby (not connected) accepted');
select test.eq((select test.err(pg_temp.punch('EMP02', 'OUT', (select id from hrms.attendance_sessions
                 where employee_id = test.emp('EMP02') and state = 'open'), dev, (pg_temp.at(5)).lat, (pg_temp.at(5)).lng, 5,
                 '2 seconds', null, null, null, null,
                 '{"level":"hardware","mock_location":false,"wifi_nearby":["Neighbour"]}')) from t2),
  'WIFI_REQUIRED', 'WIFI-005 only other Wi-Fi nearby: rejected');
select test.login('ADMIN01');
select public.set_office_wifi(pg_temp.o1(), array[]::text[]);
select test.as_admin_db();
select test.eq((select wifi_ssids from hrms.offices where id = pg_temp.o1()), '{}'::text[], 'WIFI-001 cleared: location only');

-- ============================================================ outside work
-- A past working day with no punches, and a future one (Mon after next).
create or replace function pg_temp.mon() returns date language sql as $$
  select current_date + ((7 - extract(isodow from current_date)::integer) + 1) + 7;
$$;
create or replace function pg_temp.row(p_code text, p_day date) returns hrms.attendance_row language sql security definer as $$
  select r from hrms.attendance_rows(test.org('TEST_ORG'), array[test.emp(p_code)], p_day, p_day, now()) r;
$$;
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP02')], pg_temp.mon() - 14, pg_temp.mon());
select test.eq((pg_temp.row('EMP02', pg_temp.mon() - 14)).status, 'absent', 'OUT-001 past workday without punches is absent');

select test.login('HR01');
select test.throws(format('select public.grant_outside_work(array[%L]::uuid[], %L, %L, ''Client visit'')',
  test.emp('EMP02'), pg_temp.mon() - 14, pg_temp.mon()), 'ACCESS_DENIED', 'OUT-002 only Admin grants outside work');
select test.login('ADMIN01');
select test.throws(format('select public.grant_outside_work(array[%L]::uuid[], %L, %L, ''x'')',
  test.emp('EMP02'), pg_temp.mon() - 60, pg_temp.mon()), 'VALIDATION_FAILED', 'OUT-002 at most 31 days');
create temporary table g1 as select public.grant_outside_work(array[test.emp('EMP02')], pg_temp.mon() - 14,
  pg_temp.mon() - 14, 'Client visit') as res;
select public.grant_outside_work(array[test.emp('EMP02')], pg_temp.mon(), pg_temp.mon(), 'Site survey');
select test.eq((select (res -> 'data' ->> 'days_added')::integer from g1), 1, 'OUT-003 one day granted');
select test.eq((select (public.grant_outside_work(array[test.emp('EMP02')], pg_temp.mon() - 14, pg_temp.mon() - 14,
  'again') -> 'data' ->> 'days_added')::integer), 0, 'OUT-003 granting again adds nothing');

select test.as_admin_db();
select test.eq((pg_temp.row('EMP02', pg_temp.mon() - 14)).status, 'present', 'OUT-004 granted day counts as present');
select test.eq((pg_temp.row('EMP02', pg_temp.mon() - 14)).effective_source, 'outside', 'OUT-004 marked as outside work');
select test.eq(((pg_temp.row('EMP02', pg_temp.mon() - 14)).calc).credited_seconds,
  ((pg_temp.row('EMP02', pg_temp.mon() - 14)).calc).required_seconds, 'OUT-004 full shift credited');
select test.eq(((pg_temp.row('EMP02', pg_temp.mon() - 14)).calc).shortfall_seconds, 0, 'OUT-004 no shortfall');
select test.eq(hrms.attendance_row_json(pg_temp.row('EMP02', pg_temp.mon() - 14)) ->> 'outside_reason', 'Client visit',
  'OUT-004 reason shown on the day');
select test.eq(hrms.attendance_row_json(pg_temp.row('EMP01', pg_temp.mon() - 14)) ->> 'outside_reason', null::text,
  'OUT-004 no reason on normal days');
select test.eq((pg_temp.row('EMP02', pg_temp.mon())).effective_source, 'outside', 'OUT-004 future day pre-approved');
select test.eq((pg_temp.row('EMP02', pg_temp.mon())).status, 'upcoming', 'OUT-004 future day not counted as present yet');
select test.eq((pg_temp.row('EMP01', pg_temp.mon() - 14)).effective_source, null::text, 'OUT-004 others unaffected');

select test.login('ADMIN01');
create temporary table l1 as select public.list_outside_work(pg_temp.mon() - 20) as res;
select test.eq((select jsonb_array_length(res -> 'data') from l1), 2, 'OUT-005 Admin lists active grants');
select test.throws(format('select public.revoke_outside_work(%L, null)', (select res -> 'data' -> 0 ->> 'id' from l1)),
  'VALIDATION_FAILED', 'OUT-006 revoking needs a reason');
select public.revoke_outside_work((g ->> 'id')::uuid, 'Visit cancelled')
from l1, jsonb_array_elements(res -> 'data') g where (g ->> 'work_date')::date = pg_temp.mon() - 14;
select test.as_admin_db();
select test.eq((pg_temp.row('EMP02', pg_temp.mon() - 14)).status, 'absent', 'OUT-006 revoked day no longer credited');
select test.eq((select count(*)::integer from hrms.notifications where kind = 'attendance.outside_work'
                and recipient_id = test.emp('EMP02')), 2, 'OUT-003 employee notified per grant');

rollback;
