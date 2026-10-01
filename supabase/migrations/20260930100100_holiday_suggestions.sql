-- =============================================================================
-- Holiday suggestions (owner decision 2026-09-30). A monthly job reads a
-- public holiday calendar feed and stores SUGGESTIONS only. Nothing is ever
-- published automatically: Admin/HR reviews each suggestion and adds it as a
-- draft holiday, which an Admin then publishes (architecture §6: "API import
-- is suggestion-only and deduplicated by date/scope; manual calendar works
-- without API"). The feed is not a legal holiday list.
-- =============================================================================

create table hrms.holiday_suggestions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references hrms.organizations(id) on delete restrict,
  holiday_date date not null,
  name text not null check (char_length(name) between 1 and 120),
  category text check (char_length(category) <= 60),
  source text not null check (char_length(source) between 1 and 40),
  source_uid text check (char_length(source_uid) <= 200),
  state text not null default 'new' check (state in ('new', 'added', 'dismissed')),
  holiday_id uuid references hrms.holidays(id) on delete restrict,
  fetched_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  unique (org_id, holiday_date, name)
);
create index holiday_suggestions_org_date_idx on hrms.holiday_suggestions (org_id, holiday_date);
alter table hrms.holiday_suggestions enable row level security;

-- Stores parsed feed items for every organisation (or one, when p_org_id is
-- given for an on-demand refresh). Past dates and oversized input are
-- ignored; existing suggestions (any state) are never duplicated or revived.
create or replace function public.internal_store_holiday_suggestions(p_org_id uuid, p_source text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org record;
  v_added integer := 0;
  v_count integer;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then
    perform hrms.raise_error('VALIDATION_FAILED', 'Invalid holiday feed.');
  end if;
  for v_org in select id from hrms.organizations where p_org_id is null or id = p_org_id loop
    insert into hrms.holiday_suggestions (org_id, holiday_date, name, category, source, source_uid)
    select v_org.id, x.day, hrms.clean_text(x.name, 120), hrms.clean_text(x.category, 60), left(p_source, 40),
           hrms.clean_text(x.uid, 200)
    from jsonb_to_recordset(p_items) as x(day date, name text, category text, uid text)
    where x.day >= hrms.org_today(v_org.id) and x.day <= hrms.org_today(v_org.id) + 550
      and hrms.clean_text(x.name, 120) is not null
    on conflict (org_id, holiday_date, name) do nothing;
    get diagnostics v_count = row_count;
    v_added := v_added + v_count;
  end loop;
  insert into hrms.maintenance_runs (kind, finished_at, ok, detail)
  values ('holidays', now(), true, jsonb_build_object('added', v_added, 'source', left(p_source, 40)));
  return jsonb_build_object('added', v_added);
end;
$$;

create or replace function public.internal_holiday_refresh_due() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (select 1 from hrms.maintenance_runs where kind = 'holidays' and started_at > now() - interval '25 days');
$$;

create or replace function public.list_holiday_suggestions(p_year integer default null) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  return hrms.ok(jsonb_build_object(
    'last_fetched_at', (select max(started_at) from hrms.maintenance_runs where kind = 'holidays'),
    'suggestions', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'date', s.holiday_date, 'name', s.name, 'category', s.category, 'source', s.source,
        'state', s.state, 'holiday_id', s.holiday_id,
        'existing_holiday', (select jsonb_build_object('id', h.id, 'name', h.name, 'state', h.state)
                             from hrms.holidays h where h.org_id = s.org_id and h.holiday_date = s.holiday_date
                               and h.state <> 'withdrawn' and h.office_id is null limit 1))
        order by s.holiday_date, s.name), '[]'::jsonb)
      from hrms.holiday_suggestions s
      where s.org_id = v_actor.org_id and s.holiday_date >= hrms.org_today(v_actor.org_id)
        and (p_year is null or extract(year from s.holiday_date) = p_year))));
end;
$$;

-- Adds the suggestion as a DRAFT holiday (Admin publishes it separately).
create or replace function public.add_holiday_from_suggestion(p_id uuid, p_office_id uuid default null) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_s hrms.holiday_suggestions;
  v_h hrms.holidays;
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  select * into v_s from hrms.holiday_suggestions where id = p_id and org_id = v_actor.org_id for update;
  if not found then perform hrms.raise_error('ACCESS_DENIED'); end if;
  if v_s.state = 'added' then
    return hrms.ok(jsonb_build_object('holiday_id', v_s.holiday_id, 'already', true));
  end if;
  if p_office_id is not null and not exists (select 1 from hrms.offices where id = p_office_id and org_id = v_actor.org_id) then
    perform hrms.raise_error('ACCESS_DENIED');
  end if;
  begin
    insert into hrms.holidays (org_id, office_id, holiday_date, name, state, source, created_by)
    values (v_actor.org_id, p_office_id, v_s.holiday_date, v_s.name, 'draft', 'import', v_actor.employee_id)
    returning * into v_h;
  exception when unique_violation then
    perform hrms.raise_error('VALIDATION_FAILED', 'A holiday already exists on this date for this scope.',
      '{"date":"Already has a holiday"}'::jsonb);
  end;
  update hrms.holiday_suggestions set state = 'added', holiday_id = v_h.id, decided_by = v_actor.employee_id,
                                      decided_at = now()
  where id = v_s.id;
  perform hrms.audit(v_actor.org_id, v_actor.employee_id, 'holiday.draft_from_suggestion', 'holiday', v_h.id,
    jsonb_build_object('date', v_h.holiday_date, 'name', v_h.name, 'source', v_s.source));
  return hrms.ok(jsonb_build_object('holiday_id', v_h.id, 'already', false));
end;
$$;

create or replace function public.dismiss_holiday_suggestion(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  if not (hrms.is_admin(v_actor) or hrms.can_draft_policy(v_actor)) then perform hrms.raise_error('ACCESS_DENIED'); end if;
  update hrms.holiday_suggestions set state = 'dismissed', decided_by = v_actor.employee_id, decided_at = now()
  where id = p_id and org_id = v_actor.org_id and state = 'new';
  return hrms.ok(jsonb_build_object('dismissed', found));
end;
$$;

-- Monthly fetch through the maintenance function (hosted Supabase only).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hrms-holidays';
    perform cron.schedule('hrms-holidays', '40 21 * * *',
      $cron$ select hrms.cron_invoke('holidays') where public.internal_holiday_refresh_due() $cron$);
  end if;
end $$;

select hrms.apply_api_grants();
