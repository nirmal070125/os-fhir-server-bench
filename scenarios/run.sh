#!/usr/bin/env bash
# Run ONE scenario once against a FHIR base URL, with all knobs pulled from
# bench.config.yaml (workload.* + slo.*). This is the standalone/local entry; the
# orchestrator (plan step 6) wraps this with warm-up, repetitions, and Prometheus
# output. Metrics for THIS invocation land in results/ as line-delimited JSON +
# a summary file.
#   scenarios/run.sh <read-mix|ingest|saturation> <fhir_base_url> [duration]
#   e.g. scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
set -euo pipefail
SCN="${1:?usage: run.sh <scenario> <base_url> [duration]}"
BASE_URL="${2:?usage: run.sh <scenario> <base_url> [duration]}"
DURATION="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cfg() { "$ROOT/bin/cfg" "$1"; }

command -v k6 >/dev/null || { echo "k6 not found (installed on the loadgen VM by cloud-init)"; exit 1; }

export BASE_URL
export P99_MS="$(cfg slo.p99_ms)"
export MAX_ERROR_RATE="$(cfg slo.max_error_rate)"

W="workload.\"$SCN\""
case "$SCN" in
  read-mix|ingest)
    export RATE="$(cfg "$W.rate")"
    export PREALLOCATED_VUS="$(cfg "$W.preallocated_vus")"
    export MAX_VUS="$(cfg "$W.max_vus")"
    export DURATION="${DURATION:-${MEASURE_S:-600}s}"
    SCRIPT="$HERE/$SCN.js"
    ;;
  saturation)
    export START_RATE="$(cfg "$W.start_rate")"
    export STEP_RATE="$(cfg "$W.step_rate")"
    export STEP_DURATION="$(cfg "$W.step_duration")"
    export MAX_RATE="$(cfg "$W.max_rate")"
    export PREALLOCATED_VUS="$(cfg "$W.preallocated_vus")"
    export MAX_VUS="$(cfg "$W.max_vus")"
    SCRIPT="$HERE/saturation.js"
    ;;
  *) echo "unknown scenario: $SCN (read-mix|ingest|saturation)"; exit 1 ;;
esac

# OUTDIR + CAPTURE let the orchestrator place output and distinguish a discarded
# warm-up (CAPTURE=0 → no metrics written) from a captured measurement (CAPTURE=1).
OUTDIR="${OUTDIR:-$ROOT/results/$SCN}"
CAPTURE="${CAPTURE:-1}"
mkdir -p "$OUTDIR"

echo "==> k6 $SCN -> $BASE_URL (p99<${P99_MS}ms, err<${MAX_ERROR_RATE}, capture=$CAPTURE)"
if [[ "$CAPTURE" == "1" ]]; then
  export SUMMARY_OUT="$OUTDIR/summary.json"
  k6 run --out "json=$OUTDIR/metrics.json" "$SCRIPT"
else
  export SUMMARY_OUT=/dev/null   # warm-up: run load, throw the numbers away
  k6 run "$SCRIPT"
fi
