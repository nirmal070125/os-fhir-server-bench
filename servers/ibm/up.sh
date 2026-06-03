#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
. "$HERE/../_lib/lib.sh"
export_limits; export_ports ibm
# health_url: ibm readiness probe (see README for auth/cert caveats)
health_url() { echo "http://localhost:${HOST_PORT}$(cfg servers.ibm.health_path)"; }
docker compose up -d
wait_http_ready "$(health_url)" 420
