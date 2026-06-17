# FHIR Server Performance Benchmark — Proposal

> Status: proposal for review. Goal: a **fair, unbiased** performance benchmark of
> `fhir-server-go` against well-known **open-source** FHIR servers, to see where we stand.
> Decisions locked: load tool = **k6**; first run includes **all six servers**.

---

## 1. Goals & fairness charter

The biggest risk in a vendor-run benchmark is unconscious bias. We lock that down up
front with a written charter; everything else follows from it.

1. **Black-box, conformance-driven.** Every server is hit only through its public FHIR
   REST API. No server-specific shortcuts; no privileged bulk loader for one and the API
   for another.
2. **Identical logical dataset.** Same FHIR resources loaded into every server, from the
   same source bundles, via the same path (see §6).
3. **Identical hardware envelope.** Every System-Under-Test (SUT) runs in a container with
   the *same* CPU/memory limits, on the *same* host class, with the load generator on a
   *separate* host.
4. **Reasonably-tuned, not hand-tuned-for-us.** Each server gets its documented "production
   defaults" plus the minimal tuning its own docs recommend (JVM heap, DB pool size, etc.).
   We do **not** micro-optimize ours while leaving others on dev defaults. All configs are
   committed to the repo for review.
5. **Latest stable, same FHIR version (R4).** Pin exact versions; record them in the report.
6. **Open methodology.** Harness, configs, dataset-generation seed, and raw results are all
   published so anyone can reproduce or challenge the numbers. We should be comfortable
   handing this to a HAPI maintainer.
7. **We report where we lose, too.** A credible benchmark names the scenarios where we're
   slower. That is the whole point — "see where we stand."
8. **Reproducible by anyone, from scratch.** The whole benchmark ships as a public git repo.
   Every step — provision, bootstrap, seed, run, collect, report, teardown — is scripted and
   non-interactive. Every external dependency (cloud creds, region, VM sizes, server
   versions, dataset size, SLOs, run durations) is set through a single config file / env
   vars, never hard-coded. A third party should reproduce our results on their own Azure
   subscription by editing one config and running one command. See §9.

> ⚠️ Fairness trap: storage engines differ (we use Postgres; Blaze uses RocksDB; MS uses
> SQL Server). **"Same underlying database state" therefore means the same logical FHIR
> dataset, restored to a known snapshot before each run — NOT the same physical DB.** We
> can't and shouldn't force everyone onto one engine.

---

## 2. Servers under test (open-source only)

| Server | Lang / stack | Storage | Notes |
|---|---|---|---|
| **fhir-server-go** (ours) | Go, chi, pgx | PostgreSQL (normalized search schema) | The subject. Build from `feat/fhir-server-go-transaction-bundle` (needs the system-level bundle endpoint). |
| **HAPI FHIR JPA Server** | Java / Spring | PostgreSQL | The de-facto OSS reference; the number everyone trusts. |
| **Microsoft FHIR Server** | .NET | SQL Server | Widely deployed, Azure lineage. |
| **LinuxForHealth / IBM FHIR Server** | Java (Jakarta) | PostgreSQL | Strong R4 conformance. |
| **Medplum** | TypeScript / Node | PostgreSQL + Redis | Modern, Postgres-backed like us. |
| **Blaze** | Clojure | RocksDB | Known to be *very* fast — a useful "ceiling" reference. |

**Explicitly excluded** because they aren't open source / freely deployable: Aidbox,
Firely Server (Vonk), Google Cloud Healthcare API, Smile CDR. Including those would muddy
the "open source" framing.

We benchmark only operations **every** server supports (intersection of CapabilityStatements)
so the comparison stays apples-to-apples.

---

## 3. Workload — the API call mix

Built from how SMART-on-FHIR apps and EHR integrations actually hit a server. Each scenario
is a named, versioned k6 script.

**Read-heavy mix (realistic steady state, ~80% of traffic):**
- `GET /Patient/{id}` — instance read (the single most common call)
- `GET /Observation?patient={id}&category=vital-signs&_count=50` — classic chart-load query
- `GET /Patient?name={x}&birthdate={y}` — demographic search
- `GET /Encounter?patient={id}&_sort=-date` — sorted search
- `GET /Observation?patient={id}&_include=Observation:patient` — `_include`
- `GET /Condition?patient={id}&_revinclude=...` — `_revinclude` (drop if not universal)

**Write mix (~15%):**
- `POST /{resourceType}` — create single resource
- `PUT /{resourceType}/{id}` — update (conditional update as a variant)
- `POST /` transaction Bundle (10–30 entries) — the ingest path

**Heavy / complex (~5%, run as isolated scenarios, not blended into the mix):**
- `GET /Patient/{id}/$everything` — compartment fetch (only if all SUTs support it)
- Deep chained search, e.g. `GET /Observation?patient.name={x}`
- `_count` pagination walk (page through a large result set)

**Three distinct test profiles** (run separately, never mixed):
1. **Ingest / write throughput** — pure bulk-load of N transaction bundles. Measures write
   path + indexing cost.
2. **Read/search steady state** — the 80/15/5 blend above, at controlled arrival rate.
3. **Stress-to-saturation** — ramp arrival rate until latency knee / errors, to find max
   sustainable throughput per server.

---

## 4. Metrics

**Primary (client-side, from the load generator):**
- Throughput — sustained requests/sec
- Latency distribution — **p50 / p90 / p95 / p99 / p99.9** and max (percentiles, never just
  mean — the tail is the story)
- Error rate — non-2xx, plus FHIR `OperationOutcome` errors and timeouts
- **Max sustainable throughput** — highest arrival rate where p99 stays under an SLO
  (e.g. p99 < 500 ms) and errors < 0.1%

**Secondary (server-side, from monitoring):**
- CPU utilization (SUT container + DB container, tracked separately)
- Memory: RSS, and for JVM/CLR servers heap + **GC pause time/frequency** (a real
  differentiator vs Go)
- DB connection-pool saturation, DB CPU
- Cold-start / time-to-first-healthy (`/health/ready` for ours)
- Ingest time for the full reference dataset

**Efficiency framing (the fairest single number):** throughput **per vCPU**, and latency
**at an equal CPU budget**. Raw req/s favors whoever we gave more cores; normalizing by
resources is what makes "where we stand" honest.

---

## 5. Methodology (standards compliance)

Per server, per scenario:

1. **Cold-state reset** → restore the DB snapshot so every run starts from identical state (§6).
2. **Server start + readiness gate** → start container, poll health endpoint, record
   cold-start time.
3. **Warm-up** → run the workload at target rate for a fixed window (60–120 s). **Discard**
   these results. Warms JVM JIT, OS page cache, DB buffer cache, connection pools. Critical
   for fairness — without warm-up, JIT-compiled servers look terrible, which would unfairly
   *flatter* our Go server.
4. **Steady-state measurement** → fixed window (5–10 min) at constant load. The only data
   that counts.
5. **Cool-down** → idle gap before next run.
6. **Repeat N ≥ 3 times** per (server, scenario); report **median + min/max or 95% CI**.
   Single runs are noise.

**Load model — open, not closed.** Use a **constant-arrival-rate** (open-model) executor so
a slow server doesn't artificially throttle the offered load. This avoids **coordinated
omission** — the #1 way naive benchmarks lie about tail latency. Tool: **k6**
(`constant-arrival-rate` executor) — scriptable in JS, native headless, native percentile
output, first-class Prometheus/InfluxDB push for centralized reporting.

> **Refined — see [`load-model.md`](load-model.md).** The implemented benchmark supports
> **both** models via `run.load_model`, and **defaults to closed** (`constant-vus`, a
> concurrency sweep) — the field-standard "N concurrent users" shape, which keeps our
> numbers comparable to published FHIR-server benchmarks and is internally fair since we
> run every server through the same harness. The **open** model above remains available
> (`LOAD_MODEL=open`) for coordinated-omission-free tail latency. Either way it's a
> *stepped sweep* (one level per measured window — the sweep *is* the saturation curve),
> not a single fixed point, and the separate ramping `saturation` scenario is gone. Under
> closed model we headline throughput (CO-immune) and treat near-saturation tails as
> indicative; under open we size the VU pool from the rate and flag `dropped_iterations`
> so the load generator's ceiling is never mistaken for the server's.

**Isolation rules:**
- Load generator on a **separate host** from the SUT (otherwise you measure the generator's
  CPU contention).
- Pin SUT + DB to fixed CPU/memory via container limits (cgroups). Same limits for all.
- Quiet, dedicated network; record round-trip baseline ping.
- One SUT live at a time per host; everything else stopped. (Parallel mode runs several
  servers at once, but each on its **own** SUT+loadgen lane — never two SUTs on one host.
  Lanes are pinned to availability zones round-robin over [1,2,3]; with ≤ 3 lanes each gets
  a distinct zone, so SUTs never share a physical host. Beyond 3 lanes some share a zone —
  still separate VMs, but Azure doesn't guarantee distinct hosts within a zone, so the
  strict-isolation **headline** run uses sequential or ≤ 3 parallel lanes.)
- Same OS, kernel, Docker version across runs.

**Statistical hygiene:** record exact versions, configs, dataset hash, and host specs in
every result file so a number is never orphaned from its conditions.

---

## 6. Same database state across servers

1. **Generate one reference dataset with [Synthea](https://github.com/synthetichealth/synthea)**
   — realistic synthetic patients, fixed RNG seed so it's reproducible. Size tiers:
   **Small = 1k patients**, **Medium = 10k**, **Large = 100k** (with proportional
   Observations / Encounters / Conditions). **Headline results published on Large (100k).**
   Small/Medium are used while building/iterating on the harness; Large is the number we
   publish. Budget for it: bigger VM disks, longer generate/seed/snapshot/restore cycles.
2. **Load identically** — POST the Synthea transaction bundles through each server's FHIR
   API (same bundles, same order). No server gets a privileged backdoor importer. (If we
   later add an `$import`/bulk *ingest-specific* test, all servers use their equivalent and
   we label it separately.)
3. **Snapshot after load** — once loaded + indexed, take a storage-level snapshot
   (Postgres `pg_basebackup` / volume snapshot; RocksDB dir copy for Blaze; SQL Server
   backup for MS; etc.).
4. **Restore before every run** — each scenario starts from that frozen snapshot, so writes
   from one run never leak into the next. This guarantees the same underlying state against
   each solution.

---

## 7. Infrastructure

```
┌─────────────────┐        ┌──────────────────────────────┐
│ Load Generator  │  HTTP  │  SUT host (one server at a    │
│ (k6, headless)  │───────▶│  time, fixed CPU/mem limits)  │
│  separate host  │        │   ├─ FHIR server container    │
└────────┬────────┘        │   └─ DB container (snapshot)  │
         │ push metrics    └───────────────┬──────────────┘
         ▼                                 │ exporters
┌─────────────────────────────────────────▼──────────────┐
│ Observability + results (central)                       │
│  Prometheus (+ node_exporter, cAdvisor, db exporters)   │
│  InfluxDB or Prometheus ← k6 results                    │
│  Grafana dashboards   │  Object store (S3/GCS): raw     │
│                       │  JSON + generated HTML reports  │
└─────────────────────────────────────────────────────────┘
```

**Sizing (a sane starting point):**
- SUT host: 8 vCPU / 32 GB (limits per container e.g. 4 vCPU / 8 GB to the server, rest to
  DB — identical for all).
- Load-gen host: 8 vCPU / 16 GB (must out-class the SUT so it never bottlenecks).
- Observability host: 4 vCPU / 16 GB + disk for the TSDB.

**Where to run:** any single cloud (GCP/AWS/Azure) with fixed instance types. Although this
is a natural OpenChoreo dogfooding story, for a *fair benchmark* run it on **plain dedicated
cloud VMs first** — K8s scheduling jitter and shared-tenant noise hurt reproducibility. Use
Terraform to make the infra reproducible and disposable.

> Note: all six servers means two extra storage engines to stand up — **SQL Server** (for
> Microsoft FHIR Server) and **Db2/Postgres** (for IBM/LinuxForHealth). Budget extra setup
> time for these two; phase them in after the Postgres-native set is green (see §9).

---

## 8. Headless execution + centralized reporting

- **Orchestration:** a CI pipeline (GitHub Actions) or a single driver script that iterates
  `servers × scenarios × repetitions`, doing reset → start → warm-up → measure → collect →
  teardown for each. Fully non-interactive.
- **Trigger:** manual dispatch + optional nightly/weekly cron so we track our own regressions
  over time, not just one-shot comparisons.
- **Results capture (three layers):**
  1. **Time-series** → k6 pushes to Prometheus/InfluxDB; node/cAdvisor/db exporters feed the
     same store. Live + historical Grafana dashboards.
  2. **Raw artifacts** → each run's full k6 JSON summary + server resource samples + the exact
     config/version manifest, written to an object-storage bucket keyed by run-id.
  3. **Human report** → a generated comparison (Markdown/HTML) with percentile tables,
     throughput-per-vCPU charts, and saturation curves, committed to a results repo per run
     so the history is diffable.
- A persistent **Grafana dashboard** becomes the "where we stand" single pane: latency
  percentiles and max-throughput bar charts across all servers, filterable by scenario and
  dataset size.

---

## 9. Reproducibility & the published git repo

The benchmark is delivered as a new **public git repo** —
**`github.com/nirmal070125/os-fhir-server-bench`** — that a stranger can clone, point at
their own Azure subscription, and reproduce end-to-end. Nothing runs by hand; nothing is
hard-coded.

### Repo layout

```
os-fhir-server-bench/
├── README.md                  # quickstart: 3 commands to reproduce
├── bench.config.yaml          # THE single source of truth (see below)
├── .env.example               # secrets template (Azure creds, etc.) — never commit .env
├── reproduce.sh               # one-command: provision → bootstrap → run → report → teardown
├── infra/                     # Terraform (azurerm): SUT, load-gen, observability VMs + NSGs + net
│   └── cloud-init/            # per-VM bootstrap (Docker, exporters, k6)
├── servers/                   # one dir per SUT: docker-compose + pinned versions + tuned config
│   ├── fhir-server-go/        #   built from feat/fhir-server-go-transaction-bundle
│   ├── hapi/  ├── microsoft/  ├── ibm/  ├── medplum/  └── blaze/
├── dataset/                   # Synthea generation (pinned version + fixed seed) + snapshot/restore
├── scenarios/                 # k6 scripts (read mix, write mix, ingest, saturation, $everything)
├── orchestrator/              # the driver: loops servers × scenarios × reps; reset/warm-up/measure
├── reporting/                 # Grafana dashboards (as JSON), HTML/Markdown report generator
└── ci/                        # GitHub Actions workflows (manual dispatch + scheduled)
```

### Everything is config-driven

A single `bench.config.yaml` (overridable by env vars) holds **every** knob, so reproducing
with different choices never means editing code:

```yaml
azure:
  subscription_id: ${AZURE_SUBSCRIPTION_ID}   # from .env / CI secret
  location: eastus
  resource_group: fhir-bench-rg
  vm_sizes: { sut: Standard_D8s_v5, loadgen: Standard_D8s_v5, obs: Standard_D4s_v5 }
limits:        { sut_cpus: 4, sut_mem: 8g, db_cpus: 4, db_mem: 8g }   # identical for all SUTs
dataset:       { tool_version: 3.x.x, seed: 1234, size: medium }      # small|medium|large
servers:                                                             # pinned versions, enable/disable
  fhir-server-go: { ref: feat/fhir-server-go-transaction-bundle, enabled: true }
  hapi:           { version: vX.Y.Z, enabled: true }
  # microsoft / ibm / medplum / blaze ...
run:           { warmup_s: 90, measure_s: 600, repetitions: 3, cooldown_s: 60 }
slo:           { p99_ms: 500, max_error_rate: 0.001 }
reporting:     { tsdb: prometheus, artifact_store: azure_blob,
                 blob_container: ${BENCH_BLOB_CONTAINER} }   # raw JSON + reports → Azure Blob
```

Secrets (Azure service-principal creds, any registry tokens) come **only** from env vars /
`.env` (gitignored) or CI secrets — never the YAML, never the repo.

### One-command reproduction

```bash
git clone https://github.com/nirmal070125/os-fhir-server-bench && cd os-fhir-server-bench
cp .env.example .env && $EDITOR .env          # Azure creds + bucket
$EDITOR bench.config.yaml                      # region, sizes, which servers, dataset size
./reproduce.sh                                 # provisions Azure VMs, runs everything, publishes report, tears down
```

`reproduce.sh` is just a thin wrapper over discrete, independently-runnable scripts
(`make provision`, `make seed`, `make run`, `make report`, `make teardown`) so anyone can
also step through it stage by stage or re-run a single stage. Terraform makes the Azure
infra reproducible and disposable; `teardown` (and a CI always-run teardown step) prevents
orphaned VMs from burning the reproducer's credits.

### Reproducibility guarantees baked in

- **Pinned everything** — server image digests, Synthea version, k6 version, Terraform
  provider versions, base VM image. Recorded into each run's manifest so a result is never
  orphaned from the exact bits that produced it.
- **Deterministic dataset** — fixed Synthea seed → byte-identical bundles → snapshot hash
  asserted before runs.
- **No interactive prompts** — every script runs headless; CI exercises the same scripts a
  human would, so "works in CI" == "works for a reproducer."
- **Self-checking** — `reproduce.sh` validates config + creds up front and fails fast with a
  clear message rather than half-provisioning.

> Cloud note: the repo targets **Azure** as the reference environment (Terraform `azurerm`),
> but keeping all cloud specifics inside `infra/` + `bench.config.yaml` means a contributor
> could add an `infra/aws` or `infra/gcp` variant later without touching the
> orchestrator/scenarios/reporting layers.

---

## 10. Suggested phasing

1. **Phase 0 — harness & one server.** Stand up k6 + Synthea Medium dataset +
   snapshot/restore + reporting against *just ours*. Prove the methodology end-to-end.
2. **Phase 1 — add HAPI.** First real comparison; the reference everyone trusts.
3. **Phase 2 — add Blaze + Medplum.** Fast ceiling + direct Postgres peer.
4. **Phase 3 — add Microsoft + IBM/LinuxForHealth.** Brings the count to all six and adds the
   SQL Server / Db2 storage backends; scale the dataset to Large here.

---

## 11. Open questions to settle before build

- ~~Dataset size to publish on~~ → **DECIDED: headline on Large (100k); Small/Medium for harness iteration.**
- ~~SLO threshold for "max sustainable throughput"~~ → **DECIDED: p99 < 500 ms and error rate < 0.1%** (also publish full latency-vs-throughput curves alongside the single number).
- Exact pinned versions of each server (record at build time).
- ~~Object-store + artifact storage~~ → **DECIDED: Azure Blob Storage**, container name via env/config; raw k6 JSON + generated reports land there. Grafana hosted on the observability VM.
- ~~New repo name + GitHub org~~ → **DECIDED: `github.com/nirmal070125/os-fhir-server-bench`** (personal account; can transfer to a WSO2 org later).
- ~~Azure region~~ → **DECIDED: region is a config value (`azure.location`), default `eastus`**; reproducers override freely.
- Exact pinned versions of each server — record at build time (resolve when scaffolding `servers/`).
- Which Azure *subscription* bills the reference runs (only matters for our own published numbers; reproducers use their own).
