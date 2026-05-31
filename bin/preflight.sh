#!/usr/bin/env bash
# Fail fast BEFORE provisioning anything: verify tooling, creds, and config
# sanity so a reproducer never half-provisions and then errors out.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ok=1
red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

need() {
  if command -v "$1" >/dev/null 2>&1; then grn "  ok   $1"; else red "  MISS $1"; ok=0; fi
}

echo "Tools:"
need terraform; need az; need ssh; need make; need yq

echo "Azure credentials (.env / environment):"
for v in ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_ID ARM_CLIENT_SECRET; do
  if [[ -n "${!v:-}" ]]; then grn "  ok   $v"; else red "  MISS $v"; ok=0; fi
done

echo "Config sanity:"
key_path="$(yq -r '.azure.ssh_public_key_path' bench.config.yaml 2>/dev/null || echo '')"
key_path="${key_path/#\~/$HOME}"
if [[ -n "$key_path" && -f "$key_path" ]]; then grn "  ok   ssh public key: $key_path"; else red "  MISS ssh public key ($key_path)"; ok=0; fi

cidr="$(yq -r '.azure.allowed_ssh_cidr' bench.config.yaml 2>/dev/null || echo '')"
if [[ "$cidr" == "0.0.0.0/0" ]]; then
  warn "  WARN allowed_ssh_cidr is 0.0.0.0/0 — SSH open to the internet. Set it to <your.ip>/32."
fi

size="$(yq -r '.dataset.size' bench.config.yaml 2>/dev/null || echo '')"
if [[ "$size" == "large" ]]; then
  warn "  WARN dataset.size=large — full all-six run is the ~\$50 / multi-hour headline run."
fi

enabled="$(yq -r '.servers | to_entries | map(select(.value.enabled)) | .[].key' bench.config.yaml 2>/dev/null | paste -sd, -)"
grn "  info enabled servers: ${enabled:-none}"

echo
if [[ "$ok" == "1" ]]; then grn "Preflight passed."; else red "Preflight FAILED — fix the items above."; exit 1; fi
