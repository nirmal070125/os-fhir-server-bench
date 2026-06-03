#!/usr/bin/env bash
# Deterministic dataset fingerprint — assert byte-identical generation across
# machines/runs before seeding. Uses sha256sum (Ubuntu VMs) with a `shasum -a 256`
# fallback (macOS dev machines).
#   dataset/hash.sh [bundle_dir]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE="$("$ROOT/bin/cfg" dataset.size)"
DIR="${1:-$ROOT/dataset/output/$SIZE/fhir}"

if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

find "$DIR" -type f -name '*.json' -print0 \
  | sort -z \
  | xargs -0 cat \
  | "${SHA[@]}" \
  | cut -d' ' -f1
