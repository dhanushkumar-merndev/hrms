-- =============================================================================
-- Notifications: exactly-once in-app inbox rows + at-least-once push outbox
-- (architecture.md §7.2). Business transactions insert the inbox row and the
-- outbox job; the maintenance runner delivers push after commit. Push failure
-- never rolls back attendance or leave.
-- =============================================================================

create table hrms.notifications (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  recipient_id uuid not null,
  event_id uuid not null,
  kind text not null check (char_length(kind) <= 60),
  title text not null check (char_length(title) between 1 and 120),
  body text check (char_length(body) <= 500),
  deep_link text check (char_length(deep_link) <= 200),
  data jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (recipient_id, event_id),
  foreign key (org_id, recipient_id) references hrms.employees(org_id, id) on delete restrict
);
create index notifications_recipient_idx on hrms.notifications (recipient_id, created_at desc, id desc);
create index notifications_unread_idx on hrms.notifications (recipient_id) where read_at is null;

create table hrms.push_tokens (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  employee_id uuid not null,
  installation_id uuid not null,
  token text not null check (char_length(token) between 20 and 4096),
  platform text not null check (platform in ('android', 'ios')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  foreign key (org_id, employee_id) references hrms.employees(org_id, id) on delete restrict
);
create unique index push_tokens_active_installation on hrms.push_tokens (installation_id) where revoked_at is null;
create unique index push_tokens_active_token on hrms.push_tokens (token) where revoked_at is null;
create index push_tokens_emp_idx on hrms.push_tokens (employee_id) where revoked_at is null;

create table hrms.outbox (
  id bigint generated always as identity primary key,
  org_id uuid not null,
  notification_id uuid not null references hrms.notifications(id) on delete restrict,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  last_error text check (char_length(last_error) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (notification_id)
);
create index outbox_due_idx on hrms.outbox (next_attempt_at, id) where status in ('pending', 'sending');
create trigger outbox_touch before update on hrms.outbox
  for each row execute function hrms.touch_updated_at();

-- Inserts an inbox notification (idempotent per recipient+event) and its push
-- job. Title/body must already be lock-screen safe: no salary amounts, medical
-- reasons, coordinates or other private details.
create or replace function hrms.notify(
  p_org uuid,
  p_recipient uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_deep_link text,
  p_data jsonb default null,
  p_event_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_recipient is null then
    return null;
  end if;
  insert into hrms.notifications (org_id, recipient_id, event_id, kind, title, body, deep_link, data)
  values (p_org, p_recipient, coalesce(p_event_id, gen_random_uuid()), p_kind, p_title, p_body,
          p_deep_link, p_data)
  on conflict (recipient_id, event_id) do nothing
  returning id into v_id;
  if v_id is not null then
    insert into hrms.outbox (org_id, notification_id) values (p_org, v_id);
  end if;
  return v_id;
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
