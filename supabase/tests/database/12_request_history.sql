-- HISTORY-001..005: final requests stay reachable through keyset-paginated
-- employee and reviewer filters without changing the default pending queue.
begin;
select test.standard_org();

select test.as_admin_db();
insert into hrms.requests (
  org_id, employee_id, kind, state, assigned_reviewer_id,
  target_shift_date, submitted_at, decided_at
) values
  (test.org('TEST_ORG'), test.emp('EMP01'), 'correction', 'approved', test.emp('HR01'),
   date '2026-09-20', now() - interval '4 days', now() - interval '3 days'),
  (test.org('TEST_ORG'), test.emp('EMP01'), 'correction', 'rejected', test.emp('HR01'),
   date '2026-09-21', now() - interval '3 days', now() - interval '2 days'),
  (test.org('TEST_ORG'), test.emp('EMP01'), 'correction', 'cancelled', test.emp('HR01'),
   date '2026-09-22', now() - interval '2 days', now() - interval '1 day'),
  (test.org('TEST_ORG'), test.emp('EMP01'), 'correction', 'submitted', test.emp('HR01'),
   date '2026-09-23', now() - interval '1 day', null);

-- HISTORY-001 owners can see every request, or convenient grouped history.
select test.login('EMP01');
select test.eq(jsonb_array_length(public.list_my_requests() -> 'data'), 4,
  'HISTORY-001 All includes active and final requests');
select test.eq(jsonb_array_length(public.list_my_requests(null, 'active') -> 'data'), 1,
  'HISTORY-001 Active contains pending work');
select test.eq(jsonb_array_length(public.list_my_requests(null, 'completed') -> 'data'), 3,
  'HISTORY-001 Completed contains approved, rejected and cancelled');
select test.eq(jsonb_array_length(public.list_my_requests(null, 'cancelled') -> 'data'), 1,
  'HISTORY-001 Cancelled is directly filterable');

-- HISTORY-002 keyset pagination returns the rest without duplicates/offsets.
with first_page as (
  select public.list_my_requests(null, null, 2) -> 'data' as rows
), second_page as (
  select public.list_my_requests(
    null, null, 2,
    (rows -> 1 ->> 'created_at')::timestamptz,
    (rows -> 1 ->> 'id')::uuid
  ) -> 'data' as rows
  from first_page
)
select test.eq((select jsonb_array_length(rows) from second_page), 2,
  'HISTORY-002 next keyset page returns remaining history');

-- HISTORY-003 default reviewer view stays action-focused; history is explicit.
select test.login('HR01');
select test.eq(jsonb_array_length(public.list_review_queue() -> 'data'), 1,
  'HISTORY-003 default review queue contains pending only');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'mine', 'completed') -> 'data'), 3,
  'HISTORY-003 reviewer Completed shows every final decision');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'mine', 'approved') -> 'data'), 1,
  'HISTORY-003 reviewer can filter Approved');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'mine', 'rejected') -> 'data'), 1,
  'HISTORY-003 reviewer can filter Not approved');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'mine', 'cancelled') -> 'data'), 1,
  'HISTORY-003 reviewer can filter Cancelled');

-- HISTORY-004 reviewer scope is preserved for history; Admin can use Everyone.
select test.login('HR02');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'mine', 'completed') -> 'data'), 0,
  'HISTORY-004 unrelated reviewer cannot see another reviewer history');
select test.login('ADMIN01');
select test.eq(jsonb_array_length(public.list_review_queue(null, 'all', 'completed') -> 'data'), 3,
  'HISTORY-004 Admin Everyone scope includes completed history');

-- HISTORY-005 unknown filters are rejected instead of silently hiding data.
select test.login('EMP01');
select test.throws($q$select public.list_my_requests(null, 'gone')$q$, 'VALIDATION_FAILED',
  'HISTORY-005 invalid owner status rejected');
select test.login('HR01');
select test.throws($q$select public.list_review_queue(null, 'mine', 'gone')$q$, 'VALIDATION_FAILED',
  'HISTORY-005 invalid reviewer status rejected');

rollback;
