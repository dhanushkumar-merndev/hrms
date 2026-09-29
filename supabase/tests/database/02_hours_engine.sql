-- TIME-001..010, TIME-015/016 and the architecture §5.2 table, against the
-- pure engine with a 10:00–19:00 IST shift (paid lunch, 30 min grace,
-- 120 min extension) on 2026-09-28 (Monday).
begin;

create temporary table t_shift as select
  timestamptz '2026-09-28 10:00:00+05:30' as s,
  timestamptz '2026-09-28 19:00:00+05:30' as e,
  timestamptz '2026-09-28 14:30:00+05:30' as split;

create or replace function pg_temp.day(p_in text, p_out text, p_slots integer default 0,
                                       p_ext integer default 7200, p_early boolean default false)
returns hrms.day_calc language sql as $$
  select hrms.calc_day(true, s, e, split, 32400, p_slots, 1800, p_early, p_ext,
                       ('2026-09-28 ' || p_in || '+05:30')::timestamptz,
                       ('2026-09-28 ' || p_out || '+05:30')::timestamptz)
  from t_shift;
$$;

-- TIME-001 / table row 1: 10:00–19:00
select test.eq((pg_temp.day('10:00', '19:00')).presence_seconds, 32400, 'TIME-001 presence 9h');
select test.eq((pg_temp.day('10:00', '19:00')).credited_seconds, 32400, 'TIME-001 credited 9h (paid lunch not deducted)');
select test.eq((pg_temp.day('10:00', '19:00')).required_seconds, 32400, 'TIME-001 required 32,400 s');
select test.eq((pg_temp.day('10:00', '19:00')).shortfall_seconds, 0, 'TIME-001 no shortfall');
-- TIME-002 / row 2: 10:30–19:00
select test.eq((pg_temp.day('10:30', '19:00')).credited_seconds, 30600, 'TIME-002 credited 8:30');
select test.eq((pg_temp.day('10:30', '19:00')).shortfall_seconds, 1800, 'TIME-002 short 0:30');
select test.eq((pg_temp.day('10:30', '19:00')).is_late, false, 'TIME-002 10:30 is within grace');
-- TIME-003 / row 3: 10:30–19:30 with extension
select test.eq((pg_temp.day('10:30', '19:30')).credited_seconds, 32400, 'TIME-003 credited 9:00 with extension');
select test.eq((pg_temp.day('10:30', '19:30')).shortfall_seconds, 0, 'TIME-003 no shortfall');
select test.eq((pg_temp.day('10:30', '19:30')).extra_seconds, 0, 'TIME-003 no extra');
-- TIME-004: exact grace boundary vs one second later
select test.eq((pg_temp.day('10:30:00', '19:00')).is_late, false, 'TIME-004 10:30:00 within grace');
select test.eq((pg_temp.day('10:30:01', '19:00')).is_late, true, 'TIME-004 10:30:01 late');
select test.eq((pg_temp.day('10:30:01', '19:00')).credited_seconds, 30599, 'TIME-004 seconds retained in math');
-- Row 4: 10:31–19:00
select test.eq((pg_temp.day('10:31', '19:00')).credited_seconds, 30540, 'row 4 credited 8:29');
select test.eq((pg_temp.day('10:31', '19:00')).shortfall_seconds, 1860, 'row 4 short 0:31');
select test.eq((pg_temp.day('10:31', '19:00')).is_late, true, 'row 4 late');
-- TIME-005: early arrival, no early credit
select test.eq((pg_temp.day('09:30', '19:00')).presence_seconds, 34200, 'TIME-005 presence 9:30');
select test.eq((pg_temp.day('09:30', '19:00')).credited_seconds, 32400, 'TIME-005 credited 9:00 (no early credit)');
select test.eq((pg_temp.day('09:30', '19:00', 0, 7200, true)).credited_seconds, 34200,
  'early credit counts from IN when explicitly enabled');
-- TIME-006: extension disabled -> credit stops at 19:00
select test.eq((pg_temp.day('10:00', '20:00', 0, 0)).credited_seconds, 32400, 'TIME-006 no credit after end when extension off');
select test.eq((pg_temp.day('10:00', '21:00', 0, 7200)).extra_seconds, 7200, 'extension credit is extra, not paid overtime');
-- Early departure compares to scheduled end even after early arrival
select test.eq((pg_temp.day('09:30', '18:30')).is_early_departure, true, 'early departure vs scheduled end');
select test.eq((pg_temp.day('09:30', '18:30')).early_seconds, 1800, 'early departure 30 min');

-- TIME-009: required hours by day type
select test.eq((hrms.calc_day(true, s, e, split, 32400, 3, 1800, false, 7200, null, null)).required_seconds, 0,
  'TIME-009 full leave requires 0') from t_shift;
select test.eq((hrms.calc_day(true, s, e, split, 32400, 1, 1800, false, 7200, null, null)).required_seconds, 16200,
  'TIME-009 AM half leave requires 4:30') from t_shift;
select test.eq((hrms.calc_day(false, s, e, split, 32400, 0, 1800, false, 7200, null, null)).required_seconds, 0,
  'TIME-009 holiday/weekly off requires 0') from t_shift;

-- TIME-010: no netting across days (each day computed independently)
select test.eq((pg_temp.day('10:30', '19:00')).shortfall_seconds + (pg_temp.day('10:00', '19:30')).shortfall_seconds,
  1800, 'TIME-010 weekly short stays 0:30');
select test.eq((pg_temp.day('10:30', '19:00')).extra_seconds + (pg_temp.day('10:00', '19:30')).extra_seconds,
  1800, 'TIME-010 weekly extra stays 0:30 separately');

-- TIME-015: AM leave, work 14:30–19:00
select test.eq((pg_temp.day('14:30', '19:00', 1)).required_seconds, 16200, 'TIME-015 required 4:30');
select test.eq((pg_temp.day('14:30', '19:00', 1)).credited_seconds, 16200, 'TIME-015 credited 4:30');
select test.eq((pg_temp.day('14:30', '19:00', 1)).is_late, false, 'TIME-015 14:30 not late');
select test.eq((pg_temp.day('14:30', '19:00', 1)).is_early_departure, false, 'TIME-015 not early');
select test.eq((pg_temp.day('15:00', '19:00', 1)).is_late, false, 'TIME-015 15:00 within grace of 14:30');
select test.eq((pg_temp.day('15:00', '19:00', 1)).shortfall_seconds, 1800, 'TIME-015 15:00 IN short 0:30');
-- TIME-016: PM leave, work 10:00–14:30
select test.eq((pg_temp.day('10:00', '14:30', 2)).is_early_departure, false, 'TIME-016 14:30 OUT not early');
select test.eq((pg_temp.day('10:00', '14:30', 2)).credited_seconds, 16200, 'TIME-016 credited 4:30');
select test.eq((pg_temp.day('10:00', '16:00', 2)).credited_seconds, 16200, 'TIME-016 credit capped at 4:30');
select test.eq((pg_temp.day('10:00', '16:00', 2)).leave_conflict_seconds, 5400, 'TIME-016 overlap with leave flagged');
select test.eq((pg_temp.day('10:00', '16:00', 2)).extra_seconds, 0, 'TIME-016 no automatic extra on partial day');

-- TIME-007 / row 5: overnight 22:00–07:00, IN 22:15 OUT 07:00 next day
select test.eq((hrms.calc_day(true, timestamptz '2026-09-28 22:00+05:30', timestamptz '2026-09-29 07:00+05:30',
                timestamptz '2026-09-29 02:30+05:30', 32400, 0, 1800, false, 7200,
                timestamptz '2026-09-28 22:15+05:30', timestamptz '2026-09-29 07:00+05:30')).credited_seconds,
  31500, 'TIME-007 overnight credited 8:45');
select test.eq((hrms.calc_day(true, timestamptz '2026-09-28 22:00+05:30', timestamptz '2026-09-29 07:00+05:30',
                timestamptz '2026-09-29 02:30+05:30', 32400, 0, 1800, false, 7200,
                timestamptz '2026-09-28 22:15+05:30', timestamptz '2026-09-29 07:00+05:30')).shortfall_seconds,
  900, 'TIME-007 overnight short 0:15');

-- Missing OUT is unknown: no credited hours invented
select test.eq((hrms.calc_day(true, s, e, split, 32400, 0, 1800, false, 7200,
                timestamptz '2026-09-28 10:00+05:30', null)).credited_seconds, 0,
  'TIME-008 missing OUT credits nothing (unknown, not 9h)') from t_shift;

-- TIME-011: lunch validation
select test.ok(hrms.validate_shift(time '10:00', time '19:00', time '13:00', time '14:00') = '{}'::jsonb, 'TIME-011 lunch inside shift valid');
select test.ok(hrms.validate_shift(time '10:00', time '19:00', time '20:00', time '21:00') ? 'lunch', 'TIME-011 lunch outside shift rejected');
select test.ok(hrms.validate_shift(time '10:00', time '19:00', time '14:00', time '13:00') ? 'lunch', 'TIME-011 negative lunch rejected');
select test.ok(hrms.validate_shift(time '22:00', time '07:00', time '02:00', time '02:30') = '{}'::jsonb, 'TIME-011 overnight lunch valid');
select test.ok(hrms.validate_shift(time '10:00', time '10:00', null, null) ? 'end_local', 'zero-length shift rejected');

-- Schedule materialisation: holiday, weekly off, overnight, split point
select test.standard_org();
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP01')], date '2026-09-28', date '2026-10-04');
select test.eq((select kind from hrms.work_schedule_instances where employee_id = test.emp('EMP01') and shift_date = date '2026-10-02'),
  'holiday', 'published holiday 2 Oct is not a working day');
select test.eq((select kind from hrms.work_schedule_instances where employee_id = test.emp('EMP01') and shift_date = date '2026-10-03'),
  'weekly_off', 'Saturday is weekly off');
select test.eq((select start_at from hrms.work_schedule_instances where employee_id = test.emp('EMP01') and shift_date = date '2026-09-28'),
  timestamptz '2026-09-28 10:00+05:30', 'start in office time zone');
select test.eq((select half_split_at from hrms.work_schedule_instances where employee_id = test.emp('EMP01') and shift_date = date '2026-09-28'),
  timestamptz '2026-09-28 14:30+05:30', 'half-day split at 14:30 for paid-lunch shift');
select test.eq((select expected_seconds from hrms.work_schedule_instances where employee_id = test.emp('EMP01') and shift_date = date '2026-09-28'),
  32400, 'expected 32,400 s including paid lunch');
select test.eq((select count(*)::integer from hrms.work_schedule_instances where employee_id = test.emp('EMP01')
                and shift_date between date '2026-09-28' and date '2026-10-04' and is_required), 4,
  'Mon–Fri minus holiday = 4 required days');
-- Idempotent: running again creates nothing new and changes nothing.
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP01')], date '2026-09-28', date '2026-10-04');
select test.eq((select count(*)::integer from hrms.work_schedule_instances where employee_id = test.emp('EMP01')), 7,
  'materialisation is idempotent');

-- Overnight shift instance ends next day
update hrms.shift_assignments set effective_to = date '2026-09-30' where employee_id = test.emp('EMP02');
insert into hrms.shift_assignments (org_id, employee_id, shift_id, effective_from)
select test.org('TEST_ORG'), test.emp('EMP02'), id, date '2026-09-30' from hrms.shifts where name = 'Night';
select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP02')], date '2026-09-30', date '2026-09-30');
select test.eq((select end_at from hrms.work_schedule_instances where employee_id = test.emp('EMP02') and shift_date = date '2026-09-30'),
  timestamptz '2026-10-01 07:00+05:30', 'overnight shift ends next morning, grouped by start date');

-- Range bound protects against caller-controlled width.
select test.throws($$select hrms.ensure_schedule_instances(test.org('TEST_ORG'), array[test.emp('EMP01')], date '2024-01-01', date '2026-01-01')$$,
  'RANGE_TOO_LARGE', 'materialisation range is bounded');

-- Instances are immutable snapshots.
select test.throws($$update hrms.work_schedule_instances set expected_seconds = 1$$, '42501', 'instances cannot be updated');
rollback;
