#!/usr/bin/env bash
# Restore a Postgres snapshot BEFORE each measurement run, guaranteeing identical
# starting state and preventing one run's writes from leaking into the next.
# Connection via PG* env vars; PGDATABASE names the DB to recreate.
#   dataset/restore_postgres.sh <snapshot_file.dump>
set -euo pipefail
IN="${1:?usage: restore_postgres.sh <snapshot_file.dump>}"
DB="${PGDATABASE:?set PGDATABASE}"

# drop/create must connect to a maintenance DB, not the one being recreated.
echo "==> Dropping + recreating '$DB'"
PGDATABASE=postgres dropdb --if-exists "$DB"
PGDATABASE=postgres createdb "$DB"

echo "==> pg_restore $IN → $DB"
pg_restore --no-owner --no-privileges --dbname="$DB" "$IN"
echo "==> restore complete"
