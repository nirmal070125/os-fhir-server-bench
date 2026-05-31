#!/usr/bin/env bash
# One-command reproduction:
#   provision -> seed -> run -> report -> teardown
#
# Prereqs (operator machine): git, terraform, azure-cli, make, ssh.
# Edit bench.config.yaml + .env first, then: ./reproduce.sh
#
# Stages are also runnable individually: `make infra-up`, `make seed`, etc.
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
    echo "==> KEEP_INFRA=1 — leaving Azure resources up. Run 'make infra-down' to stop billing."
  else
    echo "==> Tearing down Azure resources"
    make infra-down
  fi
}
trap teardown EXIT

echo "==> Preflight checks"
make check

echo "==> Provisioning infrastructure"
make infra-up

echo "==> Seeding dataset"
make seed

echo "==> Running benchmark matrix"
make run

echo "==> Generating + publishing report"
make report

echo "==> Done. Report uploaded to Blob container '${BENCH_BLOB_CONTAINER:-bench-results}'."
