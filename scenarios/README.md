# scenarios/

k6 load scripts for the benchmark. **Open model** (`constant-arrival-rate`: k6 issues
a set number of requests/sec on a clock, independent of how fast the server responds).
The offered rate is the input we set exactly; achieved throughput and latency are the
outputs. The orchestrator **sweeps the offered rate** across a ladder and measures each
level — see [`docs/load-model.md`](../docs/load-model.md).

| Scenario | Executor | What it measures |
|---|---|---|
| `read-mix.js` | constant-arrival-rate | Read-dominated real-world traffic at a fixed offered req/s. Read-only → DB state is identical across the whole sweep. |
| `ingest.js` | constant-arrival-rate | Writes: POSTs `Patient+Encounter+2×Observation` **transaction bundles** (the PR #165 endpoint) at a fixed offered bundles/s. Snapshot restored before each level. |

There is no separate saturation scenario: the rate sweep *is* the saturation curve —
latency stays flat while the server keeps up, then climbs at the knee.

`lib/common.js` holds the shared bits — required `BASE_URL`, SLO thresholds (no
abort), the `op`-tagged latency/error metrics, the `constant-arrival-rate` executor,
and `setup()` id-pooling (it pages the server's own API for real ids, so no external
fixture file is needed).

## Running

`RATE` (the offered-rate level to measure) is required; SLO knobs come from
`bench.config.yaml` (`slo.*`). `run.sh` sizes the k6 VU pool from the rate (enough
in-flight headroom; see docs/load-model.md). One rate level per invocation:

```bash
# one workload at one offered rate, against a running server (seed it first)
RATE=400 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
RATE=50  scenarios/run.sh ingest   http://localhost:9090/fhir/r4 60s
```

Output for each invocation → `results/<scenario>/`: `metrics.json` (line-delimited
per-point k6 JSON) + `summary.json` (end-of-test aggregate). The orchestrator wraps
`run.sh` with restore, warm-up (discarded), `repetitions`, the rate-ladder sweep, and
Prometheus remote-write; reporting turns the per-level JSON into the published
latency-vs-rate curves and the max-sustainable-throughput headline.

## Env vars (set by `run.sh` / orchestrator, overridable)

`BASE_URL` (required, …/fhir/r4) · `RATE` (required — offered req/s for this level) ·
`P99_MS` · `MAX_ERROR_RATE` · `DURATION` · `PREALLOCATED_VUS` / `MAX_VUS` (VU pool;
auto-sized from `RATE` by `run.sh`) · `POOL_SIZE` (ids to pool for reads) ·
`READ_MIX_WEIGHTS` (JSON, override the read distribution) · `SUMMARY_OUT` ·
`RATE_LEVELS` (orchestrator: override the ladder for all scenarios, e.g. `"50 200"`).
