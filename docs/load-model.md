# Load model — open-model offered-rate sweep

> How this benchmark drives load, what it measures, and why. Read alongside
> `docs/proposal.md` (the fairness charter) and `scenarios/README.md` (the scripts).

## TL;DR

Every workload is driven as an **open model**: k6 issues requests at a fixed
**offered rate** (req/s) on a clock, independent of how fast the server responds
(`constant-arrival-rate`). We **sweep the offered rate** across a ladder
(`50, 100, 200, …`) and measure each level to steady state. The independent variable
is **offered rate**; the headline output is **max sustainable throughput** — the
highest offered rate the server keeps up with while staying under the latency SLO,
reported per server and per vCPU.

## Why open model

- **Honest tail latency (no coordinated omission).** Because requests arrive on a
  clock, a slow response cannot throttle the offered load — when the server stalls,
  the requests that pile up all record the full delay. A closed model (fixed VUs,
  each waiting for its reply before sending again) under-samples a server's slow
  moments and reports an optimistic tail. Since our headline is *tail latency at an
  SLO*, the open model is the fair tool. (This is what `docs/proposal.md` §5 argued.)
- **The metric we actually want.** "Max sustainable throughput @ p99 < 500 ms" is, by
  definition, a statement about *offered rate* — exactly the quantity this model sets.
- **Defensible.** Coordinated omission is the first thing a knowledgeable reviewer
  checks; the open model removes that line of attack.

## Offered rate vs achieved throughput

At a fixed offered rate `R`, the measured (achieved) throughput is:

```
achieved = min(offered R, server_capacity)
```

- Below the server's capacity, `achieved ≈ R` and latency stays flat — the server is
  keeping up. (So a single rate doesn't reveal the maximum; every capable server just
  returns the offered rate. The maximum only emerges from the *sweep*.)
- Above capacity, `achieved` plateaus at the server's real limit, the backlog grows,
  latency climbs, and eventually the load generator runs out of VUs to hold in-flight
  requests → **dropped iterations**.

**Max sustainable throughput** = the highest offered rate where the server still
delivered the rate (achieved ≈ offered, no dropped iterations) **and** p99 < SLO and
errors < max. That is the knee, read straight off the latency-vs-rate curve.

## The one thing the open model needs: VU headroom + a dropped-iterations guard

The executor needs a free VU to hold each in-flight request — required VUs ≈
`offered_rate × latency_seconds` (Little's Law). If the pool is too small, k6 can't
issue the scheduled requests and the *actual* offered rate silently drops below
target — which would mislabel the **load generator's** ceiling as the **server's**.

We handle this explicitly:

- `run.sh` sizes the pool from the rate: `preAllocatedVUs ≈ rate/2` (covers up to ~the
  p99 SLO, so under-SLO operation never waits on mid-test allocation) and
  `maxVUs ≈ rate×3` (headroom to ~3 s of latency).
- k6's **`dropped_iterations`** counter is captured per level. `report.py` treats any
  level with `dropped > 0` as "offered rate not delivered" (server saturated) and
  **excludes it from max-sustainable**. A non-zero `Dropped` column in the report is
  the visible flag. This is the fix for the silent VU-starvation failure mode.

## Workloads

| Workload | Ops | State |
|---|---|---|
| `read-mix` | weighted read blend: instance read (45%), patient search (20%), obs-for-patient (20%), cond-for-patient (10%), history (5%) | read-only — DB state identical across the whole sweep |
| `ingest` | POST `Patient + Encounter + 2×Observation` **transaction bundle** (the PR #165 system endpoint) | writes — DB state reset before **every** rate level |

There is no separate `saturation` scenario: the rate sweep *is* the saturation curve.
Latency stays flat while the server keeps up, then climbs at the knee — no fragile
ramp-abort / run-duration reverse-engineering.

## Per-level protocol

For each `(server, workload, offered rate R)`, repeated `repetitions` times:

```
read-mix (read-only):                ingest (writes):
  restore snapshot   ── once/rep       for each R:
  warm-up (discard)  ── once/rep         restore snapshot   (clean state)
  for each R:                            warm-up (discard)
    measure R  (constant-arrival)        measure R  (constant-arrival)
```

- **Reads** reuse one restored, warmed snapshot across the whole ladder (reads don't
  mutate state). Warm-up runs at the top of the ladder (max stress).
- **Writes** restore before each level so accumulated writes never bias the next;
  every level starts from the identical frozen snapshot (charter §6).
- **Warm-up** (`run.warmup_s`, discarded) warms JIT / page cache / DB buffers / pools.
  **Measure** (`run.measure_s`) at constant offered rate is the only captured data.
  Then cool-down. **Repeat ≥ `run.repetitions`**; the report headlines the median.

## Metrics

**Primary:**
- **Max sustainable throughput** (req/s) — highest offered rate meeting the SLO with
  the rate delivered — and **per vCPU** (÷ `limits.sut_cpus`), the fairness headline.
- **Latency-vs-rate curve**: achieved throughput, p50 / p95 / p99 / p99.9, error rate,
  and dropped iterations at each offered rate. Tails are coordinated-omission-free.

## Configuration

```yaml
run:
  scenarios: [read-mix, ingest]    # open-model offered-rate sweeps
workload:
  read-mix:
    rate_levels: [50, 100, 200, 400, 800, 1600, 3200]   # req/s offered
  ingest:
    rate_levels: [10, 25, 50, 100, 200]                 # bundles/s — writes are heavier
slo:
  p99_ms: 500                      # reads
  per_scenario:
    ingest: { p99_ms: 1000 }       # transaction-bundle writes are heavier
```

Ladders are log-spaced and extend past where a 4-vCPU server saturates so the knee is
bracketed. **Two-phase refinement:** run the coarse ladder, see where the knee falls,
then a cheap second pass with `RATE_LEVELS` set to a few rates bracketing it
(e.g. `RATE_LEVELS="2000 2400 2800"`). Env overrides for iteration/smoke:
`RATE_LEVELS="50 200"` truncates the ladder for all scenarios; `REPS`, `WARMUP_S`,
`MEASURE_S`, `COOLDOWN_S` size the windows; `SCENARIOS` selects workloads. A single
standalone level: `RATE=400 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s`.

## Output layout

```
results/<server>/<workload>/rep-<r>/rate-<R>/summary.json   # one k6 summary per level
results/<server>/run-manifest.json                          # ladders, windows, SLO, provenance
results/report.md, report.csv                               # latency-vs-rate curves + headline
```

## Cost note

A sweep multiplies wall-clock: `levels × reps × (warmup + measure + cooldown)` per
workload per server. Trim via shorter `measure_s` (steady-state percentiles settle
well before 600 s), a coarser ladder, or fewer reps for iteration; use the full ladder
for headline runs. The report logs which levels ran so a truncated ladder is never
mistaken for full coverage.
