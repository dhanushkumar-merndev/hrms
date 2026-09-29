-- =============================================================================
-- Background work inside Supabase (architecture.md §10.1).
-- pg_cron wakes the `maintenance` Edge Function through pg_net only when work
-- is due; the function authenticates with a shared secret stored in Vault.
-- Jobs claim bounded batches with row locks + SKIP LOCKED and a lease, and
-- never hold a transaction open across network I/O. Correctness never
-- depends on cron: punches and reads roll stale sessions over lazily.
-- =============================================================================

create table hrms.maintenance_runs (
  id bigint generated always as identity primary key,
  kind text not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  ok boolean,
  detail jsonb
);
create index maintenance_runs_kind_idx on hrms.maintenance_runs (kind, started_at desc);
alter table hrms.maintenance_runs enable row level security;

-- Periodic housekeeping (every 15 minutes). Returns storage objects the
-- Edge Function must delete (abandoned staging uploads and orphaned finals).
create or replace function public.internal_maintenance_tick() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint;
  v_rolled integer;
  v_staging jsonb;
  v_finals jsonb;
  v_expired integer;
  v_org record;
begin
  insert into hrms.maintenance_runs (kind) values ('tick') returning id into v_run;

  delete from hrms.punch_challenges where expires_at < now() - interval '1 day';
  delete from hrms.device_challenges where expires_at < now() - interval '1 day';

  -- Abandoned uploads: release exactly their own reservation (no full scan).
  with expired as (
    select v.id, v.org_id, v.reserved_bytes, v.staging_object_key, v.object_key
    from hrms.file_versions v
    where (v.state = 'requested' and v.upload_expires_at < now() - interval '5 minutes')
       or (v.state = 'quarantined' and v.created_at < now() - interval '1 hour')
    order by v.id
    limit 200
    for update skip locked
  ),
  upd as (
    update hrms.file_versions v
       set state = 'rejected', validation_error = 'Upload expired before completion', reserved_bytes = 0
      from expired e where v.id = e.id
    returning e.org_id, e.reserved_bytes, e.staging_object_key, e.object_key
  ),
  led as (
    update hrms.storage_ledger l set reserved_bytes = greatest(0, l.reserved_bytes - x.total), updated_at = now()
      from (select org_id, sum(reserved_bytes) as total from upd group by org_id) x
     where l.org_id = x.org_id
    returning l.org_id
  )
  select coalesce(jsonb_agg(staging_object_key) filter (where staging_object_key is not null), '[]'::jsonb),
         coalesce(jsonb_agg(object_key) filter (where object_key is not null), '[]'::jsonb),
         count(*)
    into v_staging, v_finals, v_expired
  from upd;

  -- Org-wide rollover of stale open sessions (set based, no fabricated OUT).
  update hrms.attendance_sessions s
     set state = 'needs_correction', needs_correction_reason = 'missing_out', version = s.version + 1
    from hrms.work_schedule_instances w
   where s.state = 'open' and w.id = s.schedule_instance_id
     and w.end_at + make_interval(secs => w.checkout_extension_seconds) < now();
  get diagnostics v_rolled = row_count;

  -- Materialise today + tomorrow for active employees (one statement per org).
  for v_org in select id from hrms.organizations loop
    perform hrms.ensure_schedule_instances(v_org.id, hrms.active_employee_ids(v_org.id),
                                           hrms.org_today(v_org.id), hrms.org_today(v_org.id) + 1);
  end loop;

  -- Bounded retention for transient security/rate data.
  perform set_config('hrms.retention_purge', 'on', true);
  delete from hrms.rate_limit_buckets where window_start < now() - interval '1 day';
  delete from hrms.security_events where created_at < now() - interval '180 days';
  perform set_config('hrms.retention_purge', 'off', true);
  delete from hrms.punch_rejections where created_at < now() - interval '180 days';
  delete from hrms.idempotency_records where created_at < now() - interval '30 days';

  update hrms.maintenance_runs set finished_at = now(), ok = true,
    detail = jsonb_build_object('rolled_over_sessions', v_rolled, 'expired_uploads', v_expired)
  where id = v_run;
  return jsonb_build_object('run_id', v_run, 'staging_keys', v_staging, 'final_keys', v_finals,
                            'rolled_over_sessions', v_rolled, 'expired_uploads', v_expired);
end;
$$;

-- Daily: reconcile approximate byte accounting against file versions (one
-- grouped pass per org) and record the run.
create or replace function public.internal_maintenance_daily() returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run bigint;
begin
  insert into hrms.maintenance_runs (kind) values ('daily') returning id into v_run;
  insert into hrms.storage_ledger (org_id) select id from hrms.organizations on conflict (org_id) do nothing;
  update hrms.storage_ledger l
     set reserved_bytes = coalesce(x.reserved, 0), used_bytes = coalesce(x.used, 0), updated_at = now()
    from (select o.id as org_id,
                 sum(v.reserved_bytes) filter (where v.state in ('requested', 'quarantined')) as reserved,
                 sum(v.size_bytes) filter (where v.state in ('validated', 'published', 'superseded', 'archived',
                                                             'deletion_pending')) as used
          from hrms.organizations o left join hrms.file_versions v on v.org_id = o.id
          group by o.id) x
   where l.org_id = x.org_id;
  perform hrms.daily_extras();
  update hrms.maintenance_runs set finished_at = now(), ok = true where id = v_run;
  return jsonb_build_object('run_id', v_run);
end;
$$;

-- Extension point (annual export obligations are added by the exports migration).
create or replace function hrms.daily_extras() returns void
language sql security definer set search_path = '' as $$ select; $$;

-- Cheap SQL check so an empty queue never costs an Edge invocation.
create or replace function public.internal_outbox_has_due() returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from hrms.outbox where status in ('pending', 'sending') and next_attempt_at <= now()
                 and (lease_until is null or lease_until < now()));
$$;

-- Claims at most p_limit due push jobs under a lease (SKIP LOCKED: two
-- concurrent workers never claim the same job).
create or replace function public.internal_claim_outbox(p_limit integer default 50, p_lease_seconds integer default 60)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_jobs jsonb;
begin
  with due as (
    select o.id from hrms.outbox o
    where o.status in ('pending', 'sending') and o.next_attempt_at <= now()
      and (o.lease_until is null or o.lease_until < now())
    order by o.next_attempt_at, o.id
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
    for update skip locked
  ),
  claimed as (
    update hrms.outbox o set status = 'sending', attempts = o.attempts + 1,
           lease_until = now() + make_interval(secs => least(greatest(coalesce(p_lease_seconds, 60), 10), 300))
    from due where o.id = due.id
    returning o.id, o.notification_id, o.attempts
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'outbox_id', c.id, 'attempts', c.attempts,
      'event_id', n.event_id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'deep_link', n.deep_link,
      'notification_id', n.id,
      'tokens', (select coalesce(jsonb_agg(jsonb_build_object('token', t.token, 'platform', t.platform)), '[]'::jsonb)
                 from hrms.push_tokens t where t.employee_id = n.recipient_id and t.revoked_at is null))), '[]'::jsonb)
    into v_jobs
  from claimed c join hrms.notifications n on n.id = c.notification_id;
  return v_jobs;
end;
$$;

-- Records delivery outcomes: sent | retry | failed | skipped (no tokens).
-- Retries use bounded exponential backoff; invalid tokens are revoked.
create or replace function public.internal_complete_outbox(p_results jsonb) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_done integer := 0;
begin
  for r in select * from jsonb_to_recordset(coalesce(p_results, '[]'::jsonb))
             as x(outbox_id bigint, outcome text, error text, invalid_tokens jsonb)
  loop
    update hrms.outbox o set
      status = case
        when r.outcome in ('sent', 'skipped') then r.outcome
        when r.outcome = 'retry' and o.attempts < 8 then 'pending'
        else 'failed' end,
      next_attempt_at = case when r.outcome = 'retry'
        then now() + make_interval(secs => least(3600, 30 * power(2, least(o.attempts, 7))::integer)) else o.next_attempt_at end,
      lease_until = null,
      last_error = left(r.error, 300)
    where o.id = r.outbox_id;
    if r.invalid_tokens is not null then
      update hrms.push_tokens set revoked_at = now()
      where revoked_at is null and token in (select jsonb_array_elements_text(r.invalid_tokens));
    end if;
    v_done := v_done + 1;
  end loop;
  insert into hrms.maintenance_runs (kind, finished_at, ok, detail)
  values ('outbox', now(), true, jsonb_build_object('completed', v_done));
  return jsonb_build_object('completed', v_done);
end;
$$;

create or replace function public.get_maintenance_health() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
begin
  perform hrms.require_admin(v_actor);
  return hrms.ok(jsonb_build_object(
    'last_tick', (select jsonb_build_object('at', started_at, 'ok', ok, 'detail', detail) from hrms.maintenance_runs
                  where kind = 'tick' order by started_at desc limit 1),
    'last_outbox', (select jsonb_build_object('at', started_at, 'ok', ok, 'detail', detail) from hrms.maintenance_runs
                    where kind = 'outbox' order by started_at desc limit 1),
    'outbox_backlog', (select count(*) from hrms.outbox where status in ('pending', 'sending') and org_id = v_actor.org_id),
    'outbox_failed', (select count(*) from hrms.outbox where status = 'failed' and org_id = v_actor.org_id),
    'pending_uploads', (select count(*) from hrms.file_versions where state in ('requested', 'quarantined')
                          and org_id = v_actor.org_id),
    'stale', coalesce((select started_at < now() - interval '1 hour' from hrms.maintenance_runs
                       where kind = 'tick' order by started_at desc limit 1), true)));
end;
$$;

-- Admin tasks shown on Home/workspace (maintenance health; archive tasks are
-- appended by the exports migration).
create or replace function hrms.admin_tasks(p_org uuid) returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(t), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'maintenance_stale',
                              'title', 'Background maintenance has not run recently') as t
    where coalesce((select started_at < now() - interval '1 hour' from hrms.maintenance_runs
                    where kind = 'tick' order by started_at desc limit 1), true)
    union all
    select jsonb_build_object('kind', 'reviewer_missing', 'title', 'Requests waiting for an approver',
                              'count', count(*))
    from hrms.requests r where r.org_id = p_org and r.assigned_reviewer_id is null
      and r.state in ('submitted', 'under_review', 'withdrawal_pending', 'cancellation_pending')
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'storage', 'title', 'Storage use is high',
                              'percent', round(100.0 * l.used_bytes / o.storage_budget_bytes))
    from hrms.storage_ledger l join hrms.organizations o on o.id = l.org_id
    where l.org_id = p_org and l.used_bytes * 100 >= o.storage_budget_bytes * o.storage_alert_percents[1]
  ) s;
$$;

-- -----------------------------------------------------------------------------
-- Scheduler wiring (hosted Supabase only; skipped where extensions are absent)
-- -----------------------------------------------------------------------------

-- Invokes the maintenance Edge Function. The URL and secret come from Vault
-- (created by tool/deploy.dart); without them this is a no-op.
create or replace function hrms.cron_invoke(p_kind text) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    return;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_url using 'hrms_functions_url';
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1' into v_secret using 'hrms_maintenance_secret';
  if v_url is null or v_secret is null then
    return;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 25000)'
  using v_url || '/maintenance', jsonb_build_object('kind', p_kind),
        jsonb_build_object('Content-Type', 'application/json', 'x-hrms-maintenance-secret', v_secret);
end;
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
    create extension if not exists pg_cron;
    perform cron.unschedule(jobid) from cron.job where jobname in ('hrms-outbox', 'hrms-tick', 'hrms-daily');
    perform cron.schedule('hrms-outbox', '* * * * *',
      $cron$ select hrms.cron_invoke('outbox') where public.internal_outbox_has_due() $cron$);
    perform cron.schedule('hrms-tick', '*/15 * * * *', $cron$ select hrms.cron_invoke('tick') $cron$);
    perform cron.schedule('hrms-daily', '17 21 * * *', $cron$ select hrms.cron_invoke('daily') $cron$);
  end if;
end $$;

select hrms.apply_api_grants();
