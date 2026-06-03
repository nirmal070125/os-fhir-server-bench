#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
. "$HERE/../_lib/lib.sh"
export_limits; export_ports medplum
# health_url: medplum readiness probe (see README for auth/cert caveats)
health_url() { echo "http://localhost:${HOST_PORT}$(cfg servers.medplum.health_path)"; }
docker compose down "${1:-}"
