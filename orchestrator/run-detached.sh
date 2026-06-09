#!/usr/bin/env bash
# Detached run: launch the benchmark controller ON the loadgen VM in tmux, so the
# whole run survives the operator laptop sleeping / disconnecting. The controller
# runs generate/seed/k6 locally on the loadgen and ssh-routes only the SUT leg
# (build/up/snapshot/restore) to the SUT over the private network — one ssh
# direction, one ephemeral key (added to the SUT, never your personal key on a VM).
#
# Assumes infra is already up (run `make infra-up` first, or ./reproduce.sh path).
# Tunables pass through from the env: SIZE / REPS / WARMUP_S / MEASURE_S / COOLDOWN_S
# / SCENARIOS / SEED_CONCURRENCY (all optional; fall back to bench.config.yaml).
#   orchestrator/run-detached.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
cfg() { bin/cfg "$1"; }

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
ssh $OPTS "$USER@$loadgen_ip" "chmod 600 ~/.ssh/bench_ctrl && (command -v tmux >/dev/null || sudo apt-get install -y -qq tmux)"

# Pass-through tunables (empty -> orchestrate falls back to bench.config.yaml).
envs=""
for v in SIZE REPS WARMUP_S MEASURE_S COOLDOWN_S SCENARIOS SEED_CONCURRENCY; do
  [[ -n "${!v:-}" ]] && envs+="$v='${!v}' "
done
CTRL_OPTS="-i \$HOME/.ssh/bench_ctrl -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
REMOTE_CMD="cd '$REPO' && REMOTE=1 LOADGEN_LOCAL=1 SUT_SSH='$USER@$sut_priv' SUT_REPO='$REPO' SUT_PRIVATE_HOST='$sut_priv' SSH_OPTS=\"$CTRL_OPTS\" $envs orchestrator/orchestrate.sh all > run.log 2>&1; echo \$? > run.exit; touch run.done"

echo "==> launching controller in tmux 'bench' on the loadgen"
ssh $OPTS "$USER@$loadgen_ip" "cd '$REPO' && tmux new-session -d -s bench \"$REMOTE_CMD\""

cat > "$ROOT/.detached.env" <<EOF
ADMIN=$USER
LOADGEN_IP=$loadgen_ip
SUT_IP=$sut_ip
REPO=$REPO
SSH_OPTS="$OPTS"
EOF
cat <<EOF

==> Detached run started on the loadgen VM (tmux session 'bench').
    Your laptop can now sleep / disconnect.

    Watch:   make run-status         (or: ssh $OPTS $USER@$loadgen_ip 'tail -f $REPO/run.log')
    Attach:  ssh $OPTS $USER@$loadgen_ip -t 'tmux attach -t bench'
    Fetch:   make fetch-results      (when run-status shows DONE)
    Stop:    ssh $OPTS $USER@$loadgen_ip 'tmux kill-session -t bench'

    Remember: 'make infra-down' once you've fetched results (stops billing).
EOF
