-- Admin-configured HR phone shown on the signed-out login screen through a
-- narrow, rate-limited Edge Function. The public client never reads employee
-- phone numbers or the organizations table directly.

alter table hrms.organizations
  add column support_phone text check (char_length(support_phone) <= 32);

create or replace function hrms.normalized_support_phone(p_value text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_display text := nullif(regexp_replace(btrim(coalesce(p_value, '')), '\s+', ' ', 'g'), '');
  v_digits text;
begin
  if v_display is null then
    return jsonb_build_object('display_phone', null, 'tel_uri', null);
  end if;
  v_digits := regexp_replace(v_display, '\D', '', 'g');
  if v_display !~ '^\+[0-9][0-9 ()-]{6,23}$' or length(v_digits) not between 8 and 15 then
    return null;
  end if;
  return jsonb_build_object('display_phone', v_display, 'tel_uri', 'tel:+' || v_digits);
end;
$$;

create or replace function public.get_org_settings() returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_ledger hrms.storage_ledger;
begin
  perform hrms.require_admin(v_actor);
  select * into v_org from hrms.organizations where id = v_actor.org_id;
  select * into v_ledger from hrms.storage_ledger where org_id = v_org.id;
  return hrms.ok(jsonb_build_object(
    'id', v_org.id, 'code', v_org.code, 'name', v_org.name, 'timezone', v_org.timezone,
    'annual_start_month', v_org.annual_start_month, 'leave_year_start_month', v_org.leave_year_start_month,
    'active_employee_cap', v_org.active_employee_cap, 'holiday_target', v_org.holiday_target,
    'support_contact', v_org.support_contact, 'support_phone', v_org.support_phone,
    'storage_budget_bytes', v_org.storage_budget_bytes,
    'storage_alert_percents', to_jsonb(v_org.storage_alert_percents), 'strict_geofence', v_org.strict_geofence,
    'require_biometric_punch', v_org.require_biometric_punch,
    'storage_used_bytes', coalesce(v_ledger.used_bytes, 0), 'storage_reserved_bytes', coalesce(v_ledger.reserved_bytes, 0),
    'active_employees', (select count(*) from hrms.employees where org_id = v_org.id and status = 'active'),
    'setup_published_at', v_org.setup_published_at, 'version', v_org.version), v_org.version);
end;
$$;

create or replace function public.update_org_settings(p_patch jsonb, p_expected_version integer) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor hrms.actor := hrms.current_actor();
  v_org hrms.organizations;
  v_errors jsonb := '{}'::jsonb;
  v_active integer;
  v_phone jsonb;
begin
  perform hrms.require_admin(v_actor);
  select * into v_org from hrms.organizations where id = v_actor.org_id for update;
  if v_org.version <> p_expected_version then
    perform hrms.raise_error('STALE_VERSION', 'Settings changed. Reload and try again.', null, true);
  end if;
  if p_patch ? 'timezone' and not hrms.valid_timezone(p_patch ->> 'timezone') then
    v_errors := v_errors || '{"timezone":"Unknown time zone"}';
  end if;
  if p_patch ? 'annual_start_month' and (p_patch ->> 'annual_start_month')::integer not in (1, 4) then
    v_errors := v_errors || '{"annual_start_month":"January or April"}';
  end if;
  if p_patch ? 'annual_start_month' and (p_patch ->> 'annual_start_month')::integer <> v_org.annual_start_month
     and hrms.org_has_export_jobs(v_org.id) then
    v_errors := v_errors || '{"annual_start_month":"Use the annual-period transition flow; existing archive periods are immutable"}';
  end if;
  if p_patch ? 'leave_year_start_month' and (p_patch ->> 'leave_year_start_month')::integer not between 1 and 12 then
    v_errors := v_errors || '{"leave_year_start_month":"1–12"}';
  end if;
  if p_patch ? 'active_employee_cap' then
    select count(*) into v_active from hrms.employees where org_id = v_org.id and status = 'active';
    if (p_patch ->> 'active_employee_cap')::integer < greatest(1, v_active) then
      v_errors := v_errors || jsonb_build_object('active_employee_cap',
        format('Cannot be below the %s currently active employees', v_active));
    end if;
  end if;
  if p_patch ? 'storage_budget_bytes' and (p_patch ->> 'storage_budget_bytes')::bigint < 1000000 then
    v_errors := v_errors || '{"storage_budget_bytes":"At least 1 MB"}';
  end if;
  if p_patch ? 'support_phone' then
    v_phone := hrms.normalized_support_phone(p_patch ->> 'support_phone');
    if nullif(btrim(coalesce(p_patch ->> 'support_phone', '')), '') is not null and v_phone is null then
      v_errors := v_errors || '{"support_phone":"Use an international number such as +91 98765 43210"}';
    end if;
  end if;
  if v_errors <> '{}'::jsonb then
    perform hrms.raise_error('VALIDATION_FAILED', 'Please check the highlighted fields.', v_errors);
  end if;

  update hrms.organizations set
    name = coalesce(hrms.clean_text(p_patch ->> 'name', 120), name),
    timezone = coalesce(p_patch ->> 'timezone', timezone),
    annual_start_month = coalesce((p_patch ->> 'annual_start_month')::smallint, annual_start_month),
    leave_year_start_month = coalesce((p_patch ->> 'leave_year_start_month')::smallint, leave_year_start_month),
    active_employee_cap = coalesce((p_patch ->> 'active_employee_cap')::integer, active_employee_cap),
    holiday_target = coalesce((p_patch ->> 'holiday_target')::integer, holiday_target),
    support_contact = case when p_patch ? 'support_contact' then hrms.clean_text(p_patch ->> 'support_contact', 200)
                           else support_contact end,
    support_phone = case when p_patch ? 'support_phone' then v_phone ->> 'display_phone' else support_phone end,
    storage_budget_bytes = coalesce((p_patch ->> 'storage_budget_bytes')::bigint, storage_budget_bytes),
    strict_geofence = coalesce((p_patch ->> 'strict_geofence')::boolean, strict_geofence),
    require_biometric_punch = coalesce((p_patch ->> 'require_biometric_punch')::boolean, require_biometric_punch),
    setup_published_at = case when (p_patch ->> 'publish_setup')::boolean then coalesce(setup_published_at, now())
                              else setup_published_at end,
    version = version + 1
  where id = v_org.id
  returning * into v_org;
  insert into hrms.settings_versions (org_id, version, snapshot, changed_by, reason)
  values (v_org.id, v_org.version, to_jsonb(v_org) - 'updated_at', v_actor.employee_id,
          hrms.clean_text(p_patch ->> 'reason', 500));
  perform hrms.audit(v_org.id, v_actor.employee_id, 'org.settings_updated', 'organization', v_org.id,
    (p_patch - 'reason') - 'support_phone'
      || case when p_patch ? 'support_phone' then '{"support_phone_changed":true}'::jsonb else '{}'::jsonb end,
    'business');
  return public.get_org_settings();
end;
$$;

create or replace function public.internal_login_support(p_org_code text, p_ip_hash text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hits integer;
  v_phone jsonb;
begin
  v_hits := hrms.rate_limit_hit('login-support:' || left(coalesce(p_ip_hash, 'unknown'), 64), interval '10 minutes');
  if v_hits > 30 then
    return jsonb_build_object('allowed', false, 'display_phone', null, 'tel_uri', null);
  end if;
  select hrms.normalized_support_phone(o.support_phone) into v_phone
  from hrms.organizations o where o.code = upper(btrim(coalesce(p_org_code, '')));
  return jsonb_build_object(
    'allowed', true,
    'display_phone', v_phone ->> 'display_phone',
    'tel_uri', v_phone ->> 'tel_uri');
end;
$$;

select hrms.apply_api_grants();
