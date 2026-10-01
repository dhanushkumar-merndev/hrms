-- Keep every request and review decision reachable on the phone. NULL keeps
-- the reviewer screen focused on pending work; explicit filters expose final
-- history. Employee lists support convenient active/completed groups too.

create or replace function public.list_my_requests(
  p_kind text default null, p_state text default null, p_limit integer default 25,
  p_before_created_at timestamptz default null, p_before_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_rows jsonb;
begin
  if p_state is not null and p_state not in (
    'active', 'completed', 'draft', 'submitted', 'under_review', 'returned',
    'approved', 'rejected', 'cancelled', 'withdrawal_pending', 'cancellation_pending'
  ) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown request status.');
  end if;
  select coalesce(jsonb_agg(hrms.request_summary(r) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_rows
  from (
    select * from hrms.requests r
    where r.employee_id = v_actor.employee_id
      and (p_kind is null or r.kind = p_kind)
      and case
            when p_state is null then true
            when p_state = 'active' then r.state in (
              'draft', 'submitted', 'under_review', 'returned',
              'withdrawal_pending', 'cancellation_pending')
            when p_state = 'completed' then r.state in ('approved', 'rejected', 'cancelled')
            else r.state = p_state
          end
      and (p_before_created_at is null or (r.created_at, r.id) < (p_before_created_at, p_before_id))
    order by r.created_at desc, r.id desc
    limit v_limit
  ) r;
  return hrms.ok(v_rows);
end;
$$;

create or replace function public.list_review_queue(
  p_kind text default null, p_scope text default 'mine', p_state text default null,
  p_limit integer default 25, p_before_submitted_at timestamptz default null, p_before_id uuid default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_rows jsonb;
begin
  if p_scope not in ('mine', 'all', 'unassigned') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown scope');
  end if;
  if p_scope <> 'mine' and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_state is not null and p_state not in (
    'completed', 'submitted', 'under_review', 'approved', 'rejected', 'cancelled',
    'withdrawal_pending', 'cancellation_pending'
  ) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown review status.');
  end if;
  select coalesce(jsonb_agg(hrms.request_summary(r) order by r.submitted_at desc, r.id desc), '[]'::jsonb)
    into v_rows
  from (
    select * from hrms.requests r
    where r.org_id = v_actor.org_id
      and r.employee_id <> v_actor.employee_id
      and case
            when p_state is null then r.state in (
              'submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')
            when p_state = 'completed' then r.state in ('approved', 'rejected', 'cancelled')
            else r.state = p_state
          end
      and (p_kind is null or r.kind = p_kind)
      and case p_scope
            when 'mine' then r.assigned_reviewer_id = v_actor.employee_id
            when 'unassigned' then r.assigned_reviewer_id is null
            else true end
      and (p_before_submitted_at is null or (r.submitted_at, r.id) < (p_before_submitted_at, p_before_id))
    order by r.submitted_at desc, r.id desc
    limit v_limit
  ) r;
  return hrms.ok(v_rows);
end;
$$;

select hrms.apply_api_grants();
