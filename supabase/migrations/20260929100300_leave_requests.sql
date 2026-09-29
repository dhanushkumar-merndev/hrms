-- =============================================================================
-- Leave policies/ledger and the shared request + approval state machine for
-- leave and attendance-correction requests (architecture.md §6).
--
-- Units are integer half-days (full day = 2, half = 1).
-- available(allocation) = ledger sum (allocate + credit_back - debit - expire)
--                         - active reservations
-- =============================================================================

create table hrms.leave_types (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  code text not null check (code ~ '^[A-Z0-9_]{2,16}$'),
  name text not null check (char_length(name) between 1 and 60),
  paid boolean not null default true,
  half_day_allowed boolean not null default true,
  requires_attachment boolean not null default false,
  attachment_class text not null default 'general' check (attachment_class in ('general', 'medical')),
  max_consecutive_days integer check (max_consecutive_days between 1 and 366),
  advance_notice_days integer not null default 0 check (advance_notice_days between 0 and 365),
  backdate_days integer not null default 7 check (backdate_days between 0 and 366),
  active boolean not null default true,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, code),
  unique (org_id, id)
);
create trigger leave_types_touch before update on hrms.leave_types
  for each row execute function hrms.touch_updated_at();

-- Entitlement per leave type per leave year. Publishing creates allocations.
create table hrms.leave_policies (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  leave_type_id uuid not null,
  leave_year integer not null check (leave_year between 2000 and 2200),
  annual_units integer not null check (annual_units between 0 and 730),
  carry_cap_units integer not null default 0 check (carry_cap_units between 0 and 730),
  carry_expiry_months integer check (carry_expiry_months between 1 and 12),
  prorata boolean not null default false,
  state text not null default 'draft' check (state in ('draft', 'published')),
  published_at timestamptz,
  published_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (leave_type_id, leave_year),
  foreign key (org_id, leave_type_id) references hrms.leave_types(org_id, id) on delete restrict
);

create table hrms.leave_accounts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  leave_type_id uuid not null,
  leave_year integer not null,
  created_at timestamptz not null default now(),
  unique (employee_id, leave_type_id, leave_year),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, leave_type_id) references hrms.leave_types(org_id, id) on delete restrict
);
create index leave_accounts_lookup on hrms.leave_accounts (employee_id, leave_type_id, leave_year);

create table hrms.leave_allocations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  account_id uuid not null references hrms.leave_accounts(id) on delete restrict,
  source text not null check (source in ('annual', 'prorata', 'carry_forward', 'manual')),
  valid_from date not null,
  valid_to date not null,
  policy_id uuid references hrms.leave_policies(id) on delete restrict,
  operation_id uuid not null,
  created_by uuid,
  reason text check (char_length(reason) <= 500),
  created_at timestamptz not null default now(),
  check (valid_to > valid_from),
  unique (account_id, operation_id)
);
create index leave_allocations_account_idx on hrms.leave_allocations (account_id, valid_to, id);

create table hrms.leave_ledger (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  account_id uuid not null references hrms.leave_accounts(id) on delete restrict,
  allocation_id uuid not null references hrms.leave_allocations(id) on delete restrict,
  entry_kind text not null check (entry_kind in ('allocate', 'debit', 'credit_back', 'expire', 'adjust')),
  units integer not null check (units <> 0),
  source_operation_id uuid not null,
  request_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (account_id, source_operation_id, entry_kind, allocation_id)
);
create index leave_ledger_allocation_idx on hrms.leave_ledger (allocation_id);
create index leave_ledger_request_idx on hrms.leave_ledger (request_id) where request_id is not null;
create trigger leave_ledger_append_only before update or delete on hrms.leave_ledger
  for each row execute function hrms.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Requests (leave + correction) with immutable revisions
-- -----------------------------------------------------------------------------

create table hrms.requests (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  kind text not null check (kind in ('leave', 'correction')),
  state text not null check (state in ('draft', 'submitted', 'under_review', 'returned', 'approved',
    'rejected', 'cancelled', 'withdrawal_pending', 'cancellation_pending')),
  current_revision integer not null default 1,
  version integer not null default 1,
  assigned_reviewer_id uuid,
  route_snapshot jsonb,
  first_opened_at timestamptz,
  first_opened_by uuid,
  locked_revision integer,
  approved_revision integer,
  edited boolean not null default false,
  submitted_at timestamptz,
  decided_at timestamptz,
  decided_by uuid,
  -- Safe listing projection (never the reason or attachments).
  leave_type_id uuid,
  start_date date,
  end_date date,
  units integer,
  target_shift_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, id),
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, assigned_reviewer_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, leave_type_id) references hrms.leave_types(org_id, id) on delete restrict,
  check (kind <> 'leave' or (leave_type_id is not null and start_date is not null and end_date is not null)),
  check (kind <> 'correction' or target_shift_date is not null)
);
create index requests_reviewer_idx on hrms.requests (assigned_reviewer_id, state, submitted_at desc, id);
create index requests_employee_idx on hrms.requests (employee_id, start_date desc, id);
create index requests_employee_created_idx on hrms.requests (employee_id, created_at desc, id);
create index requests_org_state_idx on hrms.requests (org_id, state, submitted_at desc, id);
create trigger requests_touch before update on hrms.requests
  for each row execute function hrms.touch_updated_at();
create trigger requests_no_delete before delete on hrms.requests
  for each row execute function hrms.forbid_mutation();

create table hrms.request_revisions (
  request_id uuid not null references hrms.requests(id) on delete restrict,
  revision_no integer not null,
  payload jsonb not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (request_id, revision_no)
);
create trigger request_revisions_append_only before update or delete on hrms.request_revisions
  for each row execute function hrms.forbid_mutation();

create table hrms.leave_reservations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  request_id uuid not null references hrms.requests(id) on delete restrict,
  revision_no integer not null,
  account_id uuid not null references hrms.leave_accounts(id) on delete restrict,
  allocation_id uuid not null references hrms.leave_allocations(id) on delete restrict,
  day date not null,
  slot text not null check (slot in ('AM', 'PM', 'FULL')),
  units integer not null check (units in (1, 2)),
  state text not null default 'active' check (state in ('active', 'converted', 'released')),
  created_at timestamptz not null default now(),
  released_at timestamptz
);
create index leave_reservations_active_alloc on hrms.leave_reservations (allocation_id) where state = 'active';
create index leave_reservations_request_idx on hrms.leave_reservations (request_id, state);

-- Day/slot occupancy. AM = [0,1), PM = [1,2), FULL = [0,2); reserved and
-- approved slots of one employee can never overlap.
create table hrms.leave_day_slots (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  request_id uuid not null references hrms.requests(id) on delete restrict,
  revision_no integer not null,
  day date not null,
  slot text not null check (slot in ('AM', 'PM', 'FULL')),
  slot_range int4range not null,
  state text not null check (state in ('reserved', 'approved', 'released')),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  constraint leave_day_slots_no_overlap exclude using gist (
    employee_id with =, day with =, slot_range with &&
  ) where (state in ('reserved', 'approved'))
);
create index leave_day_slots_emp_day on hrms.leave_day_slots (employee_id, day) where state in ('reserved', 'approved');
create index leave_day_slots_request on hrms.leave_day_slots (request_id, state);

create table hrms.approval_routes (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  team_id uuid not null,
  request_kind text not null check (request_kind in ('leave', 'correction')),
  reviewer_mode text not null check (reviewer_mode in ('manager', 'hr')),
  hr_reviewer_id uuid,
  fallback_reviewer_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  superseded_at timestamptz,
  check (reviewer_mode <> 'hr' or hr_reviewer_id is not null),
  foreign key (org_id, team_id) references hrms.teams(org_id, id) on delete restrict,
  foreign key (org_id, hr_reviewer_id) references hrms.employees(org_id, id) on delete restrict,
  foreign key (org_id, fallback_reviewer_id) references hrms.employees(org_id, id) on delete restrict
);
create unique index approval_routes_active on hrms.approval_routes (team_id, request_kind) where superseded_at is null;

create table hrms.approval_events (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  request_id uuid not null references hrms.requests(id) on delete restrict,
  revision_no integer,
  action text not null,
  actor_id uuid,
  reason text check (char_length(reason) <= 1000),
  from_state text,
  to_state text,
  created_at timestamptz not null default now()
);
create index approval_events_request_idx on hrms.approval_events (request_id, id);
create trigger approval_events_append_only before update or delete on hrms.approval_events
  for each row execute function hrms.forbid_mutation();

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

create or replace function hrms.leave_year_of(p_start_month integer, p_day date) returns integer
language sql
immutable
set search_path = ''
as $$
  select case when extract(month from p_day)::integer >= p_start_month
              then extract(year from p_day)::integer
              else extract(year from p_day)::integer - 1 end;
$$;

-- Deterministic operation id for a request state transition (stable across
-- HTTP retries; independent of client idempotency keys).
create or replace function hrms.transition_op(p_request uuid, p_kind text, p_revision integer)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select md5(p_request::text || ':' || p_kind || ':' || p_revision::text)::uuid;
$$;

create or replace function hrms.slot_range(p_slot text) returns int4range
language sql
immutable
set search_path = ''
as $$
  select case p_slot when 'AM' then int4range(0, 1) when 'PM' then int4range(1, 2) else int4range(0, 2) end;
$$;

-- Replaces the stub from the attendance migration.
create or replace function hrms.approved_leave_slots(p_employee uuid, p_day date) returns integer
language sql
stable
set search_path = ''
as $$
  select case
    when bool_or(slot = 'FULL') or (bool_or(slot = 'AM') and bool_or(slot = 'PM')) then 3
    when bool_or(slot = 'AM') then 1
    when bool_or(slot = 'PM') then 2
    else 0 end
  from hrms.leave_day_slots
  where employee_id = p_employee and day = p_day and state = 'approved';
$$;

-- Eligible leave days for a date range: only required schedule days count
-- (weekly offs/holidays excluded, no sandwich rule). Returns
-- {days:[{day, slot, units, leave_year}], units, errors}.
create or replace function hrms.compute_leave_days(
  p_org uuid, p_employee uuid, p_type hrms.leave_types,
  p_start date, p_end date, p_start_slot text, p_end_slot text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_emp hrms.employees;
  v_org hrms.organizations;
  v_errors jsonb := '{}'::jsonb;
  v_days jsonb;
  v_units integer;
  v_missing integer;
begin
  select * into v_emp from hrms.employees where id = p_employee and org_id = p_org;
  select * into v_org from hrms.organizations where id = p_org;

  if p_start is null then v_errors := v_errors || '{"start_date":"Required"}'; end if;
  if p_end is null then v_errors := v_errors || '{"end_date":"Required"}'; end if;
  if v_errors <> '{}'::jsonb then return jsonb_build_object('errors', v_errors); end if;
  if p_end < p_start then
    return jsonb_build_object('errors', '{"end_date":"End date must be on or after start date"}'::jsonb);
  end if;
  if p_end - p_start > 365 then
    return jsonb_build_object('errors', '{"end_date":"Leave cannot span more than a year"}'::jsonb);
  end if;
  if p_start_slot not in ('FULL', 'AM', 'PM') or p_end_slot not in ('FULL', 'AM', 'PM') then
    return jsonb_build_object('errors', '{"slot":"Invalid day part"}'::jsonb);
  end if;
  if p_start <> p_end and (p_start_slot = 'AM' or p_end_slot = 'PM') then
    return jsonb_build_object('errors',
      '{"slot":"A multi-day leave can start in the afternoon and end in the morning only"}'::jsonb);
  end if;
  if not p_type.half_day_allowed and (p_start_slot <> 'FULL' or (p_start <> p_end and p_end_slot <> 'FULL')) then
    return jsonb_build_object('errors', '{"slot":"Half days are not allowed for this leave type"}'::jsonb);
  end if;
  if p_start < v_emp.join_date or (v_emp.end_date is not null and p_end > v_emp.end_date) then
    return jsonb_build_object('errors', '{"start_date":"Leave must fall within your employment dates"}'::jsonb);
  end if;
  if p_type.max_consecutive_days is not null and (p_end - p_start + 1) > p_type.max_consecutive_days then
    return jsonb_build_object('errors', jsonb_build_object('end_date',
      format('At most %s consecutive days for this leave type', p_type.max_consecutive_days)));
  end if;

  perform hrms.ensure_schedule_instances(p_org, array[p_employee], p_start, p_end);

  select count(*) into v_missing
  from generate_series(p_start, p_end, interval '1 day') d
  where not exists (select 1 from hrms.work_schedule_instances w
                    where w.employee_id = p_employee and w.shift_date = d::date);
  if v_missing > 0 then
    return jsonb_build_object('errors',
      '{"start_date":"No work schedule is set for some of these dates. Contact HR."}'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', w.shift_date,
           'slot', s.slot,
           'units', case when s.slot = 'FULL' then 2 else 1 end,
           'leave_year', hrms.leave_year_of(v_org.leave_year_start_month, w.shift_date),
           'start_at', w.start_at, 'end_at', w.end_at, 'split_at', w.half_split_at
         ) order by w.shift_date), '[]'::jsonb),
         coalesce(sum(case when s.slot = 'FULL' then 2 else 1 end), 0)
    into v_days, v_units
  from hrms.work_schedule_instances w
  cross join lateral (
    select case
      when p_start = p_end then p_start_slot
      when w.shift_date = p_start then p_start_slot
      when w.shift_date = p_end then p_end_slot
      else 'FULL' end as slot
  ) s
  where w.employee_id = p_employee
    and w.shift_date between p_start and p_end
    and w.is_required;

  if v_units = 0 then
    return jsonb_build_object('errors',
      '{"start_date":"These dates are all holidays or weekly offs — no leave is needed"}'::jsonb);
  end if;
  return jsonb_build_object('days', v_days, 'units', v_units, 'errors', '{}'::jsonb);
end;
$$;

-- Accepted/effective attendance overlapping requested leave slots. Leave and
-- worked time can never both be credited silently.
create or replace function hrms.leave_attendance_conflicts(p_employee uuid, p_days jsonb) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from jsonb_to_recordset(p_days) as d(day date, slot text, start_at timestamptz, end_at timestamptz,
                                       split_at timestamptz)
  join hrms.attendance_sessions s on s.employee_id = p_employee and s.shift_date = d.day
  where s.effective_in_at is not null
    and hrms.overlap_seconds(
          s.effective_in_at, coalesce(s.effective_out_at, greatest(now(), s.effective_in_at)),
          case when d.slot = 'PM' then d.split_at else d.start_at end,
          case when d.slot = 'AM' then d.split_at else d.end_at end) > 0;
$$;

-- Available units per allocation (ledger minus active reservations), one
-- grouped pass — no per-allocation subquery loop.
create or replace function hrms.allocation_availability(p_account_ids uuid[])
returns table (allocation_id uuid, account_id uuid, valid_from date, valid_to date, available integer)
language sql
stable
set search_path = ''
as $$
  select a.id, a.account_id, a.valid_from, a.valid_to,
         (coalesce(l.total, 0) - coalesce(r.total, 0))::integer
  from hrms.leave_allocations a
  left join (select allocation_id, sum(units) as total from hrms.leave_ledger
             where account_id = any(p_account_ids) group by allocation_id) l on l.allocation_id = a.id
  left join (select allocation_id, sum(units) as total from hrms.leave_reservations
             where account_id = any(p_account_ids) and state = 'active' group by allocation_id) r
         on r.allocation_id = a.id
  where a.account_id = any(p_account_ids);
$$;

-- Reserves balance and day slots for a request revision. All-or-nothing:
-- any shortfall in any leave year raises and rolls back the transaction.
-- Accounts are locked in stable id order to prevent concurrent overdraw.
create or replace function hrms.reserve_leave(
  p_org uuid, p_employee uuid, p_request uuid, p_revision integer, p_type hrms.leave_types, p_days jsonb
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_years integer[];
  v_account_ids uuid[];
  a_id uuid[]; a_account uuid[]; a_from date[]; a_to date[]; a_year integer[]; a_avail integer[];
  r_account uuid[] := '{}'; r_alloc uuid[] := '{}'; r_day date[] := '{}'; r_slot text[] := '{}';
  r_units integer[] := '{}';
  v_day record;
  v_need integer;
  v_take integer;
  i integer;
begin
  -- Day/slot occupancy first (exclusion constraint = authoritative overlap check).
  begin
    insert into hrms.leave_day_slots (org_id, employee_id, request_id, revision_no, day, slot, slot_range, state)
    select p_org, p_employee, p_request, p_revision, d.day, d.slot, hrms.slot_range(d.slot), 'reserved'
    from jsonb_to_recordset(p_days) as d(day date, slot text);
  exception when exclusion_violation then
    perform hrms.raise_error('OVERLAPPING_LEAVE', 'You already have leave on one of these days.',
      '{"start_date":"Overlaps an existing leave request"}'::jsonb);
  end;

  if not p_type.paid then
    return;  -- unpaid leave consumes no balance, only day slots
  end if;

  select array_agg(distinct (d ->> 'leave_year')::integer) into v_years from jsonb_array_elements(p_days) d;

  select array_agg(id order by id) into v_account_ids
  from (select id from hrms.leave_accounts
        where employee_id = p_employee and leave_type_id = p_type.id and leave_year = any(v_years)
        order by id for update) locked;

  if v_account_ids is null
     or cardinality(v_account_ids) < cardinality(v_years) then
    perform hrms.raise_error('INSUFFICIENT_BALANCE', 'No leave balance is available for these dates.',
      '{"leave_type_id":"No balance allocated for this leave year"}'::jsonb);
  end if;

  select array_agg(av.allocation_id order by av.valid_to, av.allocation_id),
         array_agg(av.account_id order by av.valid_to, av.allocation_id),
         array_agg(av.valid_from order by av.valid_to, av.allocation_id),
         array_agg(av.valid_to order by av.valid_to, av.allocation_id),
         array_agg(acc.leave_year order by av.valid_to, av.allocation_id),
         array_agg(av.available order by av.valid_to, av.allocation_id)
    into a_id, a_account, a_from, a_to, a_year, a_avail
  from hrms.allocation_availability(v_account_ids) av
  join hrms.leave_accounts acc on acc.id = av.account_id;

  -- Greedy in memory: earliest-expiring valid allocation first; a full day may
  -- split across two allocations. No SQL runs inside this loop.
  for v_day in
    select (d ->> 'day')::date as day, d ->> 'slot' as slot, (d ->> 'units')::integer as units,
           (d ->> 'leave_year')::integer as leave_year
    from jsonb_array_elements(p_days) d order by 1
  loop
    v_need := v_day.units;
    if a_id is not null then
      for i in 1 .. cardinality(a_id) loop
        exit when v_need = 0;
        if a_year[i] = v_day.leave_year and v_day.day >= a_from[i] and v_day.day < a_to[i] and a_avail[i] > 0 then
          v_take := least(v_need, a_avail[i]);
          a_avail[i] := a_avail[i] - v_take;
          v_need := v_need - v_take;
          r_account := r_account || a_account[i];
          r_alloc := r_alloc || a_id[i];
          r_day := r_day || v_day.day;
          r_slot := r_slot || v_day.slot;
          r_units := r_units || v_take;
        end if;
      end loop;
    end if;
    if v_need > 0 then
      perform hrms.raise_error('INSUFFICIENT_BALANCE', 'Not enough leave balance for these dates.',
        jsonb_build_object('leave_type_id', format('Insufficient balance for leave year %s', v_day.leave_year)));
    end if;
  end loop;

  insert into hrms.leave_reservations (org_id, request_id, revision_no, account_id, allocation_id, day, slot, units)
  select p_org, p_request, p_revision, x.account_id, x.allocation_id, x.day, x.slot, x.units
  from unnest(r_account, r_alloc, r_day, r_slot, r_units) as x(account_id, allocation_id, day, slot, units);
end;
$$;

-- Releases active reservations and reserved slots of a request exactly once.
create or replace function hrms.release_request_holds(p_request uuid) returns void
language sql
security definer
set search_path = ''
as $$
  update hrms.leave_reservations set state = 'released', released_at = now()
  where request_id = p_request and state = 'active';
  update hrms.leave_day_slots set state = 'released', released_at = now()
  where request_id = p_request and state = 'reserved';
$$;

-- Converts reservations to ledger debits once (stable transition op id).
create or replace function hrms.debit_request(p_request uuid, p_revision integer, p_actor uuid) returns void
language sql
security definer
set search_path = ''
as $$
  insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id,
                                 request_id, created_by)
  select r.org_id, r.account_id, r.allocation_id, 'debit', -sum(r.units)::integer,
         hrms.transition_op(p_request, 'approve', p_revision), p_request, p_actor
  from hrms.leave_reservations r
  where r.request_id = p_request and r.state = 'active'
  group by r.org_id, r.account_id, r.allocation_id
  on conflict (account_id, source_operation_id, entry_kind, allocation_id) do nothing;
  update hrms.leave_reservations set state = 'converted' where request_id = p_request and state = 'active';
  update hrms.leave_day_slots set state = 'approved' where request_id = p_request and state = 'reserved';
$$;

-- Credits approved leave back to the ORIGINAL allocations exactly once.
create or replace function hrms.credit_back_request(p_request uuid, p_revision integer, p_actor uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into hrms.leave_ledger (org_id, account_id, allocation_id, entry_kind, units, source_operation_id,
                                 request_id, created_by)
  select l.org_id, l.account_id, l.allocation_id, 'credit_back', -sum(l.units)::integer,
         hrms.transition_op(p_request, 'cancel', p_revision), p_request, p_actor
  from hrms.leave_ledger l
  where l.request_id = p_request and l.entry_kind = 'debit'
  group by l.org_id, l.account_id, l.allocation_id
  having sum(l.units) <> 0
  on conflict (account_id, source_operation_id, entry_kind, allocation_id) do nothing;
  update hrms.leave_day_slots set state = 'released', released_at = now()
  where request_id = p_request and state = 'approved';
$$;

-- Eligibility of a reviewer at a point in time: active, provisioned, not the
-- requester, and holding a reviewing role.
create or replace function hrms.is_eligible_reviewer(p_reviewer uuid, p_requester uuid) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_reviewer is not null and p_reviewer <> p_requester and exists (
    select 1 from hrms.employees e
    where e.id = p_reviewer and e.status = 'active' and e.provisioning_state = 'complete'
      and (hrms.employee_roles(e.id) && array['manager', 'hr', 'admin']
           or exists (select 1 from hrms.team_managers tm where tm.manager_id = e.id
                      and (tm.effective_to is null or tm.effective_to > current_date)))
  );
$$;

-- Resolves the reviewer at submission from the Admin-configured route for the
-- employee's team: Manager OR HR (not a sequential two-step), else the
-- explicit fallback. Never the requester. NULL => pending with setup alert.
create or replace function hrms.resolve_reviewer(p_org uuid, p_employee uuid, p_kind text, p_day date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_team uuid := hrms.team_on(p_employee, p_day);
  v_route hrms.approval_routes;
  v_primary uuid;
begin
  if v_team is null then
    v_team := hrms.team_on(p_employee, hrms.org_today(p_org));
  end if;
  select * into v_route from hrms.approval_routes
  where team_id = v_team and request_kind = p_kind and superseded_at is null;
  if not found then
    return jsonb_build_object('reviewer_id', null, 'team_id', v_team, 'reason', 'no_route');
  end if;
  v_primary := case v_route.reviewer_mode
                 when 'manager' then hrms.manager_of_team_on(v_team, hrms.org_today(p_org))
                 else v_route.hr_reviewer_id end;
  if hrms.is_eligible_reviewer(v_primary, p_employee) then
    return jsonb_build_object('reviewer_id', v_primary, 'team_id', v_team, 'route_id', v_route.id,
                              'mode', v_route.reviewer_mode, 'fallback', false);
  end if;
  if hrms.is_eligible_reviewer(v_route.fallback_reviewer_id, p_employee) then
    return jsonb_build_object('reviewer_id', v_route.fallback_reviewer_id, 'team_id', v_team,
                              'route_id', v_route.id, 'mode', v_route.reviewer_mode, 'fallback', true);
  end if;
  return jsonb_build_object('reviewer_id', null, 'team_id', v_team, 'route_id', v_route.id,
                            'mode', v_route.reviewer_mode, 'reason', 'no_eligible_reviewer');
end;
$$;

create or replace function hrms.request_event(
  p_req hrms.requests, p_action text, p_actor uuid, p_reason text, p_from text, p_to text
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into hrms.approval_events (org_id, request_id, revision_no, action, actor_id, reason, from_state, to_state)
  values (p_req.org_id, p_req.id, p_req.current_revision, p_action, p_actor, p_reason, p_from, p_to);
$$;

-- Minimal queue/list projection: no reasons, revisions or attachments.
create or replace function hrms.request_summary(p_req hrms.requests) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_req.id, 'kind', p_req.kind, 'state', p_req.state, 'version', p_req.version,
    'current_revision', p_req.current_revision, 'edited', p_req.edited,
    'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name),
    'leave_type', case when lt.id is null then null else jsonb_build_object('id', lt.id, 'code', lt.code, 'name', lt.name) end,
    'start_date', p_req.start_date, 'end_date', p_req.end_date, 'units', p_req.units,
    'target_shift_date', p_req.target_shift_date,
    'submitted_at', p_req.submitted_at, 'first_opened_at', p_req.first_opened_at,
    'reviewer_assigned', p_req.assigned_reviewer_id is not null,
    'created_at', p_req.created_at, 'updated_at', p_req.updated_at
  )
  from hrms.employees e
  left join hrms.leave_types lt on lt.id = p_req.leave_type_id
  where e.id = p_req.employee_id;
$$;

-- Full detail: revisions, events, reservation state. Callers must already be
-- authorised (owner path or locking reviewer path).
create or replace function hrms.request_detail(p_req hrms.requests) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select hrms.request_summary(p_req) || jsonb_build_object(
    'revisions', (select coalesce(jsonb_agg(jsonb_build_object(
                     'revision_no', rv.revision_no, 'payload', rv.payload, 'created_at', rv.created_at)
                     order by rv.revision_no), '[]'::jsonb)
                  from hrms.request_revisions rv where rv.request_id = p_req.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                  'action', ev.action, 'revision_no', ev.revision_no, 'reason', ev.reason,
                  'from_state', ev.from_state, 'to_state', ev.to_state, 'created_at', ev.created_at,
                  'actor', (select jsonb_build_object('id', a.id, 'name', a.full_name, 'code', a.employee_code)
                            from hrms.employees a where a.id = ev.actor_id))
                  order by ev.id), '[]'::jsonb)
               from hrms.approval_events ev where ev.request_id = p_req.id),
    'reviewer', (select jsonb_build_object('id', r.id, 'name', r.full_name, 'code', r.employee_code)
                 from hrms.employees r where r.id = p_req.assigned_reviewer_id),
    'locked_revision', p_req.locked_revision,
    'approved_revision', p_req.approved_revision,
    'reserved_units', (select coalesce(sum(units), 0) from hrms.leave_reservations
                       where request_id = p_req.id and state = 'active'),
    'debited_units', (select coalesce(-sum(units), 0) from hrms.leave_ledger
                      where request_id = p_req.id and entry_kind = 'debit'),
    'credited_back_units', (select coalesce(sum(units), 0) from hrms.leave_ledger
                            where request_id = p_req.id and entry_kind = 'credit_back')
  );
$$;

-- Notification copy stays lock-screen safe: no names, reasons or medical info.
create or replace function hrms.notify_request(p_req hrms.requests, p_recipient uuid, p_kind text, p_title text,
                                               p_body text, p_for_reviewer boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  select hrms.notify(p_req.org_id, p_recipient, p_kind, p_title, p_body,
    case when p_for_reviewer then '/approvals/' || p_req.id else '/requests/' || p_req.id end,
    jsonb_build_object('request_id', p_req.id, 'kind', p_req.kind),
    md5(p_req.id::text || ':' || p_kind || ':' || p_req.version::text || ':' || p_recipient::text)::uuid);
$$;

-- Alerts every active Admin that a request has no eligible reviewer.
create or replace function hrms.alert_missing_reviewer(p_req hrms.requests) returns void
language sql
security definer
set search_path = ''
as $$
  select hrms.notify(p_req.org_id, e.id, 'setup.reviewer_missing', 'Approver setup needed',
    'A request is waiting because no eligible approver is configured.', '/approvals/' || p_req.id,
    jsonb_build_object('request_id', p_req.id),
    md5(p_req.id::text || ':missing:' || p_req.version::text || ':' || e.id::text)::uuid)
  from hrms.employees e
  where e.org_id = p_req.org_id and e.status = 'active' and e.id <> p_req.employee_id
    and 'admin' = any(hrms.employee_roles(e.id));
$$;

-- Validates a correction proposal against its schedule instance.
create or replace function hrms.validate_correction(
  p_actor hrms.actor, p_shift_date date, p_in timestamptz, p_out timestamptz
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inst hrms.work_schedule_instances;
  v_sess hrms.attendance_sessions;
  v_errors jsonb := '{}'::jsonb;
  v_today date := hrms.org_today(p_actor.org_id);
begin
  if p_shift_date is null then
    return jsonb_build_object('errors', '{"shift_date":"Required"}'::jsonb);
  end if;
  if p_shift_date > v_today then
    return jsonb_build_object('errors', '{"shift_date":"Corrections are for past or current shifts"}'::jsonb);
  end if;
  perform hrms.ensure_schedule_instances(p_actor.org_id, array[p_actor.employee_id], p_shift_date, p_shift_date);
  select * into v_inst from hrms.work_schedule_instances
  where employee_id = p_actor.employee_id and shift_date = p_shift_date;
  if not found or not v_inst.is_required then
    return jsonb_build_object('errors', '{"shift_date":"No working shift is scheduled on this date"}'::jsonb);
  end if;
  if p_in is null then v_errors := v_errors || '{"proposed_in_at":"Required"}'; end if;
  if p_out is null then v_errors := v_errors || '{"proposed_out_at":"Required"}'; end if;
  if v_errors <> '{}'::jsonb then return jsonb_build_object('errors', v_errors); end if;
  if p_out <= p_in then
    return jsonb_build_object('errors',
      '{"proposed_out_at":"Check-out must be after check-in (use Next day for overnight shifts)"}'::jsonb);
  end if;
  if p_in < v_inst.start_at - make_interval(secs => v_inst.early_entry_seconds)
     or p_out > v_inst.end_at + make_interval(secs => v_inst.checkout_extension_seconds) then
    return jsonb_build_object('errors',
      '{"proposed_in_at":"Times must fall within this shift''s allowed check-in/out window"}'::jsonb);
  end if;
  if p_out > now() then
    return jsonb_build_object('errors', '{"proposed_out_at":"Check-out cannot be in the future"}'::jsonb);
  end if;
  select * into v_sess from hrms.attendance_sessions where schedule_instance_id = v_inst.id;
  return jsonb_build_object('errors', '{}'::jsonb, 'instance_id', v_inst.id, 'session_id', v_sess.id,
    'based_on_revision', coalesce(v_sess.effective_revision, 0), 'shift_date', v_inst.shift_date,
    'start_at', v_inst.start_at, 'end_at', v_inst.end_at);
end;
$$;

-- Applies an approved correction: append an adjustment revision and move the
-- session's effective projection. Original events are never modified.
create or replace function hrms.apply_correction(p_req hrms.requests, p_payload jsonb, p_actor uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inst hrms.work_schedule_instances;
  v_sess hrms.attendance_sessions;
  v_in timestamptz := (p_payload ->> 'proposed_in_at')::timestamptz;
  v_out timestamptz := (p_payload ->> 'proposed_out_at')::timestamptz;
  v_based integer := coalesce((p_payload ->> 'based_on_revision')::integer, 0);
  v_slots integer;
  v_split timestamptz;
begin
  select * into v_inst from hrms.work_schedule_instances
  where employee_id = p_req.employee_id and shift_date = p_req.target_shift_date;

  v_slots := hrms.approved_leave_slots(p_req.employee_id, v_inst.shift_date);
  if v_slots = 3
     or (v_slots = 1 and hrms.overlap_seconds(v_in, v_out, v_inst.start_at, v_inst.half_split_at) > 0)
     or (v_slots = 2 and hrms.overlap_seconds(v_in, v_out, v_inst.half_split_at, v_inst.end_at) > 0) then
    perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
      'This correction overlaps approved leave. Resolve the leave first.');
  end if;

  select * into v_sess from hrms.attendance_sessions where schedule_instance_id = v_inst.id for update;
  if not found then
    if v_based <> 0 then
      perform hrms.raise_error('STALE_VERSION', 'Attendance changed since this correction was submitted.');
    end if;
    insert into hrms.attendance_sessions (org_id, employee_id, schedule_instance_id, shift_date, state,
      effective_in_at, effective_out_at, effective_source, effective_revision)
    values (p_req.org_id, p_req.employee_id, v_inst.id, v_inst.shift_date, 'closed', v_in, v_out, 'manual', 1)
    returning * into v_sess;
    insert into hrms.attendance_adjustments (org_id, employee_id, session_id, revision, based_on_revision,
      effective_in_at, effective_out_at, request_id, approved_by, reason)
    values (p_req.org_id, p_req.employee_id, v_sess.id, 1, 0, v_in, v_out, p_req.id, p_actor,
            coalesce(p_reason, 'Approved correction'));
  else
    if v_sess.effective_revision <> v_based then
      perform hrms.raise_error('STALE_VERSION',
        'Attendance changed since this correction was submitted. Ask the employee to resubmit.');
    end if;
    insert into hrms.attendance_adjustments (org_id, employee_id, session_id, revision, based_on_revision,
      effective_in_at, effective_out_at, request_id, approved_by, reason)
    values (p_req.org_id, p_req.employee_id, v_sess.id, v_sess.effective_revision + 1, v_sess.effective_revision,
            v_in, v_out, p_req.id, p_actor, coalesce(p_reason, 'Approved correction'));
    update hrms.attendance_sessions
       set effective_in_at = v_in, effective_out_at = v_out, state = 'closed',
           needs_correction_reason = null,
           effective_source = case when in_event_id is null and out_event_id is null then 'manual' else 'mixed' end,
           effective_revision = effective_revision + 1, version = version + 1
     where id = v_sess.id;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Owner operations
-- -----------------------------------------------------------------------------

-- Creates/edits/submits a leave request. Editable only while Submitted and
-- unopened by the reviewer, or while Returned. An edit of an unopened
-- Submitted request atomically swaps its reservation; a failed edit leaves
-- the previous revision and reservation untouched (transaction rollback).
create or replace function public.save_leave_request(
  p_request_id uuid,
  p_leave_type_id uuid,
  p_start_date date,
  p_end_date date,
  p_start_slot text,
  p_end_slot text,
  p_reason text,
  p_attachment_file_version_id uuid,
  p_submit boolean,
  p_expected_version integer,
  p_operation_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_type hrms.leave_types;
  v_req hrms.requests;
  v_calc jsonb;
  v_today date := hrms.org_today(v_actor.org_id);
  v_replay jsonb;
  v_hash text;
  v_route jsonb;
  v_prev_state text;
  v_payload jsonb;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_result jsonb;
begin
  v_hash := hrms.sha256_hex(concat_ws('|', p_request_id, p_leave_type_id, p_start_date, p_end_date,
    p_start_slot, p_end_slot, v_reason, p_attachment_file_version_id, p_submit, p_expected_version));
  v_replay := hrms.idem_claim(v_actor.employee_id, v_actor.org_id, 'leave.save', p_operation_key, v_hash);
  if v_replay is not null then return v_replay; end if;

  select * into v_type from hrms.leave_types
  where id = p_leave_type_id and org_id = v_actor.org_id and active;
  if not found then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a leave type.',
      '{"leave_type_id":"Choose an active leave type"}'::jsonb);
  end if;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'leave' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state in ('under_review', 'withdrawal_pending') then
      perform hrms.raise_error('REQUEST_LOCKED',
        'Your approver has opened this request. Contact them for changes.');
    end if;
    if v_req.state not in ('draft', 'submitted', 'returned') then
      perform hrms.raise_error('REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
  end if;

  -- Backdating window applies to past start dates, advance notice to future
  -- ones (both inclusive, server-configured).
  if p_start_date is not null and p_start_date < v_today then
    if p_start_date < v_today - v_type.backdate_days then
      perform hrms.raise_error('VALIDATION_FAILED', 'Too far in the past.', jsonb_build_object('start_date',
        format('Leave can be backdated at most %s days', v_type.backdate_days)));
    end if;
  elsif p_start_date is not null and v_type.advance_notice_days > 0
        and p_start_date < v_today + v_type.advance_notice_days then
    perform hrms.raise_error('VALIDATION_FAILED', 'Needs more notice.', jsonb_build_object('start_date',
      format('Apply at least %s days in advance', v_type.advance_notice_days)));
  end if;

  v_calc := hrms.compute_leave_days(v_actor.org_id, v_actor.employee_id, v_type, p_start_date, p_end_date,
                                    coalesce(p_start_slot, 'FULL'), coalesce(p_end_slot, 'FULL'));
  if v_calc -> 'errors' <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the dates.', v_calc -> 'errors');
  end if;

  if p_submit and v_type.requires_attachment and p_attachment_file_version_id is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'Attach the required document.',
      '{"attachment":"This leave type needs a supporting document"}'::jsonb);
  end if;
  if p_attachment_file_version_id is not null and not exists (
       select 1 from hrms.file_versions fv join hrms.file_records fr on fr.id = fv.file_record_id
       where fv.id = p_attachment_file_version_id and fr.owner_employee_id = v_actor.employee_id
         and fr.class in ('leave_attachment', 'medical_attachment') and fv.state in ('validated', 'published')) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Attachment not found.',
      '{"attachment":"Upload the document again"}'::jsonb);
  end if;

  if hrms.leave_attendance_conflicts(v_actor.employee_id, v_calc -> 'days') > 0 then
    perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
      'You have recorded attendance during this leave. Request a correction or change the dates.');
  end if;

  v_payload := jsonb_build_object(
    'leave_type_id', v_type.id, 'leave_type_code', v_type.code, 'leave_type_name', v_type.name,
    'start_date', p_start_date, 'end_date', p_end_date,
    'start_slot', coalesce(p_start_slot, 'FULL'), 'end_slot', coalesce(p_end_slot, 'FULL'),
    'reason', v_reason, 'attachment_file_version_id', p_attachment_file_version_id,
    'units', (v_calc ->> 'units')::integer, 'days', v_calc -> 'days');

  if p_request_id is null then
    insert into hrms.requests (org_id, employee_id, kind, state, leave_type_id, start_date, end_date, units)
    values (v_actor.org_id, v_actor.employee_id, 'leave', 'draft', v_type.id, p_start_date, p_end_date,
            (v_calc ->> 'units')::integer)
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, 1, v_payload, v_actor.employee_id);
    v_prev_state := 'draft';
  else
    v_prev_state := v_req.state;
    -- Swap: release the old revision's holds, then reserve the new one below.
    if v_req.state = 'submitted' then
      perform hrms.release_request_holds(v_req.id);
    end if;
    update hrms.requests
       set current_revision = current_revision + 1,
           version = version + 1,
           edited = (v_req.state <> 'draft'),
           leave_type_id = v_type.id, start_date = p_start_date, end_date = p_end_date,
           units = (v_calc ->> 'units')::integer
     where id = v_req.id
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
  end if;

  if p_submit then
    perform hrms.reserve_leave(v_actor.org_id, v_actor.employee_id, v_req.id, v_req.current_revision, v_type,
                               v_calc -> 'days');
    if v_prev_state in ('draft', 'returned') then
      v_route := hrms.resolve_reviewer(v_actor.org_id, v_actor.employee_id, 'leave', p_start_date);
      update hrms.requests
         set state = 'submitted', submitted_at = now(), version = version + 1,
             assigned_reviewer_id = case when v_prev_state = 'returned' then assigned_reviewer_id
                                         else (v_route ->> 'reviewer_id')::uuid end,
             route_snapshot = case when v_prev_state = 'returned' then route_snapshot else v_route end
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, case when v_prev_state = 'returned' then 'resubmitted' else 'submitted' end,
                                 v_actor.employee_id, null, v_prev_state, 'submitted');
      if v_req.assigned_reviewer_id is null then
        perform hrms.alert_missing_reviewer(v_req);
      else
        perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.submitted',
          'New leave request to review', 'A team member submitted a leave request.', true);
      end if;
    else
      perform hrms.request_event(v_req, 'edited', v_actor.employee_id, null, v_prev_state, v_req.state);
    end if;
  elsif v_prev_state = 'submitted' then
    perform hrms.raise_error('VALIDATION_FAILED', 'A submitted request can only be saved by submitting it.');
  end if;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_request_id is null then 'leave.created' else 'leave.edited' end, 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'state', v_req.state,
                       'units', v_req.units, 'start_date', p_start_date, 'end_date', p_end_date),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(v_actor.employee_id, 'leave.save', p_operation_key, v_result);
  return v_result;
end;
$$;

-- Creates/edits/submits an attendance correction request.
create or replace function public.save_correction_request(
  p_request_id uuid,
  p_shift_date date,
  p_proposed_in_at timestamptz,
  p_proposed_out_at timestamptz,
  p_reason text,
  p_submit boolean,
  p_expected_version integer,
  p_operation_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_check jsonb;
  v_replay jsonb;
  v_route jsonb;
  v_prev_state text;
  v_payload jsonb;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_result jsonb;
begin
  v_replay := hrms.idem_claim(v_actor.employee_id, v_actor.org_id, 'correction.save', p_operation_key,
    hrms.sha256_hex(concat_ws('|', p_request_id, p_shift_date, p_proposed_in_at, p_proposed_out_at, v_reason,
                              p_submit, p_expected_version)));
  if v_replay is not null then return v_replay; end if;

  if v_reason is null or char_length(v_reason) < 3 then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Explain the correction"}'::jsonb);
  end if;

  if p_request_id is not null then
    select * into v_req from hrms.requests where id = p_request_id for update;
    if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'correction' then
      perform hrms.raise_error('ACCESS_DENIED');
    end if;
    if v_req.state in ('under_review', 'withdrawal_pending') then
      perform hrms.raise_error('REQUEST_LOCKED', 'Your approver has opened this request. Contact them for changes.');
    end if;
    if v_req.state not in ('draft', 'submitted', 'returned') then
      perform hrms.raise_error('REQUEST_LOCKED', 'This request can no longer be edited.');
    end if;
    if v_req.version <> p_expected_version then
      perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
    end if;
  end if;

  v_check := hrms.validate_correction(v_actor, p_shift_date, p_proposed_in_at, p_proposed_out_at);
  if v_check -> 'errors' <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the correction.', v_check -> 'errors');
  end if;

  v_payload := jsonb_build_object(
    'shift_date', p_shift_date, 'schedule_instance_id', v_check -> 'instance_id',
    'session_id', v_check -> 'session_id', 'based_on_revision', (v_check ->> 'based_on_revision')::integer,
    'proposed_in_at', p_proposed_in_at, 'proposed_out_at', p_proposed_out_at, 'reason', v_reason,
    'shift_start_at', v_check -> 'start_at', 'shift_end_at', v_check -> 'end_at');

  if p_request_id is null then
    insert into hrms.requests (org_id, employee_id, kind, state, target_shift_date)
    values (v_actor.org_id, v_actor.employee_id, 'correction', 'draft', p_shift_date)
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, 1, v_payload, v_actor.employee_id);
    v_prev_state := 'draft';
  else
    v_prev_state := v_req.state;
    update hrms.requests
       set current_revision = current_revision + 1, version = version + 1,
           edited = (v_req.state <> 'draft'), target_shift_date = p_shift_date
     where id = v_req.id
    returning * into v_req;
    insert into hrms.request_revisions (request_id, revision_no, payload, created_by)
    values (v_req.id, v_req.current_revision, v_payload, v_actor.employee_id);
  end if;

  if p_submit then
    if v_prev_state in ('draft', 'returned') then
      v_route := hrms.resolve_reviewer(v_actor.org_id, v_actor.employee_id, 'correction', p_shift_date);
      update hrms.requests
         set state = 'submitted', submitted_at = now(), version = version + 1,
             assigned_reviewer_id = case when v_prev_state = 'returned' then assigned_reviewer_id
                                         else (v_route ->> 'reviewer_id')::uuid end,
             route_snapshot = case when v_prev_state = 'returned' then route_snapshot else v_route end
       where id = v_req.id
      returning * into v_req;
      perform hrms.request_event(v_req, case when v_prev_state = 'returned' then 'resubmitted' else 'submitted' end,
                                 v_actor.employee_id, null, v_prev_state, 'submitted');
      if v_req.assigned_reviewer_id is null then
        perform hrms.alert_missing_reviewer(v_req);
      else
        perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.submitted',
          'New attendance correction to review', 'A team member submitted an attendance correction.', true);
      end if;
    else
      perform hrms.request_event(v_req, 'edited', v_actor.employee_id, null, v_prev_state, v_req.state);
    end if;
  elsif v_prev_state = 'submitted' then
    perform hrms.raise_error('VALIDATION_FAILED', 'A submitted request can only be saved by submitting it.');
  end if;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id,
    case when p_request_id is null then 'correction.created' else 'correction.edited' end, 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'state', v_req.state, 'shift_date', p_shift_date),
    'business', v_actor.employee_id);

  v_result := hrms.ok(hrms.request_detail(v_req), v_req.version);
  perform hrms.idem_complete(v_actor.employee_id, 'correction.save', p_operation_key, v_result);
  return v_result;
end;
$$;

-- Owner withdraws: Submitted/Returned/Draft -> Cancelled at once;
-- Under review -> WithdrawalPending (reservation retained until resolved).
create or replace function public.withdraw_request(p_request_id uuid, p_expected_version integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_from text;
  v_reason text := hrms.clean_text(p_reason, 1000);
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found or v_req.employee_id <> v_actor.employee_id then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
  end if;
  v_from := v_req.state;
  if v_req.state in ('draft', 'submitted', 'returned') then
    perform hrms.release_request_holds(v_req.id);
    update hrms.requests set state = 'cancelled', version = version + 1, decided_at = now()
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'withdrawn', v_actor.employee_id, v_reason, v_from, 'cancelled');
  elsif v_req.state = 'under_review' then
    update hrms.requests set state = 'withdrawal_pending', version = version + 1
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'withdrawal_requested', v_actor.employee_id, v_reason, v_from,
                               'withdrawal_pending');
    perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.withdrawal_requested',
      'Withdrawal requested', 'A team member asked to withdraw a request you are reviewing.', true);
  else
    perform hrms.raise_error('REQUEST_LOCKED', 'This request cannot be withdrawn now.');
  end if;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.withdraw', 'request', v_req.id,
    jsonb_build_object('from', v_from, 'to', v_req.state), 'business', v_actor.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

-- Owner asks to cancel APPROVED leave; the debit stays until approved.
create or replace function public.request_leave_cancellation(
  p_request_id uuid, p_expected_version integer, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_reason text := hrms.clean_text(p_reason, 1000);
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found or v_req.employee_id <> v_actor.employee_id or v_req.kind <> 'leave' then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_req.state <> 'approved' then
    perform hrms.raise_error('REQUEST_LOCKED', 'Only approved leave can be cancelled this way.');
  end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload and try again.', null, true);
  end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  update hrms.requests set state = 'cancellation_pending', version = version + 1
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req, 'cancellation_requested', v_actor.employee_id, v_reason, 'approved',
                             'cancellation_pending');
  perform hrms.notify_request(v_req, v_req.assigned_reviewer_id, 'request.cancellation_requested',
    'Leave cancellation requested', 'A team member asked to cancel approved leave.', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave.cancellation_requested', 'request', v_req.id,
    null, 'business', v_actor.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

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
  select coalesce(jsonb_agg(hrms.request_summary(r) order by r.created_at desc, r.id desc), '[]'::jsonb)
    into v_rows
  from (
    select * from hrms.requests r
    where r.employee_id = v_actor.employee_id
      and (p_kind is null or r.kind = p_kind)
      and (p_state is null or r.state = p_state)
      and (p_before_created_at is null or (r.created_at, r.id) < (p_before_created_at, p_before_id))
    order by r.created_at desc, r.id desc
    limit v_limit
  ) r;
  return hrms.ok(v_rows);
end;
$$;

-- Owner read path: full own detail without creating a reviewer lock.
create or replace function public.get_my_request(p_request_id uuid) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
begin
  select * into v_req from hrms.requests where id = p_request_id;
  if not found or v_req.employee_id <> v_actor.employee_id then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

-- -----------------------------------------------------------------------------
-- Reviewer operations
-- -----------------------------------------------------------------------------

-- Reviewer may act if assigned (and not the requester), or is an Admin acting
-- as fallback/override (never on their own request). Returns 'assigned' |
-- 'admin' | null.
create or replace function hrms.review_authority(p_actor hrms.actor, p_req hrms.requests) returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_req.org_id <> p_actor.org_id or p_req.employee_id = p_actor.employee_id then null
    when p_req.assigned_reviewer_id = p_actor.employee_id then 'assigned'
    when hrms.is_admin(p_actor) then 'admin'
    else null end;
$$;

-- Queue: minimal projection only. Listing never locks.
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
  select coalesce(jsonb_agg(hrms.request_summary(r) order by r.submitted_at desc, r.id desc), '[]'::jsonb)
    into v_rows
  from (
    select * from hrms.requests r
    where r.org_id = v_actor.org_id
      and r.employee_id <> v_actor.employee_id
      and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')
      and (p_state is null or r.state = p_state)
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

-- Atomic first-review lock: authorise, lock the CURRENT revision, audit, and
-- return exactly that revision's detail in one transaction. If the owner's
-- edit committed first, the reviewer receives and locks the newer version; if
-- this lock wins, the owner's edit fails with REQUEST_LOCKED.
create or replace function public.open_request_for_review(p_request_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_authority text;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_balance jsonb;
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  v_authority := hrms.review_authority(v_actor, v_req);
  if v_authority is null then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_authority = 'admin' and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required to review as Admin fallback.',
      '{"reason":"Required for Admin override"}'::jsonb);
  end if;

  if v_req.state = 'submitted' then
    update hrms.requests
       set state = 'under_review', locked_revision = current_revision,
           first_opened_at = coalesce(first_opened_at, now()),
           first_opened_by = coalesce(first_opened_by, v_actor.employee_id),
           version = version + 1
     where id = v_req.id
    returning * into v_req;
    perform hrms.request_event(v_req, 'opened', v_actor.employee_id, v_reason, 'submitted', 'under_review');
  end if;

  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.review_opened', 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'authority', v_authority, 'reason', v_reason),
    'access', v_req.employee_id);

  if v_req.kind = 'leave' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'leave_year', acc.leave_year, 'available', av.available, 'valid_to', av.valid_to)), '[]'::jsonb)
      into v_balance
    from hrms.leave_accounts acc
    cross join lateral hrms.allocation_availability(array[acc.id]) av
    where acc.employee_id = v_req.employee_id and acc.leave_type_id = v_req.leave_type_id
      and acc.leave_year >= extract(year from v_req.start_date)::integer - 1;
  end if;

  return hrms.ok(hrms.request_detail(v_req) || jsonb_build_object(
    'authority', v_authority, 'balance', v_balance,
    'attendance_conflicts', case when v_req.kind = 'leave' then hrms.leave_attendance_conflicts(
       v_req.employee_id, (select payload -> 'days' from hrms.request_revisions
                           where request_id = v_req.id and revision_no = v_req.current_revision)) end),
    v_req.version);
end;
$$;

-- Approve / reject / return. Compare-and-swap on state + version: concurrent
-- decisions have exactly one winner; the loser gets STALE_VERSION.
create or replace function public.decide_request(
  p_request_id uuid, p_decision text, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_authority text;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_payload jsonb;
  v_to text;
begin
  if p_decision not in ('approve', 'reject', 'return') then
    perform hrms.raise_error('VALIDATION_FAILED', 'Unknown decision');
  end if;
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_req.employee_id = v_actor.employee_id then
    perform hrms.raise_error('SELF_APPROVAL_FORBIDDEN', 'You cannot decide your own request.');
  end if;
  v_authority := hrms.review_authority(v_actor, v_req);
  if v_authority is null then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  if v_req.state <> 'under_review' or v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it before deciding.', null, true);
  end if;
  if (p_decision in ('reject', 'return') or v_authority = 'admin') and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;

  select payload into v_payload from hrms.request_revisions
  where request_id = v_req.id and revision_no = v_req.current_revision;

  if p_decision = 'approve' then
    if v_req.kind = 'leave' then
      if hrms.leave_attendance_conflicts(v_req.employee_id, v_payload -> 'days') > 0 then
        perform hrms.raise_error('LEAVE_ATTENDANCE_CONFLICT',
          'Attendance was recorded during this leave. Return it for correction instead.');
      end if;
      perform hrms.debit_request(v_req.id, v_req.current_revision, v_actor.employee_id);
    else
      perform hrms.apply_correction(v_req, v_payload, v_actor.employee_id, v_reason);
    end if;
    v_to := 'approved';
  elsif p_decision = 'reject' then
    perform hrms.release_request_holds(v_req.id);
    v_to := 'rejected';
  else
    perform hrms.release_request_holds(v_req.id);
    v_to := 'returned';
  end if;

  update hrms.requests
     set state = v_to, version = version + 1, decided_at = now(), decided_by = v_actor.employee_id,
         approved_revision = case when v_to = 'approved' then current_revision else approved_revision end
   where id = v_req.id
  returning * into v_req;
  perform hrms.request_event(v_req, case p_decision when 'approve' then 'approved' when 'reject' then 'rejected'
                                    else 'returned' end,
                             v_actor.employee_id, v_reason, 'under_review', v_to);
  perform hrms.notify_request(v_req, v_req.employee_id, 'request.' || v_to,
    case v_to when 'approved' then 'Request approved' when 'rejected' then 'Request not approved'
              else 'Request returned for changes' end,
    case v_to when 'returned' then 'Your approver asked for changes. Open the request to update it.'
              else 'Open the app to see the details.' end, false);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.' || p_decision, 'request', v_req.id,
    jsonb_build_object('revision', v_req.current_revision, 'authority', v_authority, 'reason', v_reason),
    'business', v_req.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

-- Reviewer accepts/declines a pending withdrawal.
create or replace function public.resolve_withdrawal(
  p_request_id uuid, p_accept boolean, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_authority text;
  v_reason text := hrms.clean_text(p_reason, 1000);
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  v_authority := hrms.review_authority(v_actor, v_req);
  if v_authority is null then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.state <> 'withdrawal_pending' or v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if (not p_accept or v_authority = 'admin') and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if p_accept then
    perform hrms.release_request_holds(v_req.id);
    update hrms.requests set state = 'cancelled', version = version + 1, decided_at = now(),
                             decided_by = v_actor.employee_id
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'withdrawal_accepted', v_actor.employee_id, v_reason,
                               'withdrawal_pending', 'cancelled');
  else
    update hrms.requests set state = 'under_review', version = version + 1
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'withdrawal_declined', v_actor.employee_id, v_reason,
                               'withdrawal_pending', 'under_review');
  end if;
  perform hrms.notify_request(v_req, v_req.employee_id, 'request.withdrawal_' ||
    case when p_accept then 'accepted' else 'declined' end,
    case when p_accept then 'Withdrawal accepted' else 'Withdrawal declined' end,
    'Open the app to see the details.', false);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.withdrawal_resolved', 'request', v_req.id,
    jsonb_build_object('accepted', p_accept, 'reason', v_reason), 'business', v_req.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

-- Reviewer approves/declines cancellation of approved leave. Approval credits
-- the original allocations exactly once; declining restores Approved as-is.
create or replace function public.resolve_cancellation(
  p_request_id uuid, p_accept boolean, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_authority text;
  v_reason text := hrms.clean_text(p_reason, 1000);
begin
  select * into v_req from hrms.requests where id = p_request_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.employee_id = v_actor.employee_id then
    perform hrms.raise_error('SELF_APPROVAL_FORBIDDEN', 'You cannot decide your own request.');
  end if;
  v_authority := hrms.review_authority(v_actor, v_req);
  if v_authority is null then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.state <> 'cancellation_pending' or v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if (not p_accept or v_authority = 'admin') and v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  if p_accept then
    perform hrms.credit_back_request(v_req.id, v_req.approved_revision, v_actor.employee_id);
    update hrms.requests set state = 'cancelled', version = version + 1, decided_at = now(),
                             decided_by = v_actor.employee_id
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'cancellation_approved', v_actor.employee_id, v_reason,
                               'cancellation_pending', 'cancelled');
  else
    update hrms.requests set state = 'approved', version = version + 1
    where id = v_req.id returning * into v_req;
    perform hrms.request_event(v_req, 'cancellation_declined', v_actor.employee_id, v_reason,
                               'cancellation_pending', 'approved');
  end if;
  perform hrms.notify_request(v_req, v_req.employee_id, 'request.cancellation_' ||
    case when p_accept then 'approved' else 'declined' end,
    case when p_accept then 'Leave cancellation approved' else 'Leave cancellation declined' end,
    'Open the app to see the details.', false);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'leave.cancellation_resolved', 'request', v_req.id,
    jsonb_build_object('accepted', p_accept, 'reason', v_reason), 'business', v_req.employee_id);
  return hrms.ok(hrms.request_detail(v_req), v_req.version);
end;
$$;

-- Admin reassigns a pending request with a reason. The old assignee loses
-- action rights immediately; requests never silently reroute on team changes.
create or replace function public.reassign_request(
  p_request_id uuid, p_new_reviewer_id uuid, p_reason text, p_expected_version integer
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_req hrms.requests;
  v_reason text := hrms.clean_text(p_reason, 1000);
  v_old uuid;
begin
  if not hrms.is_admin(v_actor) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_reason is null then
    perform hrms.raise_error('VALIDATION_FAILED', 'A reason is required.', '{"reason":"Required"}'::jsonb);
  end if;
  select * into v_req from hrms.requests where id = p_request_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_req.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'This request changed. Reload it.', null, true);
  end if;
  if v_req.state not in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending') then
    perform hrms.raise_error('REQUEST_LOCKED', 'Only pending requests can be reassigned.');
  end if;
  if not hrms.is_eligible_reviewer(p_new_reviewer_id, v_req.employee_id) then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose an eligible approver other than the requester.',
      '{"reviewer_id":"Not an eligible approver"}'::jsonb);
  end if;
  v_old := v_req.assigned_reviewer_id;
  update hrms.requests set assigned_reviewer_id = p_new_reviewer_id, version = version + 1,
         route_snapshot = coalesce(route_snapshot, '{}'::jsonb)
                          || jsonb_build_object('reassigned_from', v_old, 'reassigned_by', v_actor.employee_id)
  where id = v_req.id returning * into v_req;
  perform hrms.request_event(v_req, 'reassigned', v_actor.employee_id, v_reason, v_req.state, v_req.state);
  perform hrms.notify_request(v_req, p_new_reviewer_id, 'request.reassigned', 'Request assigned to you',
    'A request was assigned to you for review.', true);
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'request.reassigned', 'request', v_req.id,
    jsonb_build_object('from', v_old, 'to', p_new_reviewer_id, 'reason', v_reason), 'business', v_req.employee_id);
  return hrms.ok(hrms.request_summary(v_req), v_req.version);
end;
$$;

-- Leave balances per type for a leave year (default: current).
create or replace function public.get_leave_balances(p_leave_year integer default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_year integer;
  v_rows jsonb;
begin
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  v_year := coalesce(p_leave_year, hrms.leave_year_of(v_org.leave_year_start_month, hrms.org_today(v_org.id)));
  with acc as (
    select a.* from hrms.leave_accounts a
    where a.employee_id = v_actor.employee_id and a.leave_year = v_year
  ),
  ledger as (
    select l.account_id,
           sum(l.units) filter (where l.entry_kind = 'allocate') as allocated,
           -sum(l.units) filter (where l.entry_kind = 'debit') as debited,
           sum(l.units) filter (where l.entry_kind = 'credit_back') as credited_back,
           -sum(l.units) filter (where l.entry_kind = 'expire') as expired,
           sum(l.units) filter (where l.entry_kind = 'adjust') as adjusted
    from hrms.leave_ledger l where l.account_id in (select id from acc)
    group by l.account_id
  ),
  reserved as (
    select r.account_id, sum(r.units) as reserved from hrms.leave_reservations r
    where r.account_id in (select id from acc) and r.state = 'active' group by r.account_id
  ),
  avail as (
    select av.account_id,
           sum(av.available) filter (where av.valid_to > hrms.org_today(v_org.id)) as available
    from hrms.allocation_availability(array(select id from acc)) av
    group by av.account_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'leave_type', jsonb_build_object('id', t.id, 'code', t.code, 'name', t.name, 'paid', t.paid,
                                            'half_day_allowed', t.half_day_allowed,
                                            'requires_attachment', t.requires_attachment),
           'leave_year', v_year,
           'allocated_units', coalesce(l.allocated, 0) + coalesce(l.adjusted, 0),
           'used_units', coalesce(l.debited, 0) - coalesce(l.credited_back, 0),
           'reserved_units', coalesce(r.reserved, 0),
           'expired_units', coalesce(l.expired, 0),
           'available_units', case when t.paid then coalesce(av.available, 0) else null end
         ) order by t.name), '[]'::jsonb)
    into v_rows
  from hrms.leave_types t
  left join acc a on a.leave_type_id = t.id
  left join ledger l on l.account_id = a.id
  left join reserved r on r.account_id = a.id
  left join avail av on av.account_id = a.id
  where t.org_id = v_actor.org_id and t.active;
  return hrms.ok(jsonb_build_object('leave_year', v_year, 'balances', v_rows,
                                    'leave_year_start_month', v_org.leave_year_start_month));
end;
$$;

-- Preview units + balance impact before submitting (no reservation).
create or replace function public.preview_leave(
  p_leave_type_id uuid, p_start_date date, p_end_date date, p_start_slot text, p_end_slot text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_type hrms.leave_types;
  v_calc jsonb;
  v_conflicts integer;
begin
  select * into v_type from hrms.leave_types where id = p_leave_type_id and org_id = v_actor.org_id and active;
  if not found then
    perform hrms.raise_error('VALIDATION_FAILED', 'Choose a leave type.', '{"leave_type_id":"Required"}'::jsonb);
  end if;
  v_calc := hrms.compute_leave_days(v_actor.org_id, v_actor.employee_id, v_type, p_start_date, p_end_date,
                                    coalesce(p_start_slot, 'FULL'), coalesce(p_end_slot, 'FULL'));
  if v_calc -> 'errors' <> '{}'::jsonb then
    return hrms.ok(jsonb_build_object('valid', false, 'errors', v_calc -> 'errors'));
  end if;
  v_conflicts := hrms.leave_attendance_conflicts(v_actor.employee_id, v_calc -> 'days');
  return hrms.ok(jsonb_build_object(
    'valid', v_conflicts = 0, 'units', v_calc -> 'units',
    'days', (select jsonb_agg(jsonb_build_object('day', d -> 'day', 'slot', d -> 'slot', 'units', d -> 'units',
                                                 'start_at', d -> 'start_at', 'split_at', d -> 'split_at',
                                                 'end_at', d -> 'end_at'))
             from jsonb_array_elements(v_calc -> 'days') d),
    'attendance_conflicts', v_conflicts,
    'errors', case when v_conflicts > 0 then
      '{"start_date":"You have recorded attendance during these dates"}'::jsonb else '{}'::jsonb end));
end;
$$;

do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'hrms' loop
    execute format('alter table hrms.%I enable row level security', r.tablename);
  end loop;
end $$;

select hrms.apply_api_grants();
