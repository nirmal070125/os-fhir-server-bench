#!/usr/bin/env bash
# Build ONE head-to-head report from BOTH parallel stacks' results, pulled from Azure
# Blob. Works whether the loadgens are still up or already auto-deallocated — each
# stack uploads its results (summaries + manifest) to Blob at the end of its run, so
# Blob is the source of truth either way.
#
# Stack prefixes (run-<ts>-s1 / -s2) come from .detached.s1.env / .detached.s2.env, or
# pass them as args:  reporting/fetch-parallel.sh run-20260614-...-s1 run-20260614-...-s2
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

ACCT="$(cd infra && terraform output -raw storage_account 2>/dev/null || true)"
[[ -n "$ACCT" ]] || { echo "no storage account (is infra provisioned?)"; exit 1; }
CONT="$(bin/cfg reporting.blob_container)"
KEY="$(az storage account keys list -g "$(bin/cfg azure.resource_group)" -n "$ACCT" --query '[0].value' -o tsv)"

# Prefixes from args, else from the per-stack detached env files.
prefixes=("$@")
if [[ ${#prefixes[@]} -eq 0 ]]; then
  for s in 1 2; do
    p="$(grep -E '^PREFIX=' ".detached.s$s.env" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$p" ]] && prefixes+=("$p")
  done
fi
[[ ${#prefixes[@]} -ge 1 ]] || { echo "no stack prefixes (.detached.s1.env/.s2.env missing) — pass them as args"; exit 1; }

# Each stack's blobs live under <prefix>/<server>/... ; download and merge the server
# trees into results/<server>/... so report.py sees both servers at once.
staging="results-blob/_parallel"; rm -rf "$staging"; mkdir -p "$staging" results
for p in "${prefixes[@]}"; do
  echo "==> fetching $p from Blob"
  az storage blob download-batch --account-name "$ACCT" --account-key "$KEY" \
     -s "$CONT" --pattern "$p/*" -d "$staging" -o none 2>/dev/null || { echo "WARN: nothing in Blob for $p"; continue; }
  [[ -d "$staging/$p" ]] && cp -R "$staging/$p/." results/ || echo "WARN: no files for $p"
done

echo "==> building merged head-to-head report"
python3 reporting/report.py
