#!/usr/bin/env bash
# Disposable local Postgres + PostGIS for DB tests, installed in user space.
#
# Why: the Supabase CLI local stack needs Docker, which is not available on
# every developer machine. This gives a real Postgres 17 + PostGIS server with a
# small Supabase compatibility shim (supabase/tests/shim/*.sql) so migrations,
# RLS/RPC authorization and concurrency tests run without Docker. The hosted
# staging project remains the source of truth for Auth/Storage/Edge behaviour.
#
# Usage: tool/local_db.sh install|start|stop|status|reset|psql [args]
# Never point this at a production database: `reset` drops everything.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
MAMBA="$TOOLS/bin/micromamba"
ENV_DIR="$TOOLS/pgenv"
DATA="$TOOLS/pgdata"
PORT="${HRMS_LOCAL_PG_PORT:-54329}"
DB="hrms_test"
export MAMBA_ROOT_PREFIX="$TOOLS/mamba"

pg() { "$ENV_DIR/bin/$1" "${@:2}"; }

install() {
  mkdir -p "$TOOLS/bin"
  if [[ ! -x "$MAMBA" ]]; then
    echo "Downloading micromamba..."
    curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
      | tar -xj -C "$TOOLS" bin/micromamba
  fi
  if [[ ! -x "$ENV_DIR/bin/postgres" ]]; then
    echo "Installing postgresql 17 + postgis from conda-forge (user space)..."
    "$MAMBA" create -y -q -p "$ENV_DIR" -c conda-forge "postgresql=17" "postgis>=3.5"
  fi
  if [[ ! -d "$DATA" ]]; then
    pg initdb -D "$DATA" -U postgres --auth=trust --encoding=UTF8 --locale=C >/dev/null
    {
      echo "port = $PORT"
      echo "listen_addresses = '127.0.0.1'"
      echo "unix_socket_directories = '$TOOLS'"
      echo "timezone = 'UTC'"
      echo "max_connections = 50"
    } >> "$DATA/postgresql.conf"
  fi
  echo "Installed. Run: tool/local_db.sh start"
}

start() {
  if pg pg_ctl -D "$DATA" status >/dev/null 2>&1; then echo "already running on $PORT"; return; fi
  pg pg_ctl -D "$DATA" -l "$TOOLS/pg.log" -w start >/dev/null
  echo "Postgres running on 127.0.0.1:$PORT"
}

stop() { pg pg_ctl -D "$DATA" -m fast stop >/dev/null && echo "stopped"; }
status() { pg pg_ctl -D "$DATA" status; }

reset() {
  start
  pg psql -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q \
    -c "drop database if exists $DB with (force)" -c "create database $DB"
  echo "Database $DB recreated (empty)."
}

case "${1:-}" in
  install) install ;;
  start) start ;;
  stop) stop ;;
  status) status ;;
  reset) reset ;;
  psql) shift; pg psql -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" "$@" ;;
  bin) echo "$ENV_DIR/bin" ;;
  *) echo "usage: $0 install|start|stop|status|reset|psql|bin"; exit 2 ;;
esac
