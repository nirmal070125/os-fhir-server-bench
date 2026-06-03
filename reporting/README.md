# reporting/

Turns raw run artifacts into a published, auditable comparison — plus a live
Grafana view while a run is in flight.

## Report generator — `report.py`

Reads `results/<server>/run-manifest.json` + `results/<server>/<scenario>/rep-*/summary.json`,
aggregates across repetitions (median headline, ±half-spread on p99), and writes:

- `results/report.md` — one table per scenario, servers ranked by throughput, with
  **throughput-per-vCPU** (the fairness-normalized headline) and SLO pass/fail.
- `results/report.csv` — flat rows for any further analysis.

```bash
python3 reporting/report.py        # or: make report
```

Stdlib only — runs anywhere Python 3 is present.

## Central publishing — `upload.sh`

`make report` runs the generator, then (if `BENCH_STORAGE_ACCOUNT` is set) uploads all
of `results/` to Azure Blob under a timestamped prefix. Auth/target come from env
(`BENCH_STORAGE_ACCOUNT` / `BENCH_STORAGE_KEY` / `BENCH_BLOB_CONTAINER`), never code;
falls back to `az login` / managed identity if no key is given.

## Live view — `observability/`

For the obs VM. `prom/prometheus` (k6 remote-write receiver + scrapes the SUT's
cAdvisor/node-exporter) and a pre-provisioned `grafana`:

```bash
# obs VM:
docker compose -f reporting/observability/docker-compose.yml up -d   # Grafana :3000
# SUT VM (server-side CPU/mem):
docker compose -f reporting/observability/sut-exporters.yml up -d
# point the loadgen at Prometheus so k6 streams in:
export K6_PROMETHEUS_RW_SERVER_URL=http://<obs-ip>:9090/api/v1/write
```

`run.sh` adds `--out experimental-prometheus-rw` automatically when that env is set
(as native histograms, so the dashboard's `histogram_quantile()` panels work). The
dashboard `fhir-bench.json` shows client-side latency percentiles + throughput/error
alongside SUT container CPU/mem.

**Source of truth = the JSON artifacts**, not Grafana. The Markdown/CSV report and the
per-run manifests are what get published and compared; Grafana is the during-run lens.
Exact k6 metric names (`k6_http_req_duration`, `k6_http_reqs_total`, …) depend on the k6
version — adjust the dashboard queries if you bump k6.
