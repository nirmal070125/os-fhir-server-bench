#!/usr/bin/env bash
# Reset a Postgres-backed FHIR server's DB to the seeded baseline BEFORE each
# measurement, guaranteeing identical starting state and preventing one run's writes
# from leaking into the next.
#
# FAST PATH — template clone. A logical `pg_restore` of the whole dump rebuilds every
# index and FK constraint, which on the normalized FHIR search schema (the sp_* tables)
# takes ~minutes EACH time — crippling for a sweep that resets before every level. So
# we pay that cost ONCE: build a pristine TEMPLATE database from the dump, then reset
# the working DB with `CREATE DATABASE … TEMPLATE …`, a filesystem-level copy of the
# already-built files (no index rebuild). Every per-run reset after the first is a copy.
#
# Requires the connecting role to have CREATEDB (the postgres-image POSTGRES_USER is a
# superuser) and NO live connections to the working DB — the orchestrator stops the
# server container around this call. Connection via standard PG* env vars; PGDATABASE
# names the working DB.
#   dataset/restore_postgres.sh <snapshot_file.dump>
set -euo pipefail
IN="${1:?usage: restore_postgres.sh <snapshot_file.dump>}"
DB="${PGDATABASE:?set PGDATABASE}"
TMPL="${DB}_tmpl"
JOBS="${RESTORE_JOBS:-4}"   # parallel workers for the one-time template build

# Admin ops run against the 'postgres' maintenance DB — you can't drop or clone the DB
# you're connected to. -d postgres overrides PGDATABASE; other PG* vars are honored.
psql_admin() { psql -v ON_ERROR_STOP=1 -d postgres "$@"; }
db_exists() { [[ "$(psql_admin -tAc "select 1 from pg_database where datname='$1'")" == "1" ]]; }

# (1) One-time: build the pristine template from the dump (the slow index/constraint
# rebuild, parallelized). All later resets clone from it; the dump isn't touched again.
if ! db_exists "$TMPL"; then
  echo "==> building one-time template '$TMPL' from $IN (pg_restore -j$JOBS; slow, once per snapshot)"
  psql_admin -c "CREATE DATABASE \"$TMPL\";"
  pg_restore --clean --if-exists --no-owner --no-privileges \
    --jobs="$JOBS" --dbname="$TMPL" "$IN"
  echo "==> template '$TMPL' ready"
fi

# (2) Fast reset: recreate the working DB from the template (filesystem copy, no index
# rebuild). Terminate any stragglers first (the server should already be stopped).
echo "==> reset $DB from template $TMPL (CREATE DATABASE … TEMPLATE)"
psql_admin <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname IN ('$DB', '$TMPL') AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$DB";
CREATE DATABASE "$DB" TEMPLATE "$TMPL";
SQL
echo "==> restore complete"
