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
