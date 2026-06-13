#!/usr/bin/env bash
# Run ONE workload at ONE concurrency level against a FHIR base URL (closed model:
# VUS concurrent clients). SLO knobs come from bench.config.yaml (slo.*); the
# concurrency level is passed in via CONCURRENCY (the orchestrator sweeps the
# bench.config.yaml ladder). This is the standalone/local entry; the orchestrator
# wraps it with restore, warm-up, repetitions, and Prometheus output. Metrics for
# THIS invocation land in results/ as line-delimited JSON + a summary file.
#   CONCURRENCY=<N> scenarios/run.sh <read-mix|ingest> <fhir_base_url> [duration]
#   e.g. CONCURRENCY=32 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
set -euo pipefail
SCN="${1:?usage: CONCURRENCY=<N> run.sh <scenario> <base_url> [duration]}"
BASE_URL="${2:?usage: CONCURRENCY=<N> run.sh <scenario> <base_url> [duration]}"
DURATION="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cfg() { "$ROOT/bin/cfg" "$1"; }

command -v k6 >/dev/null || { echo "k6 not found (installed on the loadgen VM by cloud-init)"; exit 1; }

case "$SCN" in
  read-mix|ingest) SCRIPT="$HERE/$SCN.js" ;;
  *) echo "unknown scenario: $SCN (read-mix|ingest)"; exit 1 ;;
esac

export BASE_URL
# Per-scenario p99 SLO (e.g. ingest is heavier) overriding the read-oriented default.
export P99_MS="$(cfg "slo.per_scenario.\"$SCN\".p99_ms" 2>/dev/null || cfg slo.p99_ms)"
export MAX_ERROR_RATE="$(cfg slo.max_error_rate)"

# Concurrency = number of in-flight clients (k6 VUs). One level per run.
export VUS="${CONCURRENCY:?CONCURRENCY (VUs) is required — the concurrency level to measure}"
export DURATION="${DURATION:-${MEASURE_S:-600}s}"

# CAPTURE=0 (warm-up, discarded) vs 1 (measured). Same VUS either way — the warm-up
# is just a shorter window at the same concurrency to warm JIT/cache/pools.
CAPTURE="${CAPTURE:-1}"

# OUTDIR lets the orchestrator place captured output.
OUTDIR="${OUTDIR:-$ROOT/results/$SCN}"
mkdir -p "$OUTDIR"

# k6 exit codes: 0 = all thresholds passed; 99 = a threshold was crossed. Exit 99
# is a VALID RESULT — the SLO simply wasn't met at this concurrency (expected at the
# high end of the sweep) — and report.py decides pass/fail from the measured numbers.
# Only OTHER non-zero codes are real errors (couldn't connect, bad script).
run_k6() {
  local rc=0
  k6 run "$@" || rc=$?
  if [[ "$rc" != 0 && "$rc" != 99 ]]; then
    echo "ERROR: k6 failed (exit $rc) — operational error, not an SLO breach" >&2
    return "$rc"
  fi
  return 0
}

echo "==> k6 $SCN @ ${VUS} VUs -> $BASE_URL (p99<${P99_MS}ms, err<${MAX_ERROR_RATE}, capture=$CAPTURE)"
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
