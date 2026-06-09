#!/usr/bin/env bash
# Upload results/ (report + summaries + manifests — small text files) to Azure Blob
# using a pre-signed container SAS URL. Uses only curl, so the loadgen VM needs no
# az CLI. Lets a detached run publish its report without the operator's laptop.
#   reporting/upload-sas.sh "<https://acct.blob.core.windows.net/CONTAINER?SAS>" <prefix>
set -euo pipefail
SAS_URL="${1:?usage: upload-sas.sh <container-sas-url> <prefix>}"
PREFIX="${2:?usage: upload-sas.sh <container-sas-url> <prefix>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
[[ -d results ]] || { echo "upload-sas: no results/ to upload"; exit 0; }

base="${SAS_URL%%\?*}"      # https://acct.blob.core.windows.net/container
token="${SAS_URL#*\?}"      # the SAS query string

ctype() { case "$1" in *.md) echo text/markdown;; *.csv) echo text/csv;; *.json) echo application/json;; *) echo application/octet-stream;; esac; }

n=0
while IFS= read -r f; do
  rel="${f#results/}"                       # path under results/
  url="$base/$PREFIX/$rel?$token"           # -> container/<prefix>/<rel>?SAS
  if curl -fsS -X PUT -H "x-ms-blob-type: BlockBlob" -H "Content-Type: $(ctype "$f")" \
       --data-binary @"$f" "$url" >/dev/null; then n=$((n+1)); else echo "WARN: upload failed: $rel" >&2; fi
done < <(find results \( -name 'report.md' -o -name 'report.csv' \
                         -o -name 'summary.json' -o -name 'run-manifest.json' \) -type f)
echo "upload-sas: uploaded $n file(s) to $base/$PREFIX/"
