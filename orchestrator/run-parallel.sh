#!/usr/bin/env bash
# Launch TWO isolated detached stacks CONCURRENTLY, one server each, on separate
# availability zones — so two servers benchmark at the same time on separate hardware
# (≈ identical to running them one after another, in ~half the wall-clock).
#
# Requires: azure.parallel_stacks=true in bench.config.yaml + `make provision` (which
# then creates sut/loadgen in zone 1 and sut2/loadgen2 in zone 2). Each stack is a
# normal detached run on its own loadgen+SUT, sharing one cached Synthea dataset in
# Blob (generation skipped; each server still seed-loads it once). Results upload under
# run-<ts>-s1 / run-<ts>-s2; `make report-parallel` merges them into one head-to-head.
#
#   SERVERS_1=fhir-server-go SERVERS_2=hapi orchestrator/run-parallel.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

# Safety: in parallel mode auto-stop is a footgun — the first stack to finish would
# deallocate ALL VMs (its self-stop targets the whole RG), killing the other stack
# mid-run. Refuse unless it's off; stop/deallocate manually after both finish.
if [[ "$(bin/cfg azure.auto_stop_when_done 2>/dev/null)" == "true" ]]; then
  echo "ERROR: set azure.auto_stop_when_done=false for parallel runs (else the first" >&2
  echo "       stack to finish deallocates the other mid-run). Stop manually after both." >&2
  exit 1
fi

S1="${SERVERS_1:-fhir-server-go}"   # stack 1 (zone 1)
S2="${SERVERS_2:-hapi}"             # stack 2 (zone 2)
TS="run-$(date -u '+%Y%m%d-%H%M%S')"   # shared base so both prefixes group as one run

echo "==> parallel run: stack1[zone1]='$S1'  stack2[zone2]='$S2'  prefix=$TS-s{1,2}"
RUN_PREFIX="$TS" STACK=1 SERVERS="$S1" orchestrator/run-detached.sh
RUN_PREFIX="$TS" STACK=2 SERVERS="$S2" orchestrator/run-detached.sh

cat <<EOF

==> Both stacks launched (concurrent, separate zones). They share the cached dataset,
    so only the per-server seed-load runs (no Synthea generation). Manage them:
      make status STACK=1        # $S1
      make status STACK=2        # $S2
    When BOTH show DONE:
      make report-parallel       # pull both servers' results -> one head-to-head report
    Stop / halt billing:
      make stop STACK=1 ; make stop STACK=2        # stop the runs
      make stop DEALLOCATE=1                       # also deallocate all VMs
EOF
