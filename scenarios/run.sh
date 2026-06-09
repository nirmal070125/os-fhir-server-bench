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

# CAPTURE=0 (warm-up, discarded) vs 1 (measured). Resolved early because saturation
# warms up differently from how it measures (see below).
CAPTURE="${CAPTURE:-1}"

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
    export PREALLOCATED_VUS="$(cfg "$W.preallocated_vus")"
    export MAX_VUS="$(cfg "$W.max_vus")"
    SCRIPT="$HERE/saturation.js"
    if [[ "$CAPTURE" == "1" ]]; then
      # MEASURED: the full ramp (start_rate -> max_rate), unchanged.
      export START_RATE="$(cfg "$W.start_rate")"
      export STEP_RATE="$(cfg "$W.step_rate")"
      export STEP_DURATION="$(cfg "$W.step_duration")"
      export MAX_RATE="$(cfg "$W.max_rate")"
    else
      # WARM-UP: a short CONSTANT load at the start rate — warms JIT/cache/pools
      # without re-running (and discarding) the entire ramp. Re-running the full
      # 20-min ramp as warm-up was ~1h of pure waste across reps; the measured ramp
      # is identical either way, so this changes timing only, not the result.
      export WARMUP=1
      export RATE="$(cfg "$W.start_rate")"
      export DURATION="${DURATION:-90s}"
    fi
    ;;
  *) echo "unknown scenario: $SCN (read-mix|ingest|saturation)"; exit 1 ;;
esac

# OUTDIR lets the orchestrator place captured output.
OUTDIR="${OUTDIR:-$ROOT/results/$SCN}"
mkdir -p "$OUTDIR"

# k6 exit codes: 0 = all thresholds passed; 99 = a threshold was crossed (incl.
# abortOnFail). Exit 99 is a VALID RESULT — the SLO simply wasn't met (e.g. ingest
# p99 > target, or saturation hit its latency knee) — and report.py decides pass/fail
# from the measured numbers. Only OTHER non-zero codes are real errors (couldn't
# connect, bad script) that should fail the run.
run_k6() {
  local rc=0
  k6 run "$@" || rc=$?
  if [[ "$rc" != 0 && "$rc" != 99 ]]; then
    echo "ERROR: k6 failed (exit $rc) — operational error, not an SLO breach" >&2
    return "$rc"
  fi
  return 0
}

echo "==> k6 $SCN -> $BASE_URL (p99<${P99_MS}ms, err<${MAX_ERROR_RATE}, capture=$CAPTURE)"
if [[ "$CAPTURE" == "1" ]]; then
  export SUMMARY_OUT="$OUTDIR/summary.json"
  OUTS=(--out "json=$OUTDIR/metrics.json")
  # Also stream to Prometheus (live Grafana view) when an obs endpoint is configured.
  # k6 reads the target URL from K6_PROMETHEUS_RW_SERVER_URL automatically.
  if [[ -n "${K6_PROMETHEUS_RW_SERVER_URL:-}" ]]; then
    export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true   # enables histogram_quantile() in Grafana
    OUTS+=(--out experimental-prometheus-rw)
  fi
  run_k6 "${OUTS[@]}" "$SCRIPT"
else
  export SUMMARY_OUT=/dev/null   # warm-up: run load, throw the numbers away
  run_k6 "$SCRIPT"
fi
