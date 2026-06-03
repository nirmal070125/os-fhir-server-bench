# scenarios/

k6 load scripts for the benchmark. **Open model** (constant/ramping *arrival rate*,
not a fixed VU pool) so the load offered is independent of how fast the server
responds — this is what prevents coordinated omission from hiding latency.

| Scenario | Executor | What it measures |
|---|---|---|
| `read-mix.js` | constant-arrival-rate | Steady real-world read traffic at a fixed req/s. Read-only → DB state is identical across reps. |
| `ingest.js` | constant-arrival-rate | Sustained writes: POSTs `Patient+Encounter+2×Observation` **transaction bundles** (the PR #165 endpoint) at a fixed bundles/s. |
| `saturation.js` | ramping-arrival-rate | Steps offered read load up until the SLO trips (`abortOnFail`). Last sustained step ≈ **max sustainable throughput**. |

`lib/common.js` holds the shared bits — required `BASE_URL`, SLO thresholds, the
`op`-tagged latency/error metrics, the executors, and `setup()` id-pooling (it pages
the server's own API for real ids, so no external fixture file is needed).

## Running

All tunables come from `bench.config.yaml` (`workload.*`, `slo.*`); `run.sh` maps them
to k6 env vars — nothing is hard-coded in the scripts.

```bash
# one scenario, once, against a running server (seed it first)
scenarios/run.sh read-mix   http://localhost:9090/fhir/r4 60s
scenarios/run.sh ingest     http://localhost:9090/fhir/r4 60s
scenarios/run.sh saturation http://localhost:9090/fhir/r4
```

Output for each invocation → `results/<scenario>/`: `metrics.json` (line-delimited
per-point k6 JSON) + `summary.json` (end-of-test aggregate). The orchestrator (plan
step 6) wraps `run.sh` with warm-up (discarded), `repetitions`, and Prometheus
remote-write; reporting (step 7) turns the JSON into the published curves.

## Env vars (set by `run.sh`, overridable)

`BASE_URL` (required, …/fhir/r4) · `P99_MS` · `MAX_ERROR_RATE` · `RATE` ·
`DURATION` · `PREALLOCATED_VUS` · `MAX_VUS` · (saturation) `START_RATE` /
`STEP_RATE` / `STEP_DURATION` / `MAX_RATE` · `POOL_SIZE` (ids to pool for reads) ·
`READ_MIX_WEIGHTS` (JSON, override the read distribution) · `SUMMARY_OUT`.
