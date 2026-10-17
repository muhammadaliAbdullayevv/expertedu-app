#!/usr/bin/env bash
# A complete copy of the Expert Edu backend on THIS computer: its own
# PostgreSQL (in ~/.local/share/expertedu-local) and the API on
# http://127.0.0.1:8765. Nothing here talks to the real server or its database.
#
#   expertedu-local.sh setup    first time: database, tables, test data, autostart at login
#   expertedu-local.sh start    start the database and the API now
#   expertedu-local.sh stop     stop both
#   expertedu-local.sh status   is it running?
#   expertedu-local.sh reset    throw the local data away and make it again (asks first)
#   expertedu-local.sh seed     add the test data to an empty local database
#
# Sign in: 90 000 00 01 / demo1234 (owner), 90 000 00 02 / demo1234 (admin).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(dirname "$HERE")"
STATE="${EXPERTEDU_LOCAL_DIR:-$HOME/.local/share/expertedu-local}"
PG_PORT="${EXPERTEDU_LOCAL_PG_PORT:-54340}"
API_PORT="${EXPERTEDU_LOCAL_API_PORT:-8765}"
DB_URL="postgresql://postgres@127.0.0.1:${PG_PORT}/expertedu"
UNITS="$HOME/.config/systemd/user"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

write_env() {
  mkdir -p "$STATE"
  if [ ! -f "$STATE/env" ]; then
    {
      echo "DATABASE_URL=$DB_URL"
      echo "JWT_SECRET=local-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
      echo "PUBLIC_BASE_URL=http://127.0.0.1:${API_PORT}"
    } > "$STATE/env"
    chmod 600 "$STATE/env"
  fi
}

write_units() {
  mkdir -p "$UNITS"
  cat > "$UNITS/expertedu-local-db.service" <<UNIT
[Unit]
Description=Expert Edu (local) - PostgreSQL

[Service]
ExecStart=/usr/bin/postgres -D $STATE/pgdata
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
  cat > "$UNITS/expertedu-local-api.service" <<UNIT
[Unit]
Description=Expert Edu (local) - API
After=expertedu-local-db.service
Requires=expertedu-local-db.service

[Service]
WorkingDirectory=$SERVER
EnvironmentFile=$STATE/env
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do pg_isready -q -h 127.0.0.1 -p $PG_PORT && exit 0; sleep 1; done; exit 1'
ExecStart=$SERVER/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port $API_PORT
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
}

init_db() {
  if [ ! -f "$STATE/pgdata/PG_VERSION" ]; then
    say "Making the local database in $STATE/pgdata"
    initdb -D "$STATE/pgdata" -U postgres -A trust --encoding=UTF8 --no-locale >/dev/null
    {
      echo "port = $PG_PORT"
      echo "listen_addresses = '127.0.0.1'"
      echo "unix_socket_directories = '$STATE'"
    } >> "$STATE/pgdata/postgresql.conf"
  fi
}

wait_db() { for _ in $(seq 1 30); do pg_isready -q -h 127.0.0.1 -p "$PG_PORT" && return 0; sleep 1; done; return 1; }
wait_api() { for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:${API_PORT}/health" >/dev/null && return 0; sleep 1; done; return 1; }

psql_local() { psql -h 127.0.0.1 -p "$PG_PORT" -U postgres -v ON_ERROR_STOP=1 -q "$@"; }

case "${1:-}" in
  setup)
    [ -x "$SERVER/.venv/bin/uvicorn" ] || { echo "Missing $SERVER/.venv (python -m venv .venv && .venv/bin/pip install -r requirements.txt)"; exit 1; }
    write_env; init_db; write_units
    systemctl --user enable --now expertedu-local-db.service
    wait_db || { echo "The database did not start"; exit 1; }
    if ! psql_local -d postgres -Atc "select 1 from pg_database where datname='expertedu'" | grep -q 1; then
      psql_local -d postgres -c "create database expertedu"
      say "Making the tables"
      psql_local -d expertedu -f "$SERVER/schema.sql"
      NEED_SEED=1
    fi
    systemctl --user enable --now expertedu-local-api.service
    wait_api || { echo "The API did not start (journalctl --user -u expertedu-local-api)"; exit 1; }
    if [ "${NEED_SEED:-0}" = 1 ]; then "$0" seed; fi
    say "Ready: http://127.0.0.1:${API_PORT}  (owner 90 000 00 01 / demo1234)"
    ;;
  seed)
    set -a; . "$STATE/env"; set +a
    "$SERVER/.venv/bin/python" "$HERE/seed_local.py"
    ;;
  start)
    systemctl --user start expertedu-local-db.service expertedu-local-api.service
    wait_api && say "Running on http://127.0.0.1:${API_PORT}"
    ;;
  stop)
    systemctl --user stop expertedu-local-api.service expertedu-local-db.service
    ;;
  status)
    systemctl --user --no-pager status expertedu-local-db.service expertedu-local-api.service | grep -E "●|Active" || true
    curl -fs "http://127.0.0.1:${API_PORT}/health" && echo " <- API answers" || echo "API is not answering"
    ;;
  reset)
    read -r -p "Throw away ALL local data and make it again? [y/N] " yes
    [ "$yes" = y ] || exit 0
    systemctl --user stop expertedu-local-api.service
    psql_local -d postgres -c "drop database if exists expertedu"
    psql_local -d postgres -c "create database expertedu"
    psql_local -d expertedu -f "$SERVER/schema.sql"
    systemctl --user start expertedu-local-api.service
    wait_api && "$0" seed
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1;;
esac
