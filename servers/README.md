# servers/

One directory per server under test. Each exposes the **same contract** — a
`manifest.yaml` (engine + lifecycle scripts + endpoints + snapshot/restore wiring)
plus `build.sh` / `up.sh` / `down.sh` — so the orchestrator drives every server
identically. All run under the identical CPU/mem envelope from `bench.config.yaml`
(the fairness charter). `_lib/lib.sh` holds the shared helpers image-based profiles use.

| Profile | Engine | Status |
|---|---|---|
| `fhir-server-go/` | postgres | **boot-verified** — built from source @ pinned commit (main + open PR #167) |
| `hapi/` | postgres | **boot-verified** — metadata/CRUD/search + snapshot/restore green |
| `blaze/` | rocksdb | **boot-verified** — CRUD + RocksDB volume snapshot/restore green |
| `microsoft/` | mssql | ⚠️ scaffolded — SQL Server, heavy; finalize on first run (see its README) |
| `medplum/` | postgres | ⚠️ scaffolded — auth mandatory; needs the seed/scenario auth hook |
| `ibm/` | postgres | ⚠️ scaffolded — HTTPS+auth; Derby→Postgres bootstrap + auth hook |

Only `fhir-server-go` is enabled in `bench.config.yaml`; flip the others on as they're
finalized. The three scaffolded servers share two finishing tasks: auth (an optional,
env-driven `Authorization` header in `seed.sh` + `scenarios/lib/common.js`, off for the
open servers) and their engine's snapshot/restore (mssql wired; Postgres reused for
Medplum/IBM). Their `engine`/env wiring is already in the orchestrator.
