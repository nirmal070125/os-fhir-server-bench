#!/usr/bin/env bash
# Deterministic dataset fingerprint — assert byte-identical generation across
# machines/runs before seeding. (sha256sum is present on the Ubuntu VMs.)
#   dataset/hash.sh [bundle_dir]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE="$("$ROOT/bin/cfg" dataset.size)"
DIR="${1:-$ROOT/dataset/output/$SIZE/fhir}"

find "$DIR" -type f -name '*.json' -print0 \
  | sort -z \
  | xargs -0 cat \
  | sha256sum \
  | cut -d' ' -f1
