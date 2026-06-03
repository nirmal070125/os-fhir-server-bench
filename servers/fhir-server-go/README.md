# servers/fhir-server-go/

Benchmark profile for **fhir-server-go** — our server, the System Under Test.

## What gets benchmarked

Built **from source at a pinned commit**, not a pre-published image, so the binary
is exactly reproducible and matches "the latest fhir-server-go":

| | |
|---|---|
| Repo | `nirmal070125/open-healthcare-prebuilt-services` (fork) |
| Branch | `fhir-server-go/operations` |
| Commit | `3159ac6b260c7af42190a1f3382810ee5203f366` |
| = | latest `wso2:main` (incl. **PR #165** — transaction bundles, merged) **+ open PR #167** (standard FHIR operations: `$validate`/`$meta`/`$convert`/`$lastn`/`$document`) |

PR #167 is still unmerged; this profile builds the branch that contains all of `main`
plus those commits, so we benchmark exactly what ships once #167 lands. Bump the pin in
`bench.config.yaml` → `servers.fhir-server-go.commit` when it moves.

## Runtime shape (verified against the source)

- Port `9090`, base path `/fhir/r4`, readiness at **`GET /health/ready`**.
- Image is **distroless** (`gcr.io/distroless/static-debian12:nonroot`) — no shell/curl
  inside, so readiness is probed from the host (`up.sh`), not via a container healthcheck.
- Postgres 16 (native engine), data in the `pgdata` volume → snapshot/restore is
  `dataset/snapshot_postgres.sh` / `restore_postgres.sh` over the exposed `5432`.
- **Baseline = no profile validation** (`FHIR_VALIDATE_ON_WRITE=false`, `IG_PACKAGES=""`)
  so the comparison is apples-to-apples core CRUD/search. Flip both on in the config to
  measure IG-validation cost (and set the equivalent on the comparators).

## Known limit found by the harness

The server hardcodes `WriteTimeout: 60s` (`cmd/server/main.go`) — in Go that clock
spans the whole handler execution, so a very large transaction bundle (Synthea emits
up to ~40 MB patients) that takes >60s under CPU contention gets its connection cut
**after the DB commit**: the client sees a transport error but the data is in.
Seeding surfaces this at `SEED_CONCURRENCY=8` on 4 CPUs. Fix in flight: make the
server's HTTP timeouts env-configurable upstream, then bump the pin and set a
generous write timeout here. Until then, lower `SEED_CONCURRENCY` if you see
`CLIENT-ERR` on big bundles (and never blind-retry a transaction POST — verify first).

## Usage

```bash
./build.sh    # clone+checkout the pinned commit, docker build
./up.sh       # start db+server, block until /health/ready
# ... seed / run scenarios ...
./down.sh     # stop (keep data);  ./down.sh -v  to wipe volumes
```

## How config flows (no hard-coding)

`bench.config.yaml` → `render-env.sh` → `.env` → `compose.yaml`. The identical CPU/memory
envelope (`limits.sut_*` / `limits.db_*`) is applied via `deploy.resources.limits`, which
`docker compose up` (Compose v2) honors — that's what keeps every server on the same
hardware budget. `.env` and `.src/` are generated and gitignored.
