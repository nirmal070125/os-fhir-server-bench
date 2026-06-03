#!/usr/bin/env bash
# Shared helpers for image-based server profiles (sourced by each server's
# build.sh / up.sh / down.sh). compose.yaml files read SUT_CPUS/SUT_MEM/DB_CPUS/
# DB_MEM/HOST_PORT/DB_PORT straight from the process environment, so a profile
# script just exports these (from bench.config.yaml) and runs `docker compose`.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cfg() { "$ROOT/bin/cfg" "$1"; }

# Identical resource envelope for every server (the fairness charter).
export_limits() {
  export SUT_CPUS DB_CPUS SUT_MEM DB_MEM
  SUT_CPUS="$(cfg limits.sut_cpus)"; SUT_MEM="$(cfg limits.sut_mem)"
  DB_CPUS="$(cfg limits.db_cpus)";  DB_MEM="$(cfg limits.db_mem)"
}

# Export this server's host ports (HOST_PORT for the FHIR API, DB_PORT for the DB).
export_ports() { # <server>
  export HOST_PORT DB_PORT
  HOST_PORT="$(cfg "servers.$1.port")"
  DB_PORT="$(cfg "servers.$1.db_port" 2>/dev/null || echo 0)"
}

# Poll an HTTP endpoint until it returns 2xx, or fail after a timeout.
wait_http_ready() { # <url> [timeout_s]
  local url="$1" t="${2:-300}" deadline=$((SECONDS + ${2:-300}))
  echo "==> waiting for readiness: $url"
  until curl -fsS -o /dev/null "$url"; do
    if (( SECONDS >= deadline )); then
      echo "ERROR: not ready after ${t}s" >&2; return 1
    fi
    sleep 3
  done
  echo "==> ready: $url"
}
