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

## Known limit found by the harness — FIXED upstream (PR #170)

The server used to hardcode `WriteTimeout: 60s` — in Go that clock spans the whole
handler execution, so a very large transaction bundle (Synthea emits up to ~40 MB
patients) taking >60s under CPU contention got its connection cut **after the DB
commit**: the client saw a transport error but the data was in. The harness surfaced
this deterministically at `SEED_CONCURRENCY=8` on 4 CPUs.

Fixed by [PR #170](https://github.com/wso2/open-healthcare-prebuilt-services/pull/170)
(merged): `SERVER_READ/WRITE/IDLE_TIMEOUT` env vars. This profile sets
`SERVER_WRITE_TIMEOUT` from `servers.fhir-server-go.write_timeout` (default `10m`),
and the pin includes the fix — re-verified: the previously-failing parallel seed now
passes 63/63. If you ever see `CLIENT-ERR` from `seed.sh`, never blind-retry a
transaction POST — verify first (the server may have committed).

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
