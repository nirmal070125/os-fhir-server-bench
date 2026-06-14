# Load model — closed (default) or open

> How this benchmark drives load, what it measures, and why. Read alongside
> `docs/proposal.md` (the fairness charter) and `scenarios/README.md` (the scripts).

## TL;DR

The harness supports **two load models**, selected by `run.load_model` in
`bench.config.yaml` (or the `LOAD_MODEL` env override). Both **sweep a ladder of
levels** (one level per measured window) and report per server, per vCPU.

| | **closed** (default) | **open** |
|---|---|---|
| You set | **concurrency** — N clients (VUs), each send→await→send | **offered rate** — req/s on a clock |
| What emerges | throughput | backlog / latency |
| k6 executor | `constant-vus` | `constant-arrival-rate` |
| Ladder | `workload.*.concurrency_levels` | `workload.*.rate_levels` |
| Headline | peak throughput + max throughput @ p99<SLO | max sustainable throughput @ p99<SLO |
| Tail latency | optimistic past saturation (coordinated omission) | honest (CO-free) |

**Closed is the default** because it's the field-standard "N concurrent users" shape —
directly comparable to published FHIR-server benchmarks (HAPI, Blaze, fhir-benchmarks.com)
and intuitive for capacity planning. **Open** is available for coordinated-omission-free
tail latency when that's the priority.

## Choosing a model

- **closed** (default): you want results **comparable to the rest of the field**, the
  intuitive "throughput & latency at N concurrent clients" story, and throughput as a
  directly-measured (CO-immune) headline. Caveat: closed-model latency percentiles read
  **optimistically once a server is past its knee** (coordinated omission) — so we
  headline *throughput* and treat near-cliff tails as indicative.
- **open**: you want **coordinated-omission-free tail latency** as the headline — a
  slow server piles up a backlog instead of throttling the offered load, so its slow
  moments aren't under-sampled. Costs some operational complexity (VU-pool sizing +
  dropped-iteration handling, below).

Both are **internally fair**: every server runs through the same harness with the same
model, so the server-vs-server comparison is self-consistent either way. The choice only
affects CO-honesty of tails and comparability with externally-published numbers.

## What each model measures

**closed** — `throughput = concurrency / latency` (Little's Law). Throughput rises with
concurrency, then plateaus at the knee; latency climbs past it. Headline: **peak
throughput** (capacity) and **max throughput while p99 < SLO**.

**open** — `achieved = min(offered_rate, server_capacity)`. Below capacity `achieved ≈
offered` and latency is flat; above it the backlog grows, latency climbs, and the load
generator eventually can't issue the scheduled requests → **dropped iterations**.
Headline: **max sustainable throughput** = highest offered rate delivered (achieved ≈
offered, no drops) with p99 < SLO.

## Open model only: VU headroom + dropped-iterations guard

The arrival-rate executor needs a free VU per in-flight request (≈ `rate × latency`,
Little's Law). If the pool is too small, k6 can't issue the scheduled requests and the
*actual* offered rate silently drops — mislabeling the **load generator's** ceiling as
the **server's**. So `run.sh` sizes the pool from the rate (`preAllocatedVUs ≈ rate/2`,
`maxVUs ≈ rate×3`), and `report.py` **excludes any level with `dropped_iterations > 0`**
from max-sustainable (a visible `Dropped` column flags it). The closed model has no such
issue — concurrency is fixed, so there's nothing to drop.

## Workloads (same for both models)

| Workload | Ops | State |
|---|---|---|
| `read-mix` | weighted read blend: instance read (45%), patient search (20%), obs-for-patient (20%), cond-for-patient (10%), history (5%) | read-only — DB state identical across the whole sweep |
| `ingest` | POST `Patient + Encounter + 2×Observation` **transaction bundle** (the PR #165 system endpoint) | writes — DB state reset before **every** level |

There's no separate `saturation` scenario: the sweep *is* the saturation curve.

## Per-level protocol

For each `(server, workload, level)`, repeated `repetitions` times:

```
read-mix (read-only):              ingest (writes):
  restore snapshot   ── once/rep     for each level:
  warm-up (discard)  ── once/rep       restore snapshot   (clean state)
  for each level:                      warm-up (discard)
    measure (capture)                  measure (capture)
```

- **Reads** reuse one restored, warmed snapshot across the whole ladder (reads can't
  mutate state); warm-up runs at the top of the ladder.
- **Writes** restore before each level so accumulated writes never bias the next
  (charter §6) — via the fast template-clone restore (`dataset/restore_postgres.sh`).
- **Warm-up** (`run.warmup_s`, discarded) warms JIT / page cache / DB buffers / pools;
  **measure** (`run.measure_s`) is the only captured data; then cool-down. Repeat ≥
  `run.repetitions`; the report headlines the median.

## Configuration

```yaml
run:
  load_model: closed               # closed (default) | open
  scenarios: [read-mix, ingest]
workload:
  read-mix:
    concurrency_levels: [1, 8, 32, 64, 128, 256]   # closed: # of clients
    rate_levels: [50, 100, 200, 400]               # open: req/s offered
  ingest:
    concurrency_levels: [1, 4, 8, 16, 32]
    rate_levels: [10, 25, 50, 100]
slo:
  p99_ms: 500
  per_scenario: { ingest: { p99_ms: 1000 } }
```

Ladders are log-spaced and reach past where a 4-vCPU server saturates so the knee is
bracketed. **Two-phase refinement:** run the coarse ladder, see where the knee falls,
then a cheap second pass bracketing it via `CONCURRENCY_LEVELS="48 64 96"` (closed) or
`RATE_LEVELS="500 650 800"` (open). Env overrides: `LOAD_MODEL`, `CONCURRENCY_LEVELS` /
`RATE_LEVELS` (truncate the ladder for all scenarios), `REPS`, `WARMUP_S`, `MEASURE_S`,
`COOLDOWN_S`, `SCENARIOS`. Standalone single level:
`CONCURRENCY=32 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s`
(or `LOAD_MODEL=open RATE=400 …`).

## Output layout

```
results/<server>/<workload>/rep-<r>/<c-N|rate-R>/summary.json   # one k6 summary per level
results/<server>/run-manifest.json                              # load_model, ladders, windows, SLO
results/report.md, report.csv                                   # model-appropriate curves + headline
```

`report.py` reads `load_model` from the manifest and renders the matching report
(throughput-vs-concurrency for closed, latency-vs-rate for open).

## Cost note

A sweep multiplies wall-clock: `levels × reps × (warmup + measure + cooldown)` per
workload per server. Trim via shorter `measure_s` (steady-state percentiles settle well
before 600 s), a coarser ladder, or fewer reps for iteration; use the full ladder for
headline runs. The report logs which levels ran so a truncated ladder is never mistaken
for full coverage.
