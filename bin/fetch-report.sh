#!/usr/bin/env bash
# Pull the latest run's report + run log from Azure Blob and show them. Reads from
# Blob (not the VMs), so it works regardless of VM state — including after auto-stop.
# Shows run.log even when the run failed and produced no report. Optional arg: a
# specific run prefix (default: the latest).
#   bin/fetch-report.sh [run-YYYYMMDD-HHMMSS]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

ACCT="$(cd infra && terraform output -raw storage_account 2>/dev/null || true)"
[[ -n "$ACCT" ]] || { echo "no storage account (is infra provisioned?)"; exit 1; }
CONT="$(bin/cfg reporting.blob_container)"
KEY="$(az storage account keys list -g "$(bin/cfg azure.resource_group)" -n "$ACCT" --query '[0].value' -o tsv)"

names="$(az storage blob list --account-name "$ACCT" --account-key "$KEY" -c "$CONT" --query '[].name' -o tsv 2>/dev/null || true)"
[[ -n "$names" ]] || { echo "no runs found in Blob ($ACCT/$CONT) — the run may not have uploaded yet"; exit 1; }

prefix="${1:-$(printf '%s\n' "$names" | sed -E 's#/.*##' | sort -u | tail -1)}"
echo "==> run: $prefix   (others: $(printf '%s\n' "$names" | sed -E 's#/.*##' | sort -u | paste -sd' ' -))"
dest="results-blob/$prefix"; mkdir -p "$dest"
get() { az storage blob download --account-name "$ACCT" --account-key "$KEY" -c "$CONT" -n "$prefix/$1" -f "$dest/$1" -o none 2>/dev/null; }

get report.md && { echo; echo "===== report.md ====="; cat "$dest/report.md"; } \
  || echo "(no report.md — the run likely failed before producing one; see run.log below)"
echo; echo "===== run.log (tail) ====="
get run.log && tail -50 "$dest/run.log" || echo "(no run.log uploaded)"
echo; echo "(full files under $dest/)"