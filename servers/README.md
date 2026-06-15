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

## Adding a new server

The orchestrator is generic — it only knows the contract below, so adding a server is
self-contained (no orchestrator changes for a Postgres-backed, no-auth server). Copy the
closest existing profile (`hapi/` for a pre-built image, `fhir-server-go/` for build-from-source)
and adapt it.

1. **Declare it in `bench.config.yaml`** under `servers:` — `enabled`, `base_path`, `port`,
   `health_path`, and either `image:` (pre-built) or `repo`/`ref`/`commit`/`context_subdir`
   (build-from-source). Add `db_port` if it has a snapshot/restore-able database. It
   automatically inherits the shared `limits:` envelope — that's the fairness guarantee.

2. **Create `servers/<name>/`** with the uniform contract:
   - `manifest.yaml` — `name`, `engine` (`postgres` | `mssql` | `rocksdb` | …), `lifecycle`
     (build/up/down), `endpoints` (the `*_key` pointers into `bench.config.yaml`), and
     `dataset` (snapshot/restore scripts + connection block for its engine). Copy an existing one.
   - `compose.yaml` — the server + its datastore. **Must** read the resource envelope from the
     env that `_lib/lib.sh` exports: `SUT_CPUS`, `SUT_MEM`, `DB_CPUS`, `DB_MEM`, `HOST_PORT`,
     `DB_PORT`. Do not hardcode CPU/mem — that would break the fair envelope.
   - `build.sh` / `up.sh` / `down.sh` — for an image server, `build.sh` is usually a no-op
     `docker pull`; `up.sh` sources `_lib/lib.sh`, exports the envelope, and `docker compose up -d`.
     Build-from-source servers add a `render-env.sh` that materializes a `.env` from the config.

3. **Wire snapshot/restore for its engine.** Reuse `dataset/{snapshot,restore}_postgres.sh`
   (Postgres), `_mssql.sh`, or `_rocksdb.sh` (volume copy). A new engine needs a new pair of
   scripts following the same `snapshot <name>` / `restore <name>` interface.

4. **Auth (only if the server requires it).** Set an env-driven bearer token consumed by
   `dataset/seed.sh` and `scenarios/lib/common.js` (see the Medplum/IBM scaffolds). Servers
   that allow anonymous access (HAPI, Blaze, fhir-server-go) need nothing here.

5. **Add it to CI validation** — append the profile to the compose-config loop in
   `.github/workflows/validate.yml` so a malformed `compose.yaml` is caught on PR.

Verify with `SERVERS=<name> make smoke` (a small, single-rep run end-to-end). When the
`up → health → seed → snapshot → restore → measure → down` cycle is green, it's a first-class
comparator.
