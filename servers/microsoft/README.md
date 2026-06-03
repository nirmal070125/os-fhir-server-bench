# servers/microsoft/  ⚠️ scaffolded, not yet boot-verified

**Microsoft FHIR Server** (`mcr.microsoft.com/healthcareapis/r4-fhir-server`), SQL
Server backed. FHIR at root (`/`), port 8080 (host 8081), readiness `/health/check`.
Security is disabled (`FHIRServer__Security__Enabled=false`) for an open API matching
the other servers.

**Why scaffolded, not booted:** the SQL Server image is large (~2 GB) and schema-init
takes several minutes — impractical to boot-verify on a laptop alongside the others.
Finalize on the first real run (it's a phase-11 comparator by design).

**To finalize:**
1. `./build.sh && ./up.sh`, confirm `/health/check` → 200 and a `Patient` POST works.
2. Verify snapshot/restore: `dataset/snapshot_mssql.sh` / `restore_mssql.sh` use
   `BACKUP`/`RESTORE DATABASE` over a shared `./backup` volume (sqlcmd runs in a
   throwaway `mssql-tools` container — no host tool needed). Confirm a write-then-restore
   resets state, same as the Postgres/RocksDB engines.
3. Engine wiring (`engine: mssql`, `MSSQL_*` env) is already in the orchestrator.

Lifecycle/ports/limits follow the same pattern as the verified profiles.
