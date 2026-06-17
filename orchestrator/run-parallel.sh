#!/usr/bin/env bash
# Launch ONE isolated detached lane PER ENABLED SERVER, all CONCURRENTLY, each on its
# own SUT+loadgen pinned to an availability zone (round-robin over [1,2,3]) — so every
# server benchmarks at the same time on separate hardware (≈ identical to running them
# one after another, in a fraction of the wall-clock).
#
# The lane COUNT is DERIVED from the enabled servers — there's no "how many" to set.
# Requires: azure.parallel_stacks=true in bench.config.yaml + `make provision` (which
# then creates sut1/loadgen1 … sutN/loadgenN, one lane per enabled server). Each lane is
# a normal detached run on its own loadgen+SUT, sharing one cached Synthea dataset in
# Blob (generation skipped; each server still seed-loads it once). Lane i uploads under
# run-<ts>-s<i>; `make report-parallel` merges them all into one head-to-head report.
#
# Override the server set with SERVERS="a b c" (else all enabled servers in config).
#   SERVERS="fhir-server-go hapi blaze" orchestrator/run-parallel.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
cfg() { bin/cfg "$1"; }

# Auto-stop (azure.auto_stop_when_done) is parallel-SAFE: each lane's self-stop
# deallocates only its OWN SUT+loadgen, never another lane's — so a finishing lane
# can't kill a sibling mid-run. The shared obs is deallocated only by the LAST lane to
# finish (so still-running lanes keep monitoring). See self-stop.sh.
# Manual `make stop DEALLOCATE=1` still works as a backstop.

[[ "$(cfg azure.parallel_stacks 2>/dev/null)" == "true" ]] \
  || { echo "azure.parallel_stacks is not true — set it and 'make provision' before a parallel run (single-server? use 'make benchmark')." >&2; exit 1; }

# Lanes = enabled servers (or the SERVERS override), one per lane. Portable to bash 3.2.
SERVERS_LIST=()
if [[ -n "${SERVERS:-}" ]]; then
  read -r -a SERVERS_LIST <<< "$SERVERS"
else
  while IFS= read -r _s; do [[ -n "$_s" ]] && SERVERS_LIST+=("$_s"); done \
    < <(yq -r '.servers | to_entries | map(select(.value.enabled)) | .[].key' bench.config.yaml)
fi
[[ "${#SERVERS_LIST[@]}" -ge 1 ]] || { echo "no enabled servers to run" >&2; exit 1; }

TS="run-$(date -u '+%Y%m%d-%H%M%S')"   # shared base so every lane's prefix groups as one run
n="${#SERVERS_LIST[@]}"
echo "==> parallel run: $n lane(s) — $(for i in "${!SERVERS_LIST[@]}"; do printf 's%d=%s ' "$((i+1))" "${SERVERS_LIST[$i]}"; done) prefix=$TS-s{1..$n}"

for i in "${!SERVERS_LIST[@]}"; do
  stack="$((i + 1))"; server="${SERVERS_LIST[$i]}"
  echo "==> launching lane $stack: $server"
  RUN_PREFIX="$TS" STACK="$stack" SERVERS="$server" orchestrator/run-detached.sh
done

echo
echo "==> All $n lanes launched (concurrent, separate zones). They share the cached"
echo "    dataset, so only the per-server seed-load runs (no Synthea generation). Manage:"
for i in "${!SERVERS_LIST[@]}"; do
  printf '      make status STACK=%d        # %s\n' "$((i+1))" "${SERVERS_LIST[$i]}"
done
cat <<EOF
    When ALL show DONE:
      make report-parallel       # pull every lane's results -> one head-to-head report
    Stop / halt billing:
      for s in $(seq 1 "$n"); do make stop STACK=\$s; done   # stop the runs
      make stop DEALLOCATE=1                                # also deallocate all VMs
EOF
