# dataset/

Deterministic FHIR dataset generation + per-engine snapshot/restore. This is what
guarantees **every server starts each run from the same logical state**.

## Flow

```
generate.sh  →  seed.sh  →  snapshot_*.sh        (once per server, at setup)
                                  │
                                  ▼
                          restore_*.sh            (before EVERY measurement run)
```

1. **`generate.sh`** — downloads the pinned Synthea jar and generates
   `dataset.populations.<size>` patients with the fixed `seed` + `reference_date` from
   `bench.config.yaml`. Output: transaction bundles in `output/<size>/fhir/`. Same inputs →
   byte-identical bundles.
2. **`hash.sh`** — sha256 over all bundles (sorted). Assert this matches across machines to
   prove the dataset is identical before you trust any comparison.
3. **`seed.sh <fhir_base_url>`** — POSTs the bundles through the server's **public FHIR API**
   (infrastructure bundles first, then patients). No privileged bulk loader — same path for
   every server.
4. **`snapshot_*.sh` / `restore_*.sh`** — capture the loaded+indexed DB once, then restore it
   before each run.

## Storage engines

"Same underlying state" means the **same logical FHIR dataset**, not the same DB engine —
each server keeps its native storage. Snapshot/restore is therefore per-engine:

| Server(s) | Engine | Snapshot/restore |
|---|---|---|
| fhir-server-go, HAPI, Medplum, IBM | PostgreSQL | `snapshot_postgres.sh` / `restore_postgres.sh` (implemented) |
| Microsoft FHIR Server | SQL Server | `snapshot_mssql.sh` (added in plan step 11) |
| Blaze | RocksDB | filesystem snapshot of the data dir (added in plan step 10) |

The Postgres scripts use standard `PG*` env vars (`PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE`).

## Notes

- `output/` and `snapshots/` are gitignored — regenerated deterministically from the seed.
- `generate.sh` runs on the load-gen VM (JDK installed by cloud-init); seeding/snapshotting
  run against the SUT VM's DB.
