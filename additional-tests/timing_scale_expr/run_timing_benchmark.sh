#!/usr/bin/env bash
set -euo pipefail

LOGFILE2="bench-timing_agg-logs.txt"
SQL_AGG_FILE="./timing_agg_benchmark.sql"
PORT=5433

PGCTL_PATH="../../hol-lambdas/install/bin/pg_ctl"
PSQL_PATH="../../hol-lambdas/install/bin/psql"
DB_DATA_DIR="../../hol-lambdas/pgdata"


echo "[info] starting postgres on port $PORT, log: $LOGFILE2" | tee -a "$LOGFILE2"

"$PGCTL_PATH" -D "$DB_DATA_DIR" -l "$LOGFILE2" \
  -o "-p $PORT -c listen_addresses=127.0.0.1" \
  start >>"$LOGFILE2" 2>&1

echo "[info] waiting for server readiness..." | tee -a "$LOGFILE2"
for _ in {1..200}; do
  if "$PSQL_PATH" -X -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "[info] running $SQL_AGG_FILE" | tee -a "$LOGFILE2"
"$PSQL_PATH" -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PORT" -d postgres -f "$SQL_AGG_FILE" >/dev/null

echo "[info] stopping postgres" | tee -a "$LOGFILE2"
"$PGCTL_PATH" -D "$DB_DATA_DIR" stop -m fast >>"$LOGFILE2" 2>&1

echo "[done] backend log saved to: $LOGFILE2"
