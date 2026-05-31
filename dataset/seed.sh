#!/usr/bin/env bash
# Load the Synthea dataset into a FHIR server through its public REST API only
# (no privileged importer — same path for every server, per the fairness charter).
# hospitalInformation + practitionerInformation bundles go first (patient bundles
# reference those Organizations/Practitioners).
#   dataset/seed.sh <fhir_base_url> [bundle_dir]
#   e.g. dataset/seed.sh http://localhost:9090/fhir/r4
set -euo pipefail
BASE="${1:?usage: seed.sh <fhir_base_url> [bundle_dir]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE="$("$ROOT/bin/cfg" dataset.size)"
DIR="${2:-$ROOT/dataset/output/$SIZE/fhir}"

post() {
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$BASE" \
    -H 'Content-Type: application/fhir+json' \
    --data-binary @"$1"
}

ok=0; fail=0
seed_glob() {
  shopt -s nullglob
  for f in $1; do
    code="$(post "$f")"
    if [[ "$code" =~ ^2 ]]; then ok=$((ok+1)); else fail=$((fail+1)); echo "  WARN $(basename "$f") -> HTTP $code"; fi
  done
}

echo "==> Seeding infrastructure bundles (hospitals, practitioners)"
seed_glob "$DIR/hospitalInformation*.json"
seed_glob "$DIR/practitionerInformation*.json"

echo "==> Seeding patient bundles"
shopt -s nullglob
for f in "$DIR"/*.json; do
  b="$(basename "$f")"
  case "$b" in
    hospitalInformation*|practitionerInformation*) continue ;;  # already seeded above
  esac
  code="$(post "$f")"
  if [[ "$code" =~ ^2 ]]; then ok=$((ok+1)); else fail=$((fail+1)); echo "  WARN $b -> HTTP $code"; fi
done

echo "==> Seeded $ok bundles, $fail failed → $BASE"
[[ "$fail" -eq 0 ]]
