#!/usr/bin/env bash
# Fetch the pinned fhir-server-go source and build its image.
# Reproducibility: we check out the EXACT commit from bench.config.yaml, not a
# moving branch tip — if the branch has advanced, we still build that commit
# (it stays reachable in the branch history) and fail loudly if it has gone.
#   servers/fhir-server-go/build.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

./render-env.sh
set -a; . ./.env; set +a

SRC="$HERE/.src"
if [[ ! -d "$SRC/.git" ]]; then
  echo "==> cloning $FSG_REPO"
  git clone --filter=blob:none --no-checkout "$FSG_REPO" "$SRC"
fi

echo "==> fetching ref $FSG_REF and pinning commit $FSG_COMMIT"
git -C "$SRC" fetch --force origin "$FSG_REF"
if ! git -C "$SRC" cat-file -e "${FSG_COMMIT}^{commit}" 2>/dev/null; then
  echo "ERROR: pinned commit $FSG_COMMIT not found on $FSG_REF — was history rewritten?" >&2
  exit 1
fi
git -C "$SRC" checkout --quiet --detach "$FSG_COMMIT"
echo "==> source at $(git -C "$SRC" rev-parse HEAD)"

echo "==> docker compose build (context: $FSG_BUILD_CONTEXT)"
docker compose -f compose.yaml --env-file .env build
echo "==> built bench/fhir-server-go:${FSG_COMMIT}"
