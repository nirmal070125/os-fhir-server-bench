# orchestrator/

The run driver — `orchestrate.sh`. Ties the dataset, server profiles, and k6
scenarios into a methodology-compliant matrix. Two phases (= the Makefile
`seed` / `run` targets):

```
seed :  per enabled server ->  build  ->  start  ->  load dataset via public API
                            ->  snapshot the loaded+indexed DB   (once; reused)

run  :  per enabled server x scenario x repetition ->
          restore snapshot   (identical starting state every rep)
          ->  warm-up  (WARMUP_S, discarded — warms JIT/cache/pools)
          ->  measure  (MEASURE_S, captured to results/<server>/<scenario>/rep-N/)
          ->  cooldown (COOLDOWN_S)
        then write results/<server>/run-manifest.json
```

`all` does seed then run for each server.

## Execution modes — local vs Azure (remote)

`orchestrate.sh` runs the same logic in two modes:

- **Local** (default): every step runs on this machine against `localhost`. Used for
  development and the CI smoke test.
- **Remote** (`REMOTE=1`, set automatically by `reproduce.sh` from Terraform outputs):
  this process is the **operator/controller** and ssh-routes each step to the right VM —
  **no work touches the operator's disk, and there is no VM→VM ssh.**

  | Step | Runs on |
  |---|---|
  | generate Synthea, seed (POST to SUT private IP), k6 warm-up/measure | **loadgen VM** |
  | build/up/down, snapshot, restore, readiness wait | **SUT VM** |
  | terraform, report generation, final `results/` | **operator (your machine)** — KB–few MB only |

  Wiring (from `orchestrator/remote-setup.sh`): `SUT_SSH`, `LOADGEN_SSH`, `SUT_REPO`,
  `LOADGEN_REPO`, `SUT_PRIVATE_HOST`, `SSH_OPTS`. The working tree is copied to both VMs
  via tar-over-ssh (code + your `bench.config.yaml`; no jar/dataset/images). Per-rep k6
  output is produced on the loadgen and `scp`'d back to `results/`.

  This is what makes `./reproduce.sh` actually run the benchmark **on Azure** — the
  earlier wiring provisioned VMs but ran everything locally.

  - **Detached** (`make run-detached`): the operator-driven mode keeps the controller
    on your laptop, so it dies if the laptop sleeps/disconnects — fine for the short
    smoke, painful for a multi-hour run. Detached instead launches the controller **on
    the loadgen VM in a tmux session** (`LOADGEN_LOCAL=1`: generate/seed/k6 run locally
    there, only the SUT leg ssh's over the private network via a one-off ephemeral key
    added to the SUT). You kick it off and disconnect; the run survives.
    `make run-status` tails it, `make fetch-results` pulls `results/` back and builds
    the report. Infra must already be up (`make infra-up`).

## Why this order

- **Same starting state, every run** — the snapshot is restored *before each rep*,
  so neither a previous rep's writes (ingest) nor warm-up traffic leaks into the
  measured window. This is the fairness requirement made concrete.
- **Warm-up is discarded** — run with `CAPTURE=0`, so its numbers never enter the
  results. It exists only to warm the server before the measured window.
- **N reps** — every scenario runs `run.repetitions` times; reporting (step 7)
  takes the median + spread.

## Config + overrides

Everything comes from `bench.config.yaml` (`servers.*.enabled`, `run.*`, `dataset.size`,
`limits.*`, `slo.*`). Env overrides for local iteration:

| Env | Overrides |
|---|---|
| `SERVERS` / `SCENARIOS` | which servers / scenarios to run |
| `REPS` / `WARMUP_S` / `MEASURE_S` / `COOLDOWN_S` | run timing |
| `SKIP_BUILD=1` | reuse the already-built image |
| `KEEP_UP=1` | don't tear the server down at the end |
| `SUT_API_HOST` / `SUT_DB_HOST` | point at a remote SUT (default `localhost`) — lets the driver run on the loadgen VM against the SUT VM with no code change |

## Per-engine snapshot/restore

The driver reads `engine` from each server's `manifest.yaml` and calls
`dataset/snapshot_<engine>.sh` / `restore_<engine>.sh` with the right connection env.
Today: `postgres` (fhir-server-go). `mssql` (Microsoft) and `rocksdb` (Blaze) are
added with those servers in plan steps 10–11.

## Run manifest

`results/<server>/run-manifest.json` records what produced the numbers: bench-repo
SHA, k6 version, host vCPUs, the server source pin (repo/ref/commit), the fairness
`limits`, dataset size + content hash, SLO, and run timing. This is what makes a
result auditable and reproducible.
