#!/usr/bin/env bash
# Deploys the HRMS backend to the Supabase project in .env:
#   1. migrations (dry run shown first)      3. Edge Functions (server-side bundling)
#   2. Edge Function secrets                 4. Vault secrets for pg_cron + Auth hardening
# Never prints secret values. Usage: tool/deploy.sh [--migrations-only|--functions-only]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load .env safely (values may contain spaces; nothing is echoed).
eval "$(python3 - <<'EOF'
import shlex
for line in open('.env', encoding='utf-8'):
    s = line.strip()
    if not s or s.startswith('#') or '=' not in s: continue
    k, v = s.split('=', 1)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'': v = v[1:-1]
    print(f'export {k.strip()}={shlex.quote(v)}')
EOF
)"

: "${SUPABASE_PROJECT_REF:?missing in .env}"
: "${SUPABASE_ACCESS_TOKEN:?missing in .env}"
: "${SUPABASE_DB_URL:?missing in .env}"
: "${HRMS_MAINTENANCE_SECRET:?missing in .env}"
case "$APP_SUPABASE_URL" in
  *"$SUPABASE_PROJECT_REF"*) ;;
  *) echo "APP_SUPABASE_URL does not match SUPABASE_PROJECT_REF; refusing to deploy."; exit 1 ;;
esac

# npm prints full command lines in "notice" output; silence it and redact
# the connection string from everything the CLI prints.
export npm_config_loglevel=error npm_config_update_notifier=false
SB=(npx --yes --loglevel=error supabase@2.118.0)
redact() {
  python3 -c '
import os, re, sys
url = os.environ.get("SUPABASE_DB_URL", "")
secret_values = [url] + [v for k, v in os.environ.items()
                         if k in ("SUPABASE_ACCESS_TOKEN", "SUPABASE_SERVICE_ROLE_KEY", "HRMS_MAINTENANCE_SECRET") and v]
m = re.match(r"^[a-z]+://[^:]+:(.*)@[^@]+$", url)
if m: secret_values.append(m.group(1))
for line in sys.stdin:
    for v in secret_values:
        if v: line = line.replace(v, "[redacted]")
    sys.stdout.write(line)
'
}
API="https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF"
MODE="${1:-all}"

run_sql() {  # run SQL through the Management API (stdin = SQL), no echo
  python3 -c 'import json,sys; print(json.dumps({"query": sys.stdin.read()}))' \
    | curl -sS --fail-with-body -X POST -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        -H "Content-Type: application/json" "$API/database/query" --data-binary @- >/dev/null
}

if [[ "$MODE" == "all" || "$MODE" == "--migrations-only" ]]; then
  echo "== Migrations (dry run)"
  "${SB[@]}" db push --db-url "$SUPABASE_DB_URL" --dry-run 2>&1 | redact | tail -20
  echo "== Applying migrations"
  "${SB[@]}" db push --db-url "$SUPABASE_DB_URL" --yes 2>&1 | redact | tail -20
fi

if [[ "$MODE" == "all" || "$MODE" == "--functions-only" ]]; then
  echo "== Edge Function secrets"
  SECRETS="$(mktemp)"
  chmod 600 "$SECRETS"
  {
    echo "HRMS_ENVIRONMENT=${HRMS_ENVIRONMENT:-staging}"
    echo "HRMS_MAINTENANCE_SECRET=$HRMS_MAINTENANCE_SECRET"
    [[ -n "${HRMS_FCM_SERVICE_ACCOUNT_B64:-}" ]] && echo "HRMS_FCM_SERVICE_ACCOUNT_B64=$HRMS_FCM_SERVICE_ACCOUNT_B64"
    [[ -n "${HRMS_ANDROID_CERT_SHA256:-}" ]] && echo "HRMS_ANDROID_CERT_SHA256=$HRMS_ANDROID_CERT_SHA256"
    [[ -n "${HRMS_SHEETS_SERVICE_ACCOUNT_B64:-}" ]] && echo "HRMS_SHEETS_SERVICE_ACCOUNT_B64=$HRMS_SHEETS_SERVICE_ACCOUNT_B64"
    true
  } > "$SECRETS"
  "${SB[@]}" secrets set --project-ref "$SUPABASE_PROJECT_REF" --env-file "$SECRETS" 2>&1 | redact | tail -3
  rm -f "$SECRETS"

  echo "== Deploying Edge Functions"
  for fn in auth-login auth-password auth-reauth admin-users device-register punch files maintenance archive public-config \
            holiday-suggestions sheets-sync; do
    "${SB[@]}" functions deploy "$fn" --project-ref "$SUPABASE_PROJECT_REF" --no-verify-jwt --use-api 2>&1 | redact | tail -1
  done
fi

if [[ "$MODE" == "all" ]]; then
  echo "== Vault secrets for the maintenance scheduler"
  run_sql <<SQL
do \$\$
begin
  if exists (select 1 from vault.secrets where name = 'hrms_functions_url') then
    perform vault.update_secret((select id from vault.secrets where name = 'hrms_functions_url'),
      '$APP_SUPABASE_URL/functions/v1');
  else
    perform vault.create_secret('$APP_SUPABASE_URL/functions/v1', 'hrms_functions_url');
  end if;
  if exists (select 1 from vault.secrets where name = 'hrms_maintenance_secret') then
    perform vault.update_secret((select id from vault.secrets where name = 'hrms_maintenance_secret'),
      '$HRMS_MAINTENANCE_SECRET');
  else
    perform vault.create_secret('$HRMS_MAINTENANCE_SECRET', 'hrms_maintenance_secret');
  end if;
end \$\$;
SQL
  echo "   ok"

  echo "== Auth hardening (no public signup, 12+ char passwords)"
  AUTH_OUT="$(curl -sS -X PATCH -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" "$API/config/auth" \
    -d '{"disable_signup": true, "external_anonymous_users_enabled": false, "password_min_length": 12}')"
  if grep -q '"disable_signup":true' <<<"$AUTH_OUT"; then
    echo "   ok: public signup disabled, minimum password length 12"
  else
    echo "   WARNING: token cannot change Auth settings. In the Supabase dashboard set:"
    echo "     Authentication > Sign In / Providers > Allow new users to sign up: OFF"
    echo "     Authentication > Providers > Email > Minimum password length: 12"
  fi
fi
echo "Done."
