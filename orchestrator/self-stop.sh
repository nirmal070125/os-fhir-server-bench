#!/usr/bin/env bash
# Deallocate VMs in the resource group, using THIS VM's system-assigned managed
# identity (no secrets, no az CLI — just IMDS + the ARM REST API + curl/jq). Called by
# a detached run after the report uploads, when azure.auto_stop_when_done is true.
# Deallocate stops COMPUTE billing immediately; disks/IPs remain (cheap) until
# `make teardown`. Deallocates the loadgen (self) LAST so the other requests land first.
# Env: BENCH_SUB (subscription id), BENCH_RG (resource group).
#   BENCH_STOP_VMS (optional, space-separated): deallocate ONLY these instead of the
#     whole RG. Parallel mode sets it to this stack's own SUT+loadgen, so a finishing
#     stack never touches the other stack's VMs. Unset = all VMs (sequential default).
#   BENCH_SHARED_VMS + BENCH_PEER_VMS (optional, parallel only): the shared obs VM is
#     deallocated ONLY when this is the LAST stack to finish — i.e. when every VM in
#     BENCH_PEER_VMS (the other stack's SUT+loadgen) is already deallocated. Otherwise
#     obs is left up so the still-running stack keeps its monitoring. (Worst case — both
#     finish at once and neither sees the other down yet — obs lingers until manual
#     `make stop DEALLOCATE=1`; never stopped early.)
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

deallocate() { echo "self-stop: deallocating $1"; curl -s -X POST -H "Authorization: Bearer $tok" "$base/$1/deallocate?api-version=$API" >/dev/null; }
# Is a VM already deallocated? (instanceView power state == deallocated)
is_dealloc() { curl -s -H "Authorization: Bearer $tok" "$base/$1/instanceView?api-version=$API" \
  | jq -e '[.statuses[]?.code] | any(. == "PowerState/deallocated")' >/dev/null 2>&1; }

if [[ -n "${BENCH_STOP_VMS:-}" ]]; then
  vms="$BENCH_STOP_VMS"   # parallel: this stack's own VMs only (never the other stack's)
  # The shared obs VM is deallocated only if every peer VM is already down (we're last).
  if [[ -n "${BENCH_SHARED_VMS:-}" && -n "${BENCH_PEER_VMS:-}" ]]; then
    last=1
    for pv in $BENCH_PEER_VMS; do is_dealloc "$pv" || { last=0; break; }; done
    if [[ "$last" == 1 ]]; then
      echo "self-stop: last stack done — also deallocating shared: $BENCH_SHARED_VMS"
      vms="$vms $BENCH_SHARED_VMS"
    else
      echo "self-stop: peer stack still running — leaving shared VMs up: $BENCH_SHARED_VMS"
    fi
  fi
else
  vms="$(curl -s -H "Authorization: Bearer $tok" "$base?api-version=$API" | jq -r '.value[].name')"
  [[ -n "$vms" ]] || { echo "self-stop: could not list VMs (role not yet effective?) — skipping" >&2; exit 0; }
fi

# Deallocate everything except self first, then self last (it stops the VM we're on).
for vm in $vms; do [[ "$vm" == "$self" ]] && continue; deallocate "$vm"; done
case " $vms " in *" $self "*) deallocate "$self" ;; esac
echo "self-stop: deallocation requested for: ${vms// /, } (report is in Blob; 'make teardown' to fully remove)"
