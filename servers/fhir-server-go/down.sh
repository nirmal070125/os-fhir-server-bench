#!/usr/bin/env bash
# Stop the profile. Pass -v to also delete the data volume (full reset).
#   servers/fhir-server-go/down.sh        # stop, keep data
#   servers/fhir-server-go/down.sh -v     # stop + wipe pgdata/igcache
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
[[ -f .env ]] || ./render-env.sh
docker compose -f compose.yaml --env-file .env down "${1:-}"
