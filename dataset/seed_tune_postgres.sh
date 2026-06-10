#!/usr/bin/env bash
# Toggle Postgres write durability for the SEED (data-load) phase ONLY.
#
# Bulk-loading the large Synthea transaction bundles (hundreds–thousands of
# resources each = one big commit) is bottlenecked by the per-commit WAL fsync on
# fsync-limited cloud disks: backends sit in D-state on fsync and the load crawls
# (~0.1 bundle/s → a ~24h seed in our Azure runs). With synchronous_commit=off the
# commit no longer waits on the fsync (WAL still written, flushed in the
# background), which removes that wait and speeds the seed by ~1–2 orders of
# magnitude.
#
# This is SAFE for the benchmark and does NOT affect any measured number or
# cross-server fairness: it touches only seeding. Every measured run restores from
# the snapshot and runs with NORMAL durability — phase_seed resets this to the
# default (on) before the snapshot is taken, so a snapshot always implies durability
# is back on. Worst case on a crash mid-seed is a lost tail of inserts, and we
# re-seed deterministically from a fixed Synthea seed anyway.
#
# Cluster-level (ALTER SYSTEM + pg_reload_conf) — NOT a session GUC — because the
# writes come from the server's own connection pool, not this psql session. No
# restart needed: synchronous_commit is reloadable. Connection via standard PG*
# env vars (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE), same as snapshot/restore.
#   dataset/seed_tune_postgres.sh on|off
set -euo pipefail
MODE="${1:?usage: seed_tune_postgres.sh on|off}"
case "$MODE" in
  off) sql="ALTER SYSTEM SET synchronous_commit = off;" ;;  # fast bulk load (seed only)
  on)  sql="ALTER SYSTEM RESET synchronous_commit;" ;;      # back to default (on) for measurement
  *)   echo "usage: seed_tune_postgres.sh on|off" >&2; exit 2 ;;
esac

psql -v ON_ERROR_STOP=1 -At -c "$sql" -c "SELECT pg_reload_conf();" >/dev/null
echo "==> seed-tune: synchronous_commit=$(psql -At -c 'show synchronous_commit;') (mode=$MODE, reloaded — seed phase only)"
