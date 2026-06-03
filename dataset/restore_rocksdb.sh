#!/usr/bin/env bash
# Restore a RocksDB data volume before each run. Stops the container, wipes the
# volume, unpacks the snapshot, restarts. The orchestrator re-waits readiness
# afterward (the server reopens RocksDB on start). Env: BLAZE_VOLUME, BLAZE_CONTAINER.
#   dataset/restore_rocksdb.sh <snapshot_file.tar.gz>
set -euo pipefail
IN="${1:?usage: restore_rocksdb.sh <snapshot_file.tar.gz>}"
: "${BLAZE_VOLUME:?set BLAZE_VOLUME}"; : "${BLAZE_CONTAINER:?set BLAZE_CONTAINER}"

echo "==> stopping $BLAZE_CONTAINER"
docker stop "$BLAZE_CONTAINER" >/dev/null
echo "==> wiping + restoring volume $BLAZE_VOLUME from $IN"
docker run --rm -v "$BLAZE_VOLUME":/data -v "$(cd "$(dirname "$IN")" && pwd)":/in \
  alpine:3.20 sh -c "rm -rf /data/* /data/..?* 2>/dev/null; tar xzf /in/$(basename "$IN") -C /data"
echo "==> restarting $BLAZE_CONTAINER"
docker start "$BLAZE_CONTAINER" >/dev/null
echo "==> restore complete (orchestrator will wait for readiness)"
