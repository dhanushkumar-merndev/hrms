-- Leave is reviewed only by HR or Admin. Unassigned employee-data and leave
-- requests remain claimable by their eligible reviewer pool instead of
-- becoming dead ends.

create or replace function hrms.is_hr_admin_reviewer(
  p_reviewer uuid, p_requester uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_reviewer is not null and p_reviewer <> p_requester and exists (
    select 1
    from hrms.employees e
    where e.id = p_reviewer
      and e.status = 'active'
      and e.provisioning_state = 'complete'
      and hrms.employee_roles(e.id) && array['hr', 'admin']
  );
$$;

create or replace function hrms.resolve_reviewer(
  p_org uuid, p_employee uuid, p_kind text, p_day date
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_team uuid := hrms.team_on(p_employee, p_day);
  v_route hrms.approval_routes;
  v_primary uuid;
begin
  if v_team is null then
    v_team := hrms.team_on(p_employee, hrms.org_today(p_org));
  end if;

  if p_kind = 'leave' then
    select e.id into v_primary
    from hrms.employees e
    where e.org_id = p_org
      and hrms.is_hr_admin_reviewer(e.id, p_employee)
    order by case when 'hr' = any(hrms.employee_roles(e.id))
                            and not ('admin' = any(hrms.employee_roles(e.id)))
                       then 0 else 1 end,
             e.employee_code, e.id
    limit 1;
    return jsonb_build_object(
      'reviewer_id', v_primary,
      'team_id', v_team,
      'mode', 'hr_admin',
      'reason', case when v_primary is null then 'no_eligible_reviewer' end
    );
  end if;

  select * into v_route
  from hrms.approval_routes
  where team_id = v_team and request_kind = p_kind and superseded_at is null;
  if not found then
    return jsonb_build_object(
      'reviewer_id', null, 'team_id', v_team, 'reason', 'no_route');
  end if;
  v_primary := case v_route.reviewer_mode
    when 'manager' then hrms.manager_of_team_on(v_team, hrms.org_today(p_org))
    else v_route.hr_reviewer_id end;
  if hrms.is_eligible_reviewer(v_primary, p_employee) then
    return jsonb_build_object(
      'reviewer_id', v_primary, 'team_id', v_team, 'route_id', v_route.id,
      'mode', v_route.reviewer_mode, 'fallback', false);
  end if;
  if hrms.is_eligible_reviewer(v_route.fallback_reviewer_id, p_employee) then
    return jsonb_build_object(
      'reviewer_id', v_route.fallback_reviewer_id, 'team_id', v_team,
      'route_id', v_route.id, 'mode', v_route.reviewer_mode, 'fallback', true);
  end if;
  return jsonb_build_object(
    'reviewer_id', null, 'team_id', v_team, 'route_id', v_route.id,
    'mode', v_route.reviewer_mode, 'reason', 'no_eligible_reviewer');
end;
$$;

create or replace function hrms.change_review_authority(
  p_actor hrms.actor, p_req hrms.requests
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_class text := p_req.route_snapshot ->> 'initiator_class';
begin
  if p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then
    return null;
  end if;
  if v_class not in ('employee', 'hr') then return null; end if;
  if v_class = 'hr' and not hrms.is_admin(p_actor) then return null; end if;
  if v_class = 'employee'
     and not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then
    return null;
  end if;
  if p_req.assigned_reviewer_id = p_actor.employee_id then return 'assigned'; end if;
  if hrms.is_admin(p_actor) then return 'admin'; end if;
  if v_class = 'employee' and p_req.assigned_reviewer_id is null then return 'pool'; end if;
  return null;
end;
$$;

create or replace function hrms.review_authority(
  p_actor hrms.actor, p_req hrms.requests
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_assigned_valid boolean;
begin
  if p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then
    return null;
  end if;
  if hrms.is_employee_change_kind(p_req.kind) then
    return hrms.change_review_authority(p_actor, p_req);
  end if;
  if p_req.kind = 'leave' then
    if not (hrms.is_admin(p_actor) or 'hr' = any(p_actor.roles)) then return null; end if;
    if p_req.assigned_reviewer_id = p_actor.employee_id then return 'assigned'; end if;
    if hrms.is_admin(p_actor) then return 'admin'; end if;
    v_assigned_valid := hrms.is_hr_admin_reviewer(
      p_req.assigned_reviewer_id, p_req.employee_id);
    if not coalesce(v_assigned_valid, false) then return 'pool'; end if;
    return null;
  end if;
  if p_req.kind = 'bank_details'
     and p_req.route_snapshot ->> 'mode' = 'change'
     and not hrms.is_admin(p_actor) then return null; end if;
  if p_req.assigned_reviewer_id = p_actor.employee_id then return 'assigned'; end if;
  if hrms.is_admin(p_actor) then return 'admin'; end if;
  return null;
end;
$$;

create or replace function public.list_review_queue(
  p_kind text default null, p_scope text default 'mine', p_state text default null,
  p_limit integer default 25, p_before_submitted_at timestamptz default null,
  p_before_id uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_rows jsonb;
begin
  if p_scope not in ('mine', 'all', 'unassigned') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown scope');
  end if;
  if p_scope = 'all' and not hrms.is_admin(v_actor) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_scope = 'unassigned'
     and not (hrms.is_admin(v_actor) or 'hr' = any(v_actor.roles)) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if p_state is not null and p_state not in (
    'completed', 'submitted', 'under_review', 'approved', 'rejected', 'cancelled',
    'withdrawal_pending', 'cancellation_pending'
  ) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown review status.');
  end if;
  select coalesce(
    jsonb_agg(hrms.request_summary(r) order by r.submitted_at desc, r.id desc),
    '[]'::jsonb) into v_rows
  from (
    select *
    from hrms.requests r
    where r.org_id = v_actor.org_id
      and r.employee_id <> v_actor.employee_id
      and hrms.review_authority(v_actor, r) is not null
      and case
        when p_state is null then r.state in (
          'submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')
        when p_state = 'completed' then r.state in ('approved', 'rejected', 'cancelled')
        else r.state = p_state end
      and (p_kind is null or r.kind = p_kind)
      and case p_scope
        when 'mine' then r.assigned_reviewer_id = v_actor.employee_id
        when 'unassigned' then r.assigned_reviewer_id is null
          or (r.kind = 'leave' and not hrms.is_hr_admin_reviewer(
                r.assigned_reviewer_id, r.employee_id))
        else true end
      and (p_before_submitted_at is null
           or (r.submitted_at, r.id) < (p_before_submitted_at, p_before_id))
    order by r.submitted_at desc, r.id desc
    limit v_limit
  ) r;
  return hrms.ok(v_rows);
end;
$$;

create or replace function public.set_approval_route(
  p_team_id uuid, p_kind text, p_mode text, p_hr_reviewer_id uuid,
  p_fallback_reviewer_id uuid, p_reason text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.require_admin(v_actor);
  if p_kind not in ('leave', 'correction') or p_mode not in ('manager', 'hr') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose Manager or HR.');
  end if;
  if p_kind = 'leave' and p_mode <> 'hr' then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Leave approval is restricted to HR or Admin.',
      '{"mode":"Choose HR or Admin"}'::jsonb);
  end if;
  if not exists (
    select 1 from hrms.teams where id = p_team_id and org_id = v_actor.org_id
  ) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if p_mode = 'hr' and not exists (
    select 1 from hrms.employees e
    where e.id = p_hr_reviewer_id and e.org_id = v_actor.org_id
      and hrms.is_hr_admin_reviewer(
        e.id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Choose an active HR or Admin reviewer.',
      '{"hr_reviewer_id":"HR/Admin required"}'::jsonb);
  end if;
  if p_fallback_reviewer_id is not null and (
       (p_kind = 'leave' and not exists (
         select 1 from hrms.employees e
         where e.id = p_fallback_reviewer_id and e.org_id = v_actor.org_id
           and hrms.is_hr_admin_reviewer(
             e.id, '00000000-0000-0000-0000-000000000000'::uuid)))
       or (p_kind <> 'leave' and not exists (
         select 1 from hrms.employees e
         where e.id = p_fallback_reviewer_id and e.org_id = v_actor.org_id
           and e.status = 'active'
           and hrms.employee_roles(e.id) && array['manager', 'hr', 'admin']))
     ) then
    perform hrms.raise_error(
      'VALIDATION_FAILED',
      case when p_kind = 'leave' then 'Fallback must be active HR or Admin.'
           else 'Fallback must be an active Manager, HR or Admin.' end,
      '{"fallback_reviewer_id":"Not eligible"}'::jsonb);
  end if;
  update hrms.approval_routes set superseded_at = now()
  where team_id = p_team_id and request_kind = p_kind and superseded_at is null;
  insert into hrms.approval_routes (
    org_id, team_id, request_kind, reviewer_mode, hr_reviewer_id,
    fallback_reviewer_id, created_by
  ) values (
    v_actor.org_id, p_team_id, p_kind, p_mode,
    case when p_mode = 'hr' then p_hr_reviewer_id end,
    p_fallback_reviewer_id, v_actor.employee_id
  );
  perform hrms.audit(
    v_actor.org_id, v_actor.employee_id, 'approval_route.set', 'team', p_team_id,
    jsonb_build_object(
      'kind', p_kind, 'mode', p_mode, 'hr_reviewer_id', p_hr_reviewer_id,
      'fallback_reviewer_id', p_fallback_reviewer_id, 'reason', p_reason));
  return public.list_approval_routes();
end;
$$;

alter function public.reassign_request(uuid, uuid, text, integer)
  rename to reassign_request_before_hr_admin_leave;

create function public.reassign_request(
  p_request_id uuid, p_new_reviewer_id uuid, p_reason text,
  p_expected_version integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
begin
  select * into v_req
  from hrms.requests
  where id = p_request_id and org_id = v_actor.org_id;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.kind = 'leave'
     and not hrms.is_hr_admin_reviewer(p_new_reviewer_id, v_req.employee_id) then
    perform hrms.raise_error(
      'VALIDATION_FAILED', 'Leave can be assigned only to HR or Admin.',
      '{"reviewer_id":"HR/Admin required"}'::jsonb);
  end if;
  return public.reassign_request_before_hr_admin_leave(
    p_request_id, p_new_reviewer_id, p_reason, p_expected_version);
end;
$$;

revoke all on function public.reassign_request_before_hr_admin_leave(
  uuid, uuid, text, integer) from public, anon, authenticated, service_role;
revoke all on function public.reassign_request(
  uuid, uuid, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.reassign_request(
  uuid, uuid, text, integer) to authenticated;
