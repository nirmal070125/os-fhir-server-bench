#!/usr/bin/env bash
# Snapshot a SQL Server-backed server (Microsoft FHIR) via BACKUP DATABASE.
# SCAFFOLDED — wired but not yet boot-verified (see servers/microsoft/README.md).
# Runs sqlcmd inside the SQL Server container (it ships mssql-tools), backing up to
# the container's /var/opt/mssql/backup (a volume shared with the host), then copies
# the .bak out to the snapshot path. Env:
#   MSSQL_CONTAINER  sql container name      MSSQL_SA_PASSWORD  sa password
#   MSSQL_DATABASE   db to back up (FHIR)    MSSQL_BACKUP_DIR   host path of the backup volume
#   dataset/snapshot_mssql.sh <snapshot_file.bak>
set -euo pipefail
OUT="${1:?usage: snapshot_mssql.sh <snapshot_file.bak>}"
: "${MSSQL_CONTAINER:?}"; : "${MSSQL_SA_PASSWORD:?}"; : "${MSSQL_DATABASE:?}"; : "${MSSQL_BACKUP_DIR:?}"
mkdir -p "$(dirname "$OUT")"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $MSSQL_SA_PASSWORD"

echo "==> BACKUP DATABASE [$MSSQL_DATABASE]"
docker exec "$MSSQL_CONTAINER" bash -c \
  "$SQLCMD -Q \"BACKUP DATABASE [$MSSQL_DATABASE] TO DISK='/var/opt/mssql/backup/snap.bak' WITH FORMAT, INIT\""
cp "$MSSQL_BACKUP_DIR/snap.bak" "$OUT"
echo "==> snapshot size: $(du -h "$OUT" | cut -f1)"
