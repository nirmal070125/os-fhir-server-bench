# os-fhir-server-bench

A **fair, fully reproducible** performance benchmark of open-source FHIR servers.

It measures [`fhir-server-go`](https://github.com/wso2/open-healthcare-prebuilt-services)
against the well-known open-source FHIR servers (HAPI, Microsoft, IBM/LinuxForHealth,
Medplum, Blaze) under identical hardware, an identical dataset, and a standards-compliant
methodology (warm-up, steady-state, a closed- or open-model load sweep, N repetitions). Every server is hit
**only through its public FHIR REST API** — no privileged shortcuts for anyone.

> Anyone can reproduce the results on their own Azure subscription by editing one config
> file and running one command. Nothing runs by hand; nothing is hard-coded.

## ⚠️ Disclaimer

**This tool provisions paid cloud infrastructure on _your_ Azure subscription and you are
solely responsible for all charges it incurs.** A run creates multiple VMs, disks, storage,
and networking; if they are left running or are not torn down, billing continues. Costs vary
by region, VM availability, dataset size, and how long resources stay up — the figures in this
README are rough estimates, not guarantees.

The authors and contributors **cannot be held responsible for any financial cost, billing
overrun, data loss, security exposure, or other damages** arising from using this tool. You
are responsible for: monitoring your own spend, tearing down resources (`make teardown`),
securing access (set `allowed_ssh_cidr` to your IP — never leave `0.0.0.0/0`), and protecting
your credentials. The software is provided **"AS IS", without warranty of any kind** — see
[`LICENSE`](LICENSE) (Apache-2.0).

Always confirm in the Azure Portal that everything was deallocated when you are done.

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
| `scenarios/` | k6 load scripts (read-mix, ingest) — closed-model (default) or open-model load sweep ([docs/load-model.md](docs/load-model.md)) |
| `orchestrator/` | The run driver (reset → warm-up → sweep the load ladder → collect) |
| `reporting/` | Grafana dashboards + report generator |
| `ci/` | GitHub Actions (manual dispatch + scheduled) |
| `bin/` | Helper scripts (`cfg`, `preflight.sh`) |

## Status

The full pipeline is implemented and CI-validated: infra (Terraform), dataset
(Synthea + per-engine snapshot/restore), k6 scenarios (closed- or open-model load
sweep), orchestrator
(restore → warm-up → sweep the load ladder ×N → run manifest), reporting (report generator +
Prometheus/Grafana + Blob upload), and GitHub Actions (validate / smoke / azure-run).

Server profiles:

| Server | Status |
|---|---|
| fhir-server-go, HAPI | ✅ **benchmarked end-to-end** — completed a `medium1y` (10k patients) closed-model head-to-head |
| Blaze | ✅ boot-verified end-to-end |
| Microsoft, Medplum, IBM | ⚠️ scaffolded — finalize per each `servers/<name>/README.md` (shared blocker: an optional auth header for seed/scenarios) |

Next milestones: bring Blaze and the three scaffolded profiles into the sweep, then the
**Large (100k) all-comparators headline run**. Adding a server is a self-contained,
contract-driven task — see [`servers/README.md`](servers/README.md#adding-a-new-server).
