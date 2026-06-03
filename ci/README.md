# ci/

GitHub Actions live in `.github/workflows/` (GitHub only discovers them there). They
exercise the **same scripts a human runs** — no bespoke CI logic.

| Workflow | Trigger | What it does | Cost |
|---|---|---|---|
| `validate.yml` | push / PR | bash -n + shellcheck, k6 `node --check`, `report.py` compile, dashboard JSON, `docker compose config` for every profile | free |
| `smoke.yml` | manual + weekly | full pipeline on the runner: build fhir-server-go → seed → orchestrate read-mix+ingest (short) → report; uploads `results/` | free |
| `azure-run.yml` | manual only (gated) | the real headline run via `./reproduce.sh`: provision Azure → seed → matrix → report → publish to Blob → teardown | **$$ Azure** |

## Secrets for `azure-run.yml`

`ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, and
optionally `BENCH_STORAGE_ACCOUNT` / `BENCH_STORAGE_KEY`. It uses an `azure`
environment — add required reviewers there to gate spend, and `concurrency` prevents
two paid runs at once. Set `dataset.size` and which servers are `enabled` in
`bench.config.yaml` before dispatching.
