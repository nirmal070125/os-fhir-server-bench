#!/usr/bin/env bash
# Restore a SQL Server snapshot before each run (RESTORE DATABASE ... WITH REPLACE).
# SCAFFOLDED — wired but not yet boot-verified (see servers/microsoft/README.md).
# Same env contract as snapshot_mssql.sh.
#   dataset/restore_mssql.sh <snapshot_file.bak>
set -euo pipefail
IN="${1:?usage: restore_mssql.sh <snapshot_file.bak>}"
: "${MSSQL_CONTAINER:?}"; : "${MSSQL_SA_PASSWORD:?}"; : "${MSSQL_DATABASE:?}"; : "${MSSQL_BACKUP_DIR:?}"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $MSSQL_SA_PASSWORD"

cp "$IN" "$MSSQL_BACKUP_DIR/snap.bak"
echo "==> RESTORE DATABASE [$MSSQL_DATABASE] WITH REPLACE"
docker exec "$MSSQL_CONTAINER" bash -c \
  "$SQLCMD -Q \"ALTER DATABASE [$MSSQL_DATABASE] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; \
   RESTORE DATABASE [$MSSQL_DATABASE] FROM DISK='/var/opt/mssql/backup/snap.bak' WITH REPLACE; \
   ALTER DATABASE [$MSSQL_DATABASE] SET MULTI_USER\""
echo "==> restore complete"
