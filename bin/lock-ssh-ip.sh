#!/usr/bin/env bash
# Lock azure.allowed_ssh_cidr in bench.config.yaml to this machine's current public
# IP, so SSH to the VMs works without hand-editing (your IP drifts on Wi-Fi/VPN).
# Idempotent; called automatically by `make infra-up` before Terraform writes the
# NSG rule. Non-fatal: if the IP can't be detected (offline), it leaves the existing
# value and lets preflight/Terraform proceed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
   || curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "lock-ssh-ip: could not detect public IP — leaving allowed_ssh_cidr unchanged" >&2
  exit 0
fi

current="$(bin/cfg azure.allowed_ssh_cidr 2>/dev/null || echo '')"
if [[ "$current" == "$ip/32" ]]; then
  echo "==> allowed_ssh_cidr already $ip/32"
else
  perl -i -pe "s#^(\s*allowed_ssh_cidr:).*#\1 \"$ip/32\"#" bench.config.yaml
  echo "==> allowed_ssh_cidr locked to $ip/32 (was: ${current:-unset})"
fi
