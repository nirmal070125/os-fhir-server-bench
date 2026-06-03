#!/usr/bin/env bash
# Restore a Postgres snapshot BEFORE each measurement run, guaranteeing identical
# starting state and preventing one run's writes from leaking into the next.
# Connection via PG* env vars; PGDATABASE names the target DB.
#   dataset/restore_postgres.sh <snapshot_file.dump>
#
# Resets objects IN PLACE (pg_restore --clean drops then recreates each object
# from the dump) rather than dropping/recreating the database. This needs only
# ownership of the objects — not the CREATEDB/superuser privilege that the typical
# app DB role (e.g. fhir-server-go's `fhir`) does NOT have. --if-exists makes the
# drops idempotent; --single-transaction makes the whole restore atomic.
set -euo pipefail
IN="${1:?usage: restore_postgres.sh <snapshot_file.dump>}"
DB="${PGDATABASE:?set PGDATABASE}"

echo "==> pg_restore --clean $IN → $DB (in-place reset)"
pg_restore --clean --if-exists --no-owner --no-privileges \
  --single-transaction --dbname="$DB" "$IN"
echo "==> restore complete"
