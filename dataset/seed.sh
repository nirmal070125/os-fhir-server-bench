#!/usr/bin/env bash
# Load the Synthea dataset into a FHIR server through its public REST API only
# (no privileged importer — same path for every server, per the fairness charter).
# hospitalInformation + practitionerInformation bundles go first (patient bundles
# reference those Organizations/Practitioners), then patient bundles are POSTed by
# SEED_CONCURRENCY parallel workers — they're independent of each other, and
# parallelism only speeds the one-time seed; it never touches the measured phase.
# (Sequentially, Large/100k would take days: ~4s/bundle measured locally.)
#
#   dataset/seed.sh <fhir_base_url> [bundle_dir]
#   e.g. dataset/seed.sh http://localhost:9090/fhir/r4
#
# Env:
#   SEED_CONCURRENCY  parallel patient-bundle posts (default 8)
#   AUTH_HEADER       optional, e.g. 'Authorization: Bearer X' / 'Authorization: Basic Y'
#                     for auth-required servers (Medplum, IBM). Empty = open server.
#   TLS_INSECURE=1    accept self-signed TLS (IBM's Liberty default)
set -euo pipefail
BASE="${1:?usage: seed.sh <fhir_base_url> [bundle_dir]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIZE="${SIZE:-$("$ROOT/bin/cfg" dataset.size)}"
DIR="${2:-$ROOT/dataset/output/$SIZE/fhir}"
# Default 4: at 8, the two largest Synthea bundles intermittently fail mid-transaction
# with "conn closed" (Postgres connection dropped under contention), which aborts the
# whole run. 4 is reliable; raise it for speed on a beefy DB if seeding 0-fails for you.
CONC="${SEED_CONCURRENCY:-4}"

export SEED_BASE="$BASE" AUTH_HEADER="${AUTH_HEADER:-}" TLS_INSECURE="${TLS_INSECURE:-0}"

# One bundle -> one line: "OK <file>" or "FAIL <file> HTTP <code>".
# Runs in its own bash (xargs worker), reading config from the exported env.
# -H "Expect:" disables curl's 100-continue handshake on large bodies — under
# parallel load it can surface as a client-side error AFTER the server committed
# (observed with a 38MB bundle). NEVER blind-retry a failed transaction POST:
# the server may have applied it, and a retry would duplicate every resource —
# that's also why client-side errors get a distinct CLIENT-ERR label (verify, don't redo).
WORKER='
  f="$1"
  args=(-sS -o /dev/null -w "%{http_code}" --max-time 900 -X POST "$SEED_BASE" \
        -H "Content-Type: application/fhir+json" -H "Expect:")
  [[ -n "$AUTH_HEADER" ]] && args+=(-H "$AUTH_HEADER")
  [[ "$TLS_INSECURE" == "1" ]] && args+=(-k)
  if code="$(curl "${args[@]}" --data-binary @"$f" 2>/dev/null)"; then
    if [[ "$code" =~ ^2 ]]; then echo "OK $(basename "$f")"; else echo "FAIL $(basename "$f") HTTP $code"; fi
  else
    echo "FAIL $(basename "$f") CLIENT-ERR (transport failed; server may still have committed — verify before re-seeding)"
  fi
'

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT
shopt -s nullglob

echo "==> Seeding infrastructure bundles (hospitals, practitioners) — sequential"
for f in "$DIR"/hospitalInformation*.json "$DIR"/practitionerInformation*.json; do
  bash -c "$WORKER" _ "$f" | tee -a "$RESULTS"
done

total="$(find "$DIR" -name '*.json' ! -name 'hospitalInformation*' ! -name 'practitionerInformation*' | wc -l | tr -d ' ')"
echo "==> Seeding $total patient bundles — $CONC parallel workers (progress every 25)"
# Stream worker results to $RESULTS (for the summary) AND print a running count, so a
# big seed isn't a silent hour. awk flushes so progress shows live in run.log.
find "$DIR" -name '*.json' \
  ! -name 'hospitalInformation*' ! -name 'practitionerInformation*' -print0 \
  | xargs -0 -n1 -P "$CONC" bash -c "$WORKER" _ \
  | tee -a "$RESULTS" \
  | awk -v t="$total" '{n++; if (n % 25 == 0 || n == t) {printf "  ... %d/%d bundles\n", n, t; fflush()}}'

ok="$(grep -c '^OK' "$RESULTS" || true)"
fail="$(grep -c '^FAIL' "$RESULTS" || true)"
grep '^FAIL' "$RESULTS" | head -20 || true
echo "==> Seeded $ok bundles, $fail failed → $BASE"
[[ "$fail" -eq 0 ]]
