# scenarios/

k6 load scripts for the benchmark. **Closed model** (fixed VU pool = a set number of
concurrent clients, each looping send → await reply → send next). Concurrency is the
input we set exactly; throughput is the server's measured output. The orchestrator
**sweeps concurrency** across a ladder and measures each level — see
[`docs/load-model.md`](../docs/load-model.md).

| Scenario | Executor | What it measures |
|---|---|---|
| `read-mix.js` | constant-vus | Read-dominated real-world traffic from `VUS` concurrent clients. Read-only → DB state is identical across the whole sweep. |
| `ingest.js` | constant-vus | Writes: POSTs `Patient+Encounter+2×Observation` **transaction bundles** (the PR #165 endpoint) from `VUS` concurrent clients. Snapshot restored before each level. |

The standalone saturation scenario was removed: the concurrency sweep *is* the
saturation curve — throughput rises with concurrency, then plateaus at the knee.

`lib/common.js` holds the shared bits — required `BASE_URL`, SLO thresholds (no
abort), the `op`-tagged latency/error metrics, the `constant-vus` executor, and
`setup()` id-pooling (it pages the server's own API for real ids, so no external
fixture file is needed).

## Running

`CONCURRENCY` (the level to measure) is required; SLO knobs come from
`bench.config.yaml` (`slo.*`). One concurrency level per invocation:

```bash
# one workload at one concurrency level, against a running server (seed it first)
CONCURRENCY=32 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
CONCURRENCY=16 scenarios/run.sh ingest   http://localhost:9090/fhir/r4 60s
```

Output for each invocation → `results/<scenario>/`: `metrics.json` (line-delimited
per-point k6 JSON) + `summary.json` (end-of-test aggregate). The orchestrator wraps
`run.sh` with restore, warm-up (discarded), `repetitions`, the concurrency-ladder
sweep, and Prometheus remote-write; reporting turns the per-level JSON into the
published throughput-vs-concurrency curves.

## Env vars (set by `run.sh` / orchestrator, overridable)

`BASE_URL` (required, …/fhir/r4) · `CONCURRENCY` (required — VUs for this level) ·
`P99_MS` · `MAX_ERROR_RATE` · `DURATION` · `POOL_SIZE` (ids to pool for reads) ·
`READ_MIX_WEIGHTS` (JSON, override the read distribution) · `SUMMARY_OUT` ·
`CONCURRENCY_LEVELS` (orchestrator: override the ladder for all scenarios, e.g. `"1 8 32"`).
