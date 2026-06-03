#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
. "$HERE/../_lib/lib.sh"
export_limits; export_ports hapi
docker compose up -d
wait_http_ready "http://localhost:${HOST_PORT}$(cfg servers.hapi.health_path)" 360
