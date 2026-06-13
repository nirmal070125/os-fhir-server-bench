# os-fhir-server-bench

A **fair, fully reproducible** performance benchmark of open-source FHIR servers.

It measures [`fhir-server-go`](https://github.com/wso2/open-healthcare-prebuilt-services)
against the well-known open-source FHIR servers (HAPI, Microsoft, IBM/LinuxForHealth,
Medplum, Blaze) under identical hardware, an identical dataset, and a standards-compliant
methodology (warm-up, steady-state, open-model load, N repetitions). Every server is hit
**only through its public FHIR REST API** — no privileged shortcuts for anyone.

> Anyone can reproduce the results on their own Azure subscription by editing one config
> file and running one command. Nothing runs by hand; nothing is hard-coded.

## How it works

```
┌─────────────────┐  HTTP   ┌──────────────────────────────┐
│ Load Generator  │────────▶│  SUT host (one server at a    │
│ (k6, headless)  │         │  time, fixed CPU/mem limits)  │
└────────┬────────┘         │   ├─ FHIR server container    │
         │ metrics          │   └─ DB container (snapshot)  │
         ▼                  └───────────────┬──────────────┘
┌──────────────────────────────────────────▼─────────────┐
│ Observability + results: Prometheus + Grafana,          │
│ raw JSON + reports → Azure Blob                         │
└──────────────────────────────────────────────────────────┘
```

See [`docs/proposal.md`](docs/proposal.md) for the full methodology, fairness charter, and
metric definitions.

## Prerequisites

**Accounts / cloud**
- An **Azure subscription** with **≥ ~20 vCPU quota** for the `Dsv5` family in your region
  (the reference run uses 3 VMs ≈ 20 vCPUs).
- An **Azure service principal** with **Contributor** on the target subscription/RG.

**On your machine** (to *drive* the run — not to run the servers)
- `git`, `terraform`, `azure-cli` (`az`), `make`, `ssh`, and [`yq`](https://github.com/mikefarah/yq)
- An SSH keypair (path set in `bench.config.yaml`)

You do **not** install Docker, k6, Java, or any FHIR server locally — Terraform's cloud-init
stands those up on the VMs.

**Cost:** ~**$50** for a one-shot all-six *Large (100k)* run; a few dollars per *Medium* dev
run. Idle VMs cost ~$1/hr, so set `auto_stop_when_done: true` (deallocates VMs after the run)
and/or run `make teardown` when done; an auto-shutdown schedule is the backstop.

## Quickstart

```bash
git clone https://github.com/nirmal070125/os-fhir-server-bench && cd os-fhir-server-bench
cp .env.example .env && $EDITOR .env      # Azure auth (az login is enough — see .env.example)
$EDITOR bench.config.yaml                  # region, sizes, which servers, dataset size

make check        # preflight: tools, Azure auth, config — provisions nothing
make smoke        # quick validation on Azure (small, ~25 min) — prints a Blob report URL
make benchmark    # the full run (config defaults) — detached, publishes report to Blob
make teardown     # destroy everything (stop billing) when done
```

`smoke`/`benchmark` provision automatically, run **on the VMs** (your laptop can sleep),
publish the report to Blob (a URL is printed), and — with `auto_stop_when_done: true` —
stop the VMs themselves. Check progress with `make status`; pull results locally with
`make report`. Run `make help` for the full command list (incl. `provision`, `clean`, and
the `seed`/`run` stages).

## Configuration

`bench.config.yaml` is the single source of truth (region, VM sizes, resource limits,
dataset size + seed, which servers are enabled, run timings, SLOs). Secrets live **only** in
`.env`. Terraform reads the YAML directly; shell scripts read it via `bin/cfg`.

## Repository layout

| Path | Purpose |
|---|---|
| `bench.config.yaml` | All tunables (the only file most people edit) |
| `infra/` | Terraform (`azurerm`): VMs, network, storage, cloud-init |
| `dataset/` | Synthea generation + per-engine snapshot/restore |
| `servers/` | One dir per server: docker-compose, pinned versions, tuned config |
| `scenarios/` | k6 load scripts (read-mix, ingest) — closed-model concurrency sweep ([docs/load-model.md](docs/load-model.md)) |
| `orchestrator/` | The run driver (reset → warm-up → sweep concurrency → collect) |
| `reporting/` | Grafana dashboards + report generator |
| `ci/` | GitHub Actions (manual dispatch + scheduled) |
| `bin/` | Helper scripts (`cfg`, `preflight.sh`) |

## Status

The full pipeline is implemented and CI-validated: infra (Terraform), dataset
(Synthea + per-engine snapshot/restore), k6 scenarios (closed-model concurrency
sweep), orchestrator
(restore → warm-up → sweep concurrency ×N → run manifest), reporting (report generator +
Prometheus/Grafana + Blob upload), and GitHub Actions (validate / smoke / azure-run).

Server profiles:

| Server | Status |
|---|---|
| fhir-server-go, HAPI, Blaze | ✅ boot-verified end-to-end |
| Microsoft, Medplum, IBM | ⚠️ scaffolded — finalize per each `servers/<name>/README.md` (shared blocker: an optional auth header for seed/scenarios) |

Next milestones: **Phase-0 Medium run** (fhir-server-go only) on Azure, then the
**Large (100k) all-six headline run** once the three scaffolded profiles are finalized.
