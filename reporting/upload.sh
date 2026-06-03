#!/usr/bin/env bash
# Publish results/ (raw k6 JSON, per-run manifests, and the generated report) to
# Azure Blob — the central place every reproducer's numbers land. Auth + target
# come from env (.env / CI secrets), never from code:
#   BENCH_STORAGE_ACCOUNT   storage account name
#   BENCH_STORAGE_KEY       account key (or rely on `az login` / managed identity)
#   BENCH_BLOB_CONTAINER    container (default: reporting.blob_container in config)
# A run prefix keeps publishes from colliding: results/<prefix>/...
#   reporting/upload.sh [run_prefix]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v az >/dev/null || { echo "az CLI not found (installed on the VMs / CI)"; exit 1; }
[[ -d results ]] || { echo "no results/ to upload — run the benchmark + report first"; exit 1; }

CONTAINER="${BENCH_BLOB_CONTAINER:-$(bin/cfg reporting.blob_container)}"
ACCOUNT="${BENCH_STORAGE_ACCOUNT:?set BENCH_STORAGE_ACCOUNT}"
PREFIX="${1:-$(date -u +%Y%m%d-%H%M%S)}"

auth=(--account-name "$ACCOUNT")
[[ -n "${BENCH_STORAGE_KEY:-}" ]] && auth+=(--account-key "$BENCH_STORAGE_KEY") || auth+=(--auth-mode login)

echo "==> ensuring container '$CONTAINER' exists"
az storage container create --name "$CONTAINER" "${auth[@]}" --only-show-errors >/dev/null

echo "==> uploading results/ -> $ACCOUNT/$CONTAINER/$PREFIX/"
az storage blob upload-batch \
  --destination "$CONTAINER" --destination-path "$PREFIX" \
  --source results "${auth[@]}" --overwrite --only-show-errors

echo "==> done. Report at: https://${ACCOUNT}.blob.core.windows.net/${CONTAINER}/${PREFIX}/report.md"
