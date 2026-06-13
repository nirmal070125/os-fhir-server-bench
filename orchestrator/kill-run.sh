#!/usr/bin/env bash
# Forcefully stop a detached benchmark run on THIS host (the loadgen). `make stop`
# pipes this in over ssh (`ssh … 'bash -s' < orchestrator/kill-run.sh`).
#
# Why a dedicated script: killing only the tmux session leaves the controller
# orphaned — it gets reparented to init and, if it was blocked in an ssh/restore,
# survives a single `pkill -f orchestrate.sh` and can even spawn the next restore.
# So we kill the whole family (wrapper, controller, its ssh legs to the SUT, k6, the
# restore, the heartbeat), TERM first then KILL, and VERIFY nothing survives. Every
# step is best-effort, so it's safe to run when nothing is in flight.
set -uo pipefail

# Patterns matched against the full command line (pkill -f / pgrep -f).
PATTERNS=(
  ".detached-run.sh"            # launch wrapper (parents the heartbeat loop)
  "orchestrator/orchestrate.sh" # the controller
  "scenarios/run.sh"            # per-level launcher
  "k6 run"                      # the load generator
  "dataset/restore_postgres.sh" # in-flight restore invocation
  "reporting/upload-sas.sh"     # heartbeat uploader
  "ssh .*benchadmin@"           # controller's ssh legs to the SUT
)

tmux kill-session -t bench 2>/dev/null || true

# Graceful (TERM), brief grace, then forceful (KILL).
for sig in TERM KILL; do
  for p in "${PATTERNS[@]}"; do pkill -"$sig" -f "$p" 2>/dev/null || true; done
  [ "$sig" = TERM ] && sleep 3
done
sleep 1

# Verify nothing bench-related is left running.
left="$(pgrep -af 'orchestrate\.sh|scenarios/run\.sh|k6 run|restore_postgres|\.detached-run\.sh' 2>/dev/null || true)"
if [ -n "$left" ]; then
  echo "WARN: bench processes still present after KILL:"
  echo "$left"
  exit 1
fi
echo "loadgen clean — no bench processes remain"
