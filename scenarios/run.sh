#!/usr/bin/env bash
# Run ONE workload at ONE offered rate against a FHIR base URL (open model:
# constant-arrival-rate). SLO knobs come from bench.config.yaml (slo.*); the rate
# level is passed in via RATE (the orchestrator sweeps the bench.config.yaml ladder).
# This is the standalone/local entry; the orchestrator wraps it with restore,
# warm-up, repetitions, and Prometheus output. Metrics for THIS invocation land in
# results/ as line-delimited JSON + a summary file.
#   RATE=<req/s> scenarios/run.sh <read-mix|ingest> <fhir_base_url> [duration]
#   e.g. RATE=400 scenarios/run.sh read-mix http://localhost:9090/fhir/r4 60s
set -euo pipefail
SCN="${1:?usage: RATE=<req/s> run.sh <scenario> <base_url> [duration]}"
BASE_URL="${2:?usage: RATE=<req/s> run.sh <scenario> <base_url> [duration]}"
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

# Offered rate (req/s) — the level k6 tries to issue. One level per run.
export RATE="${RATE:?RATE (req/s) is required — the offered-rate level to measure}"
export DURATION="${DURATION:-${MEASURE_S:-600}s}"

# VU headroom for the open model: the executor needs a free VU per in-flight request
# (required VUs ≈ RATE × latency_s). preAllocatedVUs covers up to ~the p99 SLO so
# under-SLO operation never waits on mid-test allocation; maxVUs gives headroom to
# ~3 s of latency. Past that (deep overload) k6 emits dropped_iterations, which
# report.py flags — so the loadgen's ceiling is never mistaken for the server's.
# Env-overridable (orchestrator/smoke may pin them).
export PREALLOCATED_VUS="${PREALLOCATED_VUS:-$(( RATE / 2 > 50 ? RATE / 2 : 50 ))}"
export MAX_VUS="${MAX_VUS:-$(( RATE * 3 > 200 ? RATE * 3 : 200 ))}"

# CAPTURE=0 (warm-up, discarded) vs 1 (measured). Same RATE either way — the warm-up
# is just a shorter window at the same offered rate to warm JIT/cache/pools.
CAPTURE="${CAPTURE:-1}"

# OUTDIR lets the orchestrator place captured output.
OUTDIR="${OUTDIR:-$ROOT/results/$SCN}"
mkdir -p "$OUTDIR"

# k6 exit codes: 0 = all thresholds passed; 99 = a threshold was crossed. Exit 99
# is a VALID RESULT — the SLO simply wasn't met at this offered rate (expected at the
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

echo "==> k6 $SCN @ ${RATE}/s offered (VUs ${PREALLOCATED_VUS}->${MAX_VUS}) -> $BASE_URL (p99<${P99_MS}ms, err<${MAX_ERROR_RATE}, capture=$CAPTURE)"
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
