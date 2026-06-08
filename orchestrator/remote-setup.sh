#!/usr/bin/env bash
# Wire the operator -> Azure VMs for a remote run. Reads Terraform outputs, waits
# for SSH on the SUT + loadgen VMs, copies the working tree to both (code + your
# bench.config.yaml — the Synthea jar, dataset, and Docker images are generated ON
# the VMs, never copied), and writes .remote.env with the REMOTE wiring that
# reproduce.sh sources and orchestrate.sh consumes. Copy uses tar-over-ssh so no
# rsync is needed on either end. Secrets (.env) are NOT copied — the VMs never talk
# to Azure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
cfg() { bin/cfg "$1"; }

USER="$(cfg azure.admin_username)"
KEY_PUB="$(cfg azure.ssh_public_key_path)"; KEY_PUB="${KEY_PUB/#\~/$HOME}"
KEY="${KEY_PUB%.pub}"
[[ -f "$KEY" ]] || { echo "private key not found: $KEY (pair of $KEY_PUB)"; exit 1; }
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

out="$(cd infra && terraform output -json)"
sut_ip="$(echo "$out"     | yq -r '.public_ips.value.sut')"
loadgen_ip="$(echo "$out" | yq -r '.public_ips.value.loadgen')"
sut_priv="$(echo "$out"   | yq -r '.private_ips.value.sut')"
[[ -n "$sut_ip" && -n "$loadgen_ip" && -n "$sut_priv" ]] || { echo "missing Terraform outputs (is infra up?)"; exit 1; }
REPO_DIR="/home/$USER/os-fhir-server-bench"

wait_ssh() { # <ip> — wait for sshd AND for cloud-init (Docker/k6/etc.) to finish.
  echo "==> waiting for ssh: $USER@$1"
  local up=0
  for _ in $(seq 1 60); do
    ssh $SSH_OPTS "$USER@$1" true 2>/dev/null && { up=1; break; }
    sleep 5
  done
  [[ "$up" == 1 ]] || { echo "ERROR: ssh to $1 not ready after 5min" >&2; return 1; }
  echo "==> waiting for cloud-init to finish on $1 (Docker/k6/tools install)"
  # blocks until first-boot provisioning is done; non-zero exit if it errored
  ssh $SSH_OPTS "$USER@$1" "sudo cloud-init status --wait" || {
    echo "ERROR: cloud-init did not complete cleanly on $1" >&2; return 1; }
}

copy_repo() { # <ip>
  echo "==> copying working tree -> $1:$REPO_DIR"
  ssh $SSH_OPTS "$USER@$1" "rm -rf '$REPO_DIR' && mkdir -p '$REPO_DIR'"
  tar czf - -C "$ROOT" \
    --exclude=.git --exclude=dataset/output --exclude=dataset/snapshots \
    --exclude=results --exclude=.terraform --exclude='*.tfstate*' \
    --exclude=.env --exclude='servers/*/.src' --exclude='servers/*/.env' \
    --exclude='*.jar' --exclude=.remote.env . \
  | ssh $SSH_OPTS "$USER@$1" "tar xzf - -C '$REPO_DIR'"
}

wait_ssh "$sut_ip"
wait_ssh "$loadgen_ip"
copy_repo "$sut_ip"
copy_repo "$loadgen_ip"

cat > "$ROOT/.remote.env" <<EOF
REMOTE=1
SUT_SSH=$USER@$sut_ip
LOADGEN_SSH=$USER@$loadgen_ip
SUT_REPO=$REPO_DIR
LOADGEN_REPO=$REPO_DIR
SUT_PRIVATE_HOST=$sut_priv
SSH_OPTS=$SSH_OPTS
EOF
echo "==> wrote .remote.env  (SUT=$sut_ip  loadgen=$loadgen_ip  sut_private=$sut_priv)"
