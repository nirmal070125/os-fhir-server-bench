#!/usr/bin/env bash
# One-command operator-driven reproduction (the laptop drives the whole cycle and
# tears down at the end). For a hands-off Azure run, prefer `make benchmark`
# (detached on the VMs, survives sleep, publishes to Blob). This script is the
# RUN_LOCAL/CI path and the auto-teardown one-shot.
#   provision -> seed -> run -> report -> teardown
#
# Prereqs (operator machine): git, terraform, azure-cli, make, ssh.
# Edit bench.config.yaml + .env first, then: ./reproduce.sh
#
# Stages are also runnable individually: `make provision`, `make seed`, etc.
set -euo pipefail
cd "$(dirname "$0")"

# Load .env into the environment (ARM_* + storage creds) if present.
if [[ -f .env ]]; then
  set -a; # shellcheck disable=SC1091
  source .env; set +a
fi

KEEP_INFRA="${KEEP_INFRA:-0}"   # set KEEP_INFRA=1 to skip teardown (debugging)

teardown() {
  if [[ "$KEEP_INFRA" == "1" ]]; then
    echo "==> KEEP_INFRA=1 — leaving Azure resources up. Run 'make teardown' to stop billing."
  else
    echo "==> Tearing down Azure resources"
    make teardown
  fi
}
trap teardown EXIT

echo "==> Preflight checks"
make check

echo "==> Provisioning infrastructure"
make provision

# Default path: run the benchmark ON the Azure VMs (heavy work never touches the
# operator's disk). Set RUN_LOCAL=1 to instead run everything on this machine.
if [[ "${RUN_LOCAL:-0}" != "1" ]]; then
  echo "==> Wiring operator -> VMs (remote execution)"
  orchestrator/remote-setup.sh
  set -a; source .remote.env; set +a   # REMOTE=1 + SUT_SSH/LOADGEN_SSH/...
fi

echo "==> Seeding dataset"
make seed

echo "==> Running benchmark matrix"
make run

echo "==> Generating report"
python3 reporting/report.py
if [[ -n "${BENCH_STORAGE_ACCOUNT:-}" ]]; then
  reporting/upload.sh && echo "==> Report published to Blob container '${BENCH_BLOB_CONTAINER:-bench-results}'."
else
  echo "==> Report at results/report.md (set BENCH_STORAGE_ACCOUNT to publish to Blob)."
fi
