#!/usr/bin/env bash
# Deallocate every VM in the resource group, using THIS VM's system-assigned managed
# identity (no secrets, no az CLI — just IMDS + the ARM REST API + curl/jq). Called by
# a detached run after the report uploads, when azure.auto_stop_when_done is true.
# Deallocate stops COMPUTE billing immediately; disks/IPs remain (cheap) until
# `make infra-down`. Deallocates the loadgen (self) LAST so the other requests land first.
# Env: BENCH_SUB (subscription id), BENCH_RG (resource group).
set -uo pipefail
: "${BENCH_SUB:?}"; : "${BENCH_RG:?}"
API="2023-07-01"
IMDS="http://169.254.169.254/metadata"

tok="$(curl -s -H Metadata:true "$IMDS/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" | jq -r '.access_token // empty')"
if [[ -z "$tok" ]]; then
  echo "self-stop: no managed-identity token — skipping (is auto_stop_when_done + the role assignment in place?)" >&2
  exit 0
fi
self="$(curl -s -H Metadata:true "$IMDS/instance/compute/name?api-version=2021-02-01&format=text")"
base="https://management.azure.com/subscriptions/$BENCH_SUB/resourceGroups/$BENCH_RG/providers/Microsoft.Compute/virtualMachines"

vms="$(curl -s -H "Authorization: Bearer $tok" "$base?api-version=$API" | jq -r '.value[].name')"
[[ -n "$vms" ]] || { echo "self-stop: could not list VMs (role not yet effective?) — skipping" >&2; exit 0; }

deallocate() { echo "self-stop: deallocating $1"; curl -s -X POST -H "Authorization: Bearer $tok" "$base/$1/deallocate?api-version=$API" >/dev/null; }
for vm in $vms; do [[ "$vm" == "$self" ]] && continue; deallocate "$vm"; done
deallocate "$self"   # last — this stops the VM we're running on
echo "self-stop: deallocation requested for all VMs in $BENCH_RG (report is in Blob; 'make infra-down' to fully remove)"
