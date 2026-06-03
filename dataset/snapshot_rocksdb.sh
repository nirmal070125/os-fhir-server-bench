#!/usr/bin/env bash
# Snapshot a RocksDB-backed server (Blaze) by archiving its data volume. RocksDB
# must be quiesced for a consistent copy, so the container is stopped, the volume
# is tarred, and the container is restarted. Connection via env:
#   BLAZE_VOLUME     docker volume holding the data dir (e.g. bench-blaze_blazedata)
#   BLAZE_CONTAINER  container to stop/start around the copy
#   dataset/snapshot_rocksdb.sh <snapshot_file.tar.gz>
set -euo pipefail
OUT="${1:?usage: snapshot_rocksdb.sh <snapshot_file.tar.gz>}"
: "${BLAZE_VOLUME:?set BLAZE_VOLUME}"; : "${BLAZE_CONTAINER:?set BLAZE_CONTAINER}"
mkdir -p "$(dirname "$OUT")"

echo "==> stopping $BLAZE_CONTAINER for a consistent RocksDB copy"
docker stop "$BLAZE_CONTAINER" >/dev/null
echo "==> archiving volume $BLAZE_VOLUME -> $OUT"
docker run --rm -v "$BLAZE_VOLUME":/data:ro -v "$(cd "$(dirname "$OUT")" && pwd)":/out \
  alpine:3.20 tar czf "/out/$(basename "$OUT")" -C /data .
echo "==> restarting $BLAZE_CONTAINER"
docker start "$BLAZE_CONTAINER" >/dev/null
echo "==> snapshot size: $(du -h "$OUT" | cut -f1)"
