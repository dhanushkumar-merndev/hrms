-- HOL-002: feed import is suggestion-only, de-duplicated by date, and never
-- publishes; manual holidays keep working without the feed.
begin;
select test.standard_org();

create or replace function pg_temp.today() returns date language sql security definer as $$
  select hrms.org_today(test.org('TEST_ORG')) $$;
create or replace function pg_temp.sid(p_name text) returns uuid language sql security definer as $$
  select id from hrms.holiday_suggestions where org_id = test.org('TEST_ORG') and name = p_name $$;
create or replace function pg_temp.hstate(p_id uuid) returns text language sql security definer as $$
  select state from hrms.holidays where id = p_id $$;

create temporary table feed as select jsonb_build_array(
  jsonb_build_object('day', pg_temp.today() + 40, 'name', 'Festival A', 'category', 'Public holiday', 'uid', 'a'),
  jsonb_build_object('day', pg_temp.today() + 50, 'name', 'Festival B', 'category', 'Observance', 'uid', 'b'),
  jsonb_build_object('day', pg_temp.today() - 5, 'name', 'Already past', 'category', 'Public holiday', 'uid', 'c'),
  jsonb_build_object('day', pg_temp.today() + 60, 'name', '   ', 'category', null, 'uid', 'd')) as items;
grant select on feed to authenticated, service_role;

select test.as_service();
select test.eq((public.internal_store_holiday_suggestions(test.org('TEST_ORG'), 'public_calendar',
                  (select items from feed)) ->> 'added')::integer, 2, 'HOL-002 future, named items stored as suggestions');
select test.eq((public.internal_store_holiday_suggestions(test.org('TEST_ORG'), 'public_calendar',
                  (select items from feed)) ->> 'added')::integer, 0, 'HOL-002 re-import de-duplicated');
select test.throws($q$select public.internal_store_holiday_suggestions(null, 'x', '{"not":"array"}'::jsonb)$q$,
  'VALIDATION_FAILED', 'malformed feed rejected');
select test.as_admin_db();
select test.eq((select count(*)::integer from hrms.holidays where org_id = test.org('TEST_ORG') and source = 'import'), 0,
  'HOL-002 nothing drafted or published automatically');

select test.login('EMP01');
select test.throws('select public.list_holiday_suggestions()', 'ACCESS_DENIED', 'members cannot see suggestions');
select test.throws(format('select public.add_holiday_from_suggestion(%L)', pg_temp.sid('Festival A')), 'ACCESS_DENIED',
  'members cannot add suggestions');

select test.login('HR01');
select test.eq((select jsonb_array_length(public.list_holiday_suggestions() -> 'data' -> 'suggestions')), 2,
  'HR with policy drafting sees suggestions');
create temporary table added as select public.add_holiday_from_suggestion(pg_temp.sid('Festival A')) -> 'data' as d;
grant select on added to authenticated, service_role;
select test.eq(pg_temp.hstate((select (d ->> 'holiday_id')::uuid from added)), 'draft', 'added as a DRAFT holiday only');
select test.eq((select (public.add_holiday_from_suggestion(pg_temp.sid('Festival A')) -> 'data' ->> 'already')::boolean),
  true, 'adding twice is idempotent');
select test.eq((select (public.dismiss_holiday_suggestion(pg_temp.sid('Festival B')) -> 'data' ->> 'dismissed')::boolean),
  true, 'suggestion dismissed');
select test.eq((select count(*)::integer from jsonb_array_elements(public.list_holiday_suggestions() -> 'data' -> 'suggestions') s
                where s ->> 'state' = 'new'), 0, 'no open suggestions left');

-- A manual holiday on a suggested date wins; the suggestion shows the conflict.
select test.as_service();
select public.internal_store_holiday_suggestions(test.org('TEST_ORG'), 'public_calendar',
  jsonb_build_array(jsonb_build_object('day', pg_temp.today() + 70, 'name', 'Festival C', 'category', 'Public holiday')));
select test.login('HR01');
select public.save_holiday(null, pg_temp.today() + 70, 'Company day', null, null);
select test.eq((select s -> 'existing_holiday' ->> 'name' from jsonb_array_elements(
                  public.list_holiday_suggestions() -> 'data' -> 'suggestions') s where s ->> 'name' = 'Festival C'),
  'Company day', 'existing holiday on the date is shown');
select test.throws(format('select public.add_holiday_from_suggestion(%L)', pg_temp.sid('Festival C')), 'VALIDATION_FAILED',
  'HOL-002 duplicate date for the same scope rejected');

rollback;
