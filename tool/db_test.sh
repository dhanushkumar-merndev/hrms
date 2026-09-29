#!/usr/bin/env bash
# Applies all migrations to the disposable LOCAL database and runs the SQL test
# suites in supabase/tests/database. Destructive: recreates hrms_test.
#
# Usage: tool/db_test.sh [--migrate-only] [test-file-glob]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="$(tool/local_db.sh bin)"
PORT="${HRMS_LOCAL_PG_PORT:-54329}"
export PGOPTIONS="-c client_min_messages=warning"
PSQL=("$BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d hrms_test -v ON_ERROR_STOP=1 -q -X)

tool/local_db.sh reset >/dev/null
"${PSQL[@]}" -f supabase/tests/shim/00_supabase_shim.sql >/dev/null

for f in supabase/migrations/*.sql; do
  if ! out=$("${PSQL[@]}" -f "$f" 2>&1); then
    echo "MIGRATION FAILED: $f"; echo "$out" | tail -20; exit 1
  fi
done
echo "migrations: applied $(ls supabase/migrations/*.sql | wc -l) files"

[[ "${1:-}" == "--migrate-only" ]] && exit 0

pattern="${1:-*.sql}"
pass=0; fail=0
"${PSQL[@]}" -f supabase/tests/database/_harness.sql >/dev/null
for t in supabase/tests/database/$pattern; do
  [[ "$(basename "$t")" == _* ]] && continue
  if out=$("${PSQL[@]}" -At -f "$t" 2>&1); then
    n=$(grep -c '^ok ' <<<"$out" || true)
    echo "PASS  $(basename "$t")  ($n assertions)"
    pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"
    echo "$out" | grep -v '^ok ' | tail -15 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done
echo "suites: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
