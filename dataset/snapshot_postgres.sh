#!/usr/bin/env bash
# Snapshot a Postgres-backed FHIR server's DB AFTER seeding, so every run can
# start from byte-identical state. Connection via standard PG* env vars
# (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE).
#   dataset/snapshot_postgres.sh <snapshot_file.dump>
set -euo pipefail
OUT="${1:?usage: snapshot_postgres.sh <snapshot_file.dump>}"
mkdir -p "$(dirname "$OUT")"

echo "==> pg_dump '${PGDATABASE:-?}' → $OUT"
pg_dump --format=custom --no-owner --no-privileges --file="$OUT"
echo "==> snapshot size: $(du -h "$OUT" | cut -f1)"
