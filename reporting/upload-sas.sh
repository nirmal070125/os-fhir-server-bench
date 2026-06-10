#!/usr/bin/env bash
# Upload results/ (report + summaries + manifests — small text files) to Azure Blob
# using a pre-signed container SAS URL. Uses only curl, so the loadgen VM needs no
# az CLI. Lets a detached run publish its report without the operator's laptop.
#   reporting/upload-sas.sh "<https://acct.blob.core.windows.net/CONTAINER?SAS>" <prefix>
set -uo pipefail
SAS_URL="${1:?usage: upload-sas.sh <container-sas-url> <prefix>}"
PREFIX="${2:?usage: upload-sas.sh <container-sas-url> <prefix>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

base="${SAS_URL%%\?*}"      # https://acct.blob.core.windows.net/container
token="${SAS_URL#*\?}"      # the SAS query string

ctype() { case "$1" in *.md) echo text/markdown;; *.csv) echo text/csv;; *.json) echo application/json;; *) echo text/plain;; esac; }

put() { # <local-file> <blob-relative-path>
  [[ -f "$1" ]] || return 0
  if curl -fsS -X PUT -H "x-ms-blob-type: BlockBlob" -H "Content-Type: $(ctype "$1")" \
       --data-binary @"$1" "$base/$PREFIX/$2?$token" >/dev/null; then echo "  uploaded $2"; else echo "  WARN upload failed: $2" >&2; fi
}

# Run log + exit code FIRST, so you can always see what happened — even when the run
# failed and produced no report.
put run.log run.log
put run.exit run.exit

# Report + per-rep summaries + manifests (if the run got far enough to produce them).
if [[ -d results ]]; then
  while IFS= read -r f; do put "$f" "${f#results/}"; done \
    < <(find results \( -name 'report.md' -o -name 'report.csv' \
                        -o -name 'summary.json' -o -name 'run-manifest.json' \) -type f)
fi
echo "upload-sas: done -> $base/$PREFIX/"
