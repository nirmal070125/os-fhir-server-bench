# scenarios/

k6 load scripts for the benchmark. **Two load models**, selected by `LOAD_MODEL`
(default `closed`, falls back to `run.load_model` in the config):

- **closed** (default) — `constant-vus`: N concurrent clients (VUs), each looping
  send → await reply → send next. Concurrency is the input; throughput is the output.
  The field-standard "N users" shape.
- **open** — `constant-arrival-rate`: a fixed offered req/s on a clock; a slow server
  piles up a backlog rather than throttling the load (coordinated-omission-free tails).

The orchestrator **sweeps a ladder of levels** (concurrency for closed, offered rate
for open) and measures each — see [`docs/load-model.md`](../docs/load-model.md).

| Scenario | What it measures |
|---|---|
| `read-mix.js` | Read-dominated real-world traffic (instance read, patient search, obs/cond-for-patient, history). Read-only → DB state identical across the whole sweep. |
| `ingest.js` | Writes: POSTs `Patient+Encounter+2×Observation` **transaction bundles** (the PR #165 endpoint). Snapshot restored before each level. |

Both scripts pick their executor via `executor()` (closed/open) — there's no separate
saturation scenario; the sweep *is* the saturation curve.

`lib/common.js` holds the shared bits — required `BASE_URL`, SLO thresholds (no abort),
the `op`-tagged latency/error metrics, both executors + the `executor()` selector, and
`setup()` id-pooling (it pages the server's own API for real ids, so no fixture file).

## Running

One level per invocation. **Closed** needs `CONCURRENCY`; **open** needs `LOAD_MODEL=open`
+ `RATE` (run.sh then sizes the VU pool). SLO knobs come from `bench.config.yaml` (`slo.*`):

```bash
# closed model (default): N concurrent clients
CONCURRENCY=32 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
CONCURRENCY=8  scenarios/run.sh ingest   http://localhost:9090/fhir/r4 60s

# open model: offered req/s
LOAD_MODEL=open RATE=400 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
```

Output for each invocation → `results/<scenario>/`: `metrics.json` (line-delimited
per-point k6 JSON) + `summary.json` (end-of-test aggregate). The orchestrator wraps
`run.sh` with restore, warm-up (discarded), `repetitions`, the ladder sweep, and
Prometheus remote-write; reporting turns the per-level JSON into the published curves.

## Env vars (set by `run.sh` / orchestrator, overridable)

`BASE_URL` (required, …/fhir/r4) · `LOAD_MODEL` (closed|open) · `CONCURRENCY` (closed:
VUs for this level) · `RATE` (open: offered req/s) · `P99_MS` · `MAX_ERROR_RATE` ·
`DURATION` · `PREALLOCATED_VUS` / `MAX_VUS` (open: VU pool, auto-sized from `RATE`) ·
`POOL_SIZE` (ids to pool for reads) · `READ_MIX_WEIGHTS` (JSON) · `SUMMARY_OUT` ·
`CONCURRENCY_LEVELS` / `RATE_LEVELS` (orchestrator: override the ladder for all scenarios).
