#!/usr/bin/env bash
# Ensure all VMs in the resource group are RUNNING. `terraform apply` does NOT start
# a deallocated VM (it doesn't manage power state), so after an auto-stop a rerun
# would otherwise SSH into stopped VMs and fail. Idempotent: already-running VMs are
# a no-op; deallocated ones get started. Called by `make provision`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RG="$(bin/cfg azure.resource_group)"

ids="$(az vm list -g "$RG" --query "[].id" -o tsv 2>/dev/null || true)"
[[ -n "$ids" ]] || { echo "start-vms: no VMs found in $RG (nothing to start)"; exit 0; }

# Start only those not already running (avoids churn on a normal run).
stopped="$(az vm list -d -g "$RG" --query "[?powerState!='VM running'].id" -o tsv 2>/dev/null || true)"
if [[ -z "$stopped" ]]; then
  echo "start-vms: all VMs already running"
else
  echo "start-vms: starting stopped VMs..."
  # shellcheck disable=SC2086
  az vm start --ids $stopped -o none && echo "start-vms: started"
fi
