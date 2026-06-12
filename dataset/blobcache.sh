#!/usr/bin/env bash
# Minimal Blob cache over a pre-signed CONTAINER SAS (curl only — no az on the VM).
# Lets the orchestrator reuse the generated Synthea dataset and the seeded DB snapshot
# across runs / VM rebuilds, instead of regenerating + re-seeding every time (the seed
# is the ~hour-long cost; the dataset ~minutes).
#
#   blobcache.sh exists <blobpath>            # exit 0 if present, 1 if absent/no-cache
#   blobcache.sh get    <blobpath> <local>    # download blob -> local file
#   blobcache.sh put    <local> <blobpath>    # upload local file -> blob (single Put Blob)
#
# Auth: BENCH_CACHE_SAS = "https://<acct>.blob.core.windows.net/<container>?<sas>"
#       (container SAS with read+create+write). If UNSET/empty, this degrades safely:
#       exists/get -> miss (exit 1), put -> no-op (exit 0). So with no SAS the caller
#       transparently falls back to generate + seed (i.e. current behaviour). Every
#       failure here is non-fatal by design — caching must never break a run.
set -uo pipefail
cmd="${1:?usage: blobcache.sh exists|get|put ...}"
SAS="${BENCH_CACHE_SAS:-}"
PUT_CAP_BYTES=$((4500 * 1024 * 1024))   # single Put Blob limit ~5000 MiB; stay safely under

# No SAS configured -> behave as a permanent cache miss (caller will generate/seed).
if [[ -z "$SAS" ]]; then
  case "$cmd" in put) exit 0 ;; *) exit 1 ;; esac
fi

base="${SAS%%\?*}"   # https://acct.blob.core.windows.net/container
tok="${SAS#*\?}"     # the SAS query string

case "$cmd" in
  exists)
    blob="${2:?}"
    code="$(curl -fsS -o /dev/null -w '%{http_code}' -I "$base/$blob?$tok" 2>/dev/null || true)"
    [[ "$code" == "200" ]] ;;
  get)
    blob="${2:?}"; local_f="${3:?}"
    curl -fsS -o "$local_f" "$base/$blob?$tok" ;;
  put)
    local_f="${2:?}"; blob="${3:?}"
    [[ -f "$local_f" ]] || { echo "blobcache: $local_f missing — skip upload" >&2; exit 0; }
    sz="$(wc -c < "$local_f" 2>/dev/null || echo 0)"
    if (( sz > PUT_CAP_BYTES )); then
      echo "blobcache: $local_f is $((sz/1024/1024))MB > cap — skipping (needs chunked upload)" >&2; exit 0
    fi
    if curl -fsS -X PUT -H "x-ms-blob-type: BlockBlob" --data-binary @"$local_f" "$base/$blob?$tok" >/dev/null 2>&1; then
      echo "blobcache: cached $blob ($((sz/1024/1024))MB)"
    else
      echo "blobcache: upload failed for $blob (non-fatal)" >&2
    fi
    exit 0 ;;
  *) echo "usage: blobcache.sh exists|get|put ..." >&2; exit 2 ;;
esac
