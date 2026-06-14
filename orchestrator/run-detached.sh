#!/usr/bin/env bash
# Detached run: launch the benchmark controller ON the loadgen VM in tmux, so the
# whole run survives the operator laptop sleeping / disconnecting. The controller
# runs generate/seed/k6 locally on the loadgen and ssh-routes only the SUT leg
# (build/up/snapshot/restore) to the SUT over the private network — one ssh
# direction, one ephemeral key (added to the SUT, never your personal key on a VM).
#
# Assumes infra is already up (run `make provision` first, or ./reproduce.sh path).
# Tunables pass through from the env: SIZE / REPS / WARMUP_S / MEASURE_S / COOLDOWN_S
# / SCENARIOS / SEED_CONCURRENCY (all optional; fall back to bench.config.yaml).
#   orchestrator/run-detached.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
cfg() { bin/cfg "$1"; }
# Load .env for optional BENCH_NOTIFY_URL / BENCH_NOTIFY_KIND (webhook notification).
[[ -f .env ]] && { set -a; . ./.env; set +a; }

USER="$(cfg azure.admin_username)"
KEY_PUB="$(cfg azure.ssh_public_key_path)"; KEY_PUB="${KEY_PUB/#\~/$HOME}"; KEY="${KEY_PUB%.pub}"
[[ -f "$KEY" ]] || { echo "private key not found: $KEY"; exit 1; }
OPTS="-i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

out="$(cd infra && terraform output -json)"
sut_ip="$(echo "$out" | yq -r '.public_ips.value.sut')"
loadgen_ip="$(echo "$out" | yq -r '.public_ips.value.loadgen')"
sut_priv="$(echo "$out" | yq -r '.private_ips.value.sut')"
[[ -n "$sut_ip" && -n "$loadgen_ip" && -n "$sut_priv" ]] || { echo "missing Terraform outputs (is infra up?)"; exit 1; }
REPO="/home/$USER/os-fhir-server-bench"

wait_ssh() { echo "==> waiting for ssh+cloud-init: $1"; local up=0
  for _ in $(seq 1 60); do ssh $OPTS "$USER@$1" true 2>/dev/null && { up=1; break; }; sleep 5; done
  [[ "$up" == 1 ]] || { echo "ssh to $1 not ready" >&2; return 1; }
  ssh $OPTS "$USER@$1" "sudo cloud-init status --wait" || { echo "cloud-init failed on $1" >&2; return 1; }
}
copy_repo() { echo "==> copying working tree -> $1"; ssh $OPTS "$USER@$1" "rm -rf '$REPO' && mkdir -p '$REPO'"
  tar czf - -C "$ROOT" --exclude=.git --exclude=dataset/output --exclude=dataset/snapshots \
    --exclude=results --exclude=.terraform --exclude='*.tfstate*' --exclude=.env \
    --exclude='servers/*/.src' --exclude='servers/*/.env' --exclude='*.jar' \
    --exclude='.remote.env' --exclude='.detached.env' . | ssh $OPTS "$USER@$1" "tar xzf - -C '$REPO'"
}

wait_ssh "$sut_ip"; wait_ssh "$loadgen_ip"

# Refuse to clobber a run already in flight: copy_repo below does `rm -rf $REPO`, and
# tmux can't start a second 'bench' session — so re-launching over a live run would
# damage it AND fail to start a new one. Stop it cleanly first (make stop), or pass
# FORCE=1 to stop the in-flight run here before relaunching.
if ssh $OPTS "$USER@$loadgen_ip" 'tmux has-session -t bench 2>/dev/null'; then
  if [[ "${FORCE:-0}" == "1" ]]; then
    echo "==> FORCE=1: stopping the in-flight run on the loadgen first"
    ssh $OPTS "$USER@$loadgen_ip" 'tmux kill-session -t bench 2>/dev/null; pkill -f k6 || true; pkill -f orchestrate.sh || true'
    sleep 3
  else
    echo "ERROR: a benchmark run is already in flight on the loadgen (tmux session 'bench')." >&2
    echo "       Stop it first:  make stop      (or re-run with FORCE=1 to replace it)" >&2
    exit 1
  fi
fi

copy_repo "$sut_ip"; copy_repo "$loadgen_ip"

# Ephemeral key so the loadgen can ssh the SUT over the private network (we don't put
# your personal key on a VM). Add its public half to the SUT's authorized_keys.
TMPK="$(mktemp -d)/bench_ctrl"; trap 'rm -rf "$(dirname "$TMPK")"' EXIT
ssh-keygen -t ed25519 -f "$TMPK" -N '' -q -C bench-detached-controller
pub="$(cat "$TMPK.pub")"
echo "==> authorizing controller key on the SUT"
ssh $OPTS "$USER@$sut_ip" "mkdir -p ~/.ssh && grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys"
echo "==> installing the controller key + tmux on the loadgen"
scp $OPTS -q "$TMPK" "$USER@$loadgen_ip:.ssh/bench_ctrl"
ssh $OPTS "$USER@$loadgen_ip" "chmod 600 ~/.ssh/bench_ctrl && (command -v tmux >/dev/null || sudo apt-get install -y -qq tmux) && (command -v ts >/dev/null || sudo apt-get install -y -qq moreutils)"

# --- storage SAS so the run publishes its report to Blob (no az needed on the VM) ---
# The operator (you) has az; mint a short-lived container write-SAS for the upload and
# a 7-day read URL for report.md to view later in a browser. All non-fatal: if it
# can't be set up, the run still keeps the report on the VM (use `make report`).
acct="$(echo "$out" | yq -r '.storage_account.value // ""')"
container="$(echo "$out" | yq -r '.blob_container.value // ""')"
prefix="run-$(date -u '+%Y%m%d-%H%M%S')"
upload_url=""; report_view=""
if [[ -n "$acct" && -n "$container" ]] && command -v az >/dev/null 2>&1; then
  key="$(az storage account keys list -g "$(cfg azure.resource_group)" -n "$acct" --query '[0].value' -o tsv 2>/dev/null || true)"
  if [[ -n "$key" ]]; then
    wexp="$(date -u -v+2d '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+2 days' '+%Y-%m-%dT%H:%MZ')"
    rexp="$(date -u -v+7d '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+7 days' '+%Y-%m-%dT%H:%MZ')"
    wsas="$(az storage container generate-sas --account-name "$acct" --account-key "$key" -n "$container" --permissions cw --https-only --expiry "$wexp" -o tsv 2>/dev/null || true)"
    [[ -n "$wsas" ]] && upload_url="https://$acct.blob.core.windows.net/$container?$wsas"
    report_view="$(az storage blob generate-sas --account-name "$acct" --account-key "$key" -c "$container" -n "$prefix/report.md" --permissions r --https-only --full-uri --expiry "$rexp" -o tsv 2>/dev/null || true)"
    log_view="$(az storage blob generate-sas --account-name "$acct" --account-key "$key" -c "$container" -n "$prefix/run.log" --permissions r --https-only --full-uri --expiry "$rexp" -o tsv 2>/dev/null || true)"
  fi
fi
log_view="${log_view:-}"
[[ -z "$upload_url" ]] && echo "NOTE: Blob SAS unavailable — report will stay on the VM; use 'make report'." >&2

# --- cache SAS: lets the VMs reuse the dataset + seeded snapshot across runs ----------
# A 30-day container SAS (read+create+write) so blobcache.sh can pull/push cache blobs
# with curl. Non-fatal: if unavailable, the orchestrator just regenerates + re-seeds.
cache_sas=""
if [[ -n "$acct" && -n "$container" && -n "${key:-}" ]]; then
  cexp="$(date -u -v+30d '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+30 days' '+%Y-%m-%dT%H:%MZ')"
  csas="$(az storage container generate-sas --account-name "$acct" --account-key "$key" -n "$container" --permissions rcw --https-only --expiry "$cexp" -o tsv 2>/dev/null || true)"
  [[ -n "$csas" ]] && cache_sas="https://$acct.blob.core.windows.net/$container?$csas"
fi
[[ -n "$cache_sas" ]] && echo "==> dataset/snapshot cache ON (reuse across runs via Blob)"

# --- write a self-contained launch script to the VM, run it in tmux ---------------
# Generating a file (vs a deeply-nested ssh/tmux command) avoids quoting hell with the
# SAS token. orchestrate -> report -> upload, all logged to run.log; run.done at the end.
upload_line=":"
[[ -n "$upload_url" ]] && upload_line="reporting/upload-sas.sh \"$upload_url\" \"$prefix\" || true"
# Heartbeat: while the run is in flight, push run.log (+ whatever results exist) to Blob
# every 60s. Without this the blob appeared only at the very end — so a long run was a
# blind wait and a HANG produced no blob at all. Now the blob exists within ~a minute and
# the log updates live, so an in-progress or stuck run is diagnosable from your laptop.
hb_start=":"; hb_stop=":"
if [[ -n "$upload_url" ]]; then
  hb_start="( while [ ! -f run.done ]; do reporting/upload-sas.sh \"$upload_url\" \"$prefix\" >/dev/null 2>&1 || true; sleep 60; done ) & HB_PID=\$!"
  hb_stop="[[ -n \"\${HB_PID:-}\" ]] && kill \"\$HB_PID\" 2>/dev/null || true"
fi
# Auto-stop: after the report uploads, the loadgen deallocates all VMs via its managed
# identity (config azure.auto_stop_when_done + the Owner-only role assignment).
stop_line=":"
if [[ "$(cfg azure.auto_stop_when_done 2>/dev/null)" == "true" ]]; then
  stop_line="BENCH_SUB='$(az account show --query id -o tsv 2>/dev/null)' BENCH_RG='$(cfg azure.resource_group)' orchestrator/self-stop.sh"
  echo "==> auto-stop ON: VMs will deallocate after the report uploads"
fi
# Optional webhook notification when the run finishes (BENCH_NOTIFY_URL in .env).
notify_line=":"
if [[ -n "${BENCH_NOTIFY_URL:-}" ]]; then
  notify_line="BENCH_NOTIFY_URL='$BENCH_NOTIFY_URL' BENCH_NOTIFY_KIND='${BENCH_NOTIFY_KIND:-slack}' BENCH_RUN_PREFIX='$prefix' BENCH_REPORT_URL='$report_view' BENCH_LOG_URL='$log_view' orchestrator/notify.sh"
  echo "==> notify ON: will post to your webhook when the run finishes"
fi
exports="export REMOTE=1 LOADGEN_LOCAL=1 SUT_SSH='$USER@$sut_priv' SUT_REPO='$REPO' SUT_PRIVATE_HOST='$sut_priv'
export SSH_OPTS='-i /home/$USER/.ssh/bench_ctrl -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'"
[[ -n "$cache_sas" ]] && exports+="
export BENCH_CACHE_SAS='$cache_sas'"
for v in SIZE REPS WARMUP_S MEASURE_S COOLDOWN_S SCENARIOS SEED_CONCURRENCY \
         LOAD_MODEL CONCURRENCY_LEVELS RATE_LEVELS; do
  [[ -n "${!v:-}" ]] && exports+="
export $v='${!v}'"
done

launch="$(mktemp)"
cat > "$launch" <<LAUNCH
#!/usr/bin/env bash
cd "$REPO"
$exports
: > run.log   # create immediately so the blob appears (and is watchable) within ~a minute
# Prefix every log line with a wall-clock timestamp so a run can be analysed step by
# step — including the silent restore gaps (the timestamp on the marker before a restore
# vs the first line after it gives its duration). Uses moreutils 'ts' when present
# (installed on the loadgen above); falls back to a pass-through so it never breaks a run.
stamp() { if command -v ts >/dev/null 2>&1; then ts '[%Y-%m-%d %H:%M:%S]'; else cat; fi; }
# Start the live-log heartbeat BEFORE the run, stop it once run.done exists.
$hb_start
{
  orchestrator/orchestrate.sh all
  echo \$? > run.exit
  python3 reporting/report.py || true
} 2>&1 | stamp | tee -a run.log
touch run.done
$hb_stop
# Final authoritative upload AFTER the block so run.log is complete — runs even if the run
# failed, so the full log is always in Blob (upload-sas uploads run.log + report + summaries).
$upload_line
# Notify (reads run.exit for pass/fail) once the report+log are in Blob.
{ $notify_line ; } >> run.log 2>&1 || true
# self-stop runs last (it deallocates this very VM); log + report are already in Blob.
{ $stop_line ; } >> run.log 2>&1 || true
LAUNCH
scp $OPTS -q "$launch" "$USER@$loadgen_ip:$REPO/.detached-run.sh"
rm -f "$launch"

echo "==> launching controller in tmux 'bench' on the loadgen"
ssh $OPTS "$USER@$loadgen_ip" "chmod +x '$REPO/.detached-run.sh' && tmux new-session -d -s bench \"bash '$REPO/.detached-run.sh'\""

cat > "$ROOT/.detached.env" <<EOF
ADMIN=$USER
LOADGEN_IP=$loadgen_ip
SUT_IP=$sut_ip
REPO=$REPO
PREFIX=$prefix
SSH_OPTS="$OPTS"
EOF

cat <<EOF

==> Detached run started on the loadgen VM (tmux 'bench'). Your laptop can now
    sleep / disconnect / shut down — the run + report upload continue on the VM.

EOF
if [[ -n "$report_view" ]]; then cat <<EOF
    📊 Report (open in a browser once the run finishes, ~20-40 min — no laptop needed):
       $report_view
EOF
[[ -n "$log_view" ]] && cat <<EOF
    📜 Live log (appears within ~a minute, refreshes every 60s — watch progress / diagnose):
       $log_view
EOF
echo
else cat <<EOF
    (Blob publishing unavailable — fetch with 'make report' from your laptop.)

EOF
fi
cat <<EOF
    Watch / manage, from your laptop:
      make status                                                  # latest log + DONE
      ssh $OPTS $USER@$loadgen_ip 'tail -f $REPO/run.log'          # live stream
      ssh $OPTS $USER@$loadgen_ip -t 'tmux attach -t bench'        # live (Ctrl-b d to detach)
      make report                                                  # pull results + show locally
      make stop                                                    # stop this run (DEALLOCATE=1 also halts billing)

    When you've seen the report:  make teardown   (stops billing)
EOF
