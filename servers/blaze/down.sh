#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
. "$HERE/../_lib/lib.sh"
export_limits; export_ports blaze
docker compose down "${1:-}"
