# Load model — closed-model concurrency sweep

> How this benchmark drives load, what it measures, and why. Read alongside
> `docs/proposal.md` (the fairness charter) and `scenarios/README.md` (the scripts).

## TL;DR

Every workload is driven as a **closed model**: a fixed number of concurrent
clients (k6 VUs), each issuing requests back-to-back (send → await reply → send
next, no think-time). We **sweep concurrency** across a ladder of levels
(`1, 2, 4, … N`) and measure each level to steady state. The independent variable
is **concurrency**; the headline output is **throughput (req/s) at each concurrency**,
reported per server and normalized **per vCPU**.

This is the widely-understood way to compare server performance — "how much
throughput, and what latency, at N concurrent clients" — and at equal concurrency
the throughput comparison across servers is direct and fair.

## Why closed model

- **Intuitive, standard comparison.** Throughput-vs-concurrency is how most server
  benchmarks (incl. TechEmpower) present results. "At 128 concurrent clients server
  A does 5,000 req/s, server B does 800 req/s" is a statement everyone understands.
- **Throughput becomes a real measurement.** Concurrency is an *input* we set
  exactly, so throughput is the server's *measured* output — the differentiator.
  (Under an open arrival-rate model, every server that keeps up just reports the
  offered rate, so throughput can't rank anything.)
- **No load-generator artifacts.** A VU never issues its next request until the
  previous reply returns, so the generator never needs an unbounded VU pool and
  there are **no dropped iterations / VU-starvation** effects to corrupt the load.
- **Fair at equal concurrency.** All servers face the same `N` concurrent clients,
  same dataset, same envelope. Throughput at a fixed `N` is a direct count, not a
  modeled quantity.

## The one caveat we state openly: tail latency under saturation

The closed model has a known property — **coordinated omission**: when a server is
*saturated*, a slow response delays that client's *next* request, so the client
issues fewer requests during the slow window and the slowest moments are
under-sampled. The effect is that **latency percentiles (esp. the tail) read
optimistically once a server is past its knee**, and more so for slower servers.

We handle this honestly rather than hide it:

1. **Throughput is the headline; latency is secondary.** Throughput at fixed
   concurrency is *not* affected by coordinated omission (it's a direct count), so
   the primary comparison is unbiased.
2. **Latency columns are labeled `closed-model per-request percentiles`** in the
   report, so a reviewer knows they are not coordinated-omission-corrected and are
   conservative for fast servers / optimistic for saturated ones.
3. **The SLO is read off the pre-saturation region**, where closed and open models
   agree: we report *max throughput while p99 < SLO* — the highest concurrency at
   which p99 is still under the bar, and the throughput there. Below the knee, the
   tail is trustworthy; that is exactly the region the SLO cares about.

> If we ever need coordinated-omission-corrected tails for the *post-knee* region,
> the fair tool is an open-model arrival-rate sweep (k6 `constant-arrival-rate`);
> it is intentionally out of scope here and would be added as a clearly-separate
> view, never mixed into these numbers.

## Workloads

Same operation mixes as before; only the load model changes.

| Workload | Ops | State |
|---|---|---|
| `read-mix` | weighted read blend: instance read (45%), patient search (20%), obs-for-patient (20%), cond-for-patient (10%), history (5%) | read-only — DB state identical across the whole sweep |
| `ingest` | POST `Patient + Encounter + 2×Observation` **transaction bundle** (the PR #165 system endpoint) | writes — DB state reset before **every** concurrency level |

The standalone `saturation` scenario is **removed**: the concurrency sweep *is* the
saturation curve. Throughput rises with concurrency, then plateaus (or latency
climbs) at the server's capacity — the knee is visible directly, with no fragile
ramp-abort / run-duration reverse-engineering.

## Per-level protocol

For each `(server, workload, concurrency C)`, repeated `repetitions` times:

```
read-mix (read-only):                ingest (writes):
  restore snapshot   ── once/rep       for each C:
  warm-up (discard)  ── once/rep         restore snapshot   (clean state)
  for each C:                            warm-up (discard)
    measure C  (constant-vus)            measure C  (constant-vus)
```

- **Reads** reuse one restored, warmed snapshot across the whole ladder — reads do
  not mutate state, so re-restoring per level would only waste time.
- **Writes** restore before each level so accumulated writes from one level never
  bias the next; every level starts from the identical frozen snapshot (charter §6).
- **Warm-up** (`run.warmup_s`, discarded) warms JIT / page cache / DB buffers /
  pools. **Measure** (`run.measure_s`) at constant concurrency is the only captured
  data. Then cool-down.
- **Repeat ≥ `run.repetitions`**; the report headlines the median and shows spread.

## Metrics

**Primary (fair, coordinated-omission-immune):**
- **Throughput** (req/s) at each concurrency — median across reps.
- **Throughput per vCPU** (÷ `limits.sut_cpus`) — the fairness-normalized headline.
- **Peak throughput** and the concurrency at which it occurs (≈ capacity).
- **Max throughput while p99 < SLO** — highest concurrency meeting the p99 + error
  SLO, and the throughput there.

**Secondary (labeled closed-model per-request percentiles):**
- p50 / p95 / p99 / p99.9 and error rate at each concurrency.

## Configuration

Everything is config-driven in `bench.config.yaml`:

```yaml
run:
  scenarios: [read-mix, ingest]   # closed-model concurrency sweeps
workload:
  read-mix:
    concurrency_levels: [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]
  ingest:
    concurrency_levels: [1, 2, 4, 8, 16, 32, 64]   # writes are heavier → lower ceiling
slo:
  p99_ms: 500                     # reads
  per_scenario:
    ingest: { p99_ms: 1000 }      # transaction-bundle writes are heavier
```

Env overrides for iteration/smoke: `CONCURRENCY_LEVELS="1 8 32"` truncates the
ladder for all scenarios; `REPS`, `WARMUP_S`, `MEASURE_S`, `COOLDOWN_S` size the
windows; `SCENARIOS` selects workloads. A single standalone level:
`CONCURRENCY=32 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s`.

## Output layout

```
results/<server>/<workload>/rep-<r>/c-<C>/summary.json   # one k6 summary per level
results/<server>/run-manifest.json                       # ladders, windows, SLO, provenance
results/report.md, report.csv                            # throughput-vs-concurrency curves
```

## Cost note

A sweep multiplies wall-clock: `levels × reps × (warmup + measure + cooldown)` per
workload per server. With 10 read levels × 3 reps × (90s + 600s + 60s) ≈ 6.3 h of
read-mix per server before seed/restore overhead. Trim via shorter `measure_s`, a
coarser ladder, or fewer reps for iteration; use the full ladder for headline runs.
The report logs exactly which levels ran so a truncated ladder is never mistaken
for full coverage.
```
