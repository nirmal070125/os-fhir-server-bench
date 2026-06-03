#!/usr/bin/env bash
# Start db + server and block until the server is ready to serve traffic.
# The image is distroless (no shell/curl), so readiness is probed from the host.
#   servers/fhir-server-go/up.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

[[ -f .env ]] || ./render-env.sh
set -a; . ./.env; set +a

echo "==> docker compose up -d"
docker compose -f compose.yaml --env-file .env up -d

URL="http://localhost:${FSG_PORT}${FSG_HEALTH_PATH}"
echo "==> waiting for readiness: $URL"
deadline=$((SECONDS + 180))
until curl -fsS -o /dev/null "$URL"; do
  if (( SECONDS >= deadline )); then
    echo "ERROR: server not ready after 180s" >&2
    docker compose -f compose.yaml --env-file .env logs --tail 50 server >&2 || true
    exit 1
  fi
  sleep 2
done
echo "==> ready at http://localhost:${FSG_PORT}${FSG_BASE_PATH}"
