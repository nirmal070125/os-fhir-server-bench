# servers/blaze/

**Blaze FHIR Server** comparator — `samply/blaze:0.30.0`, single container with
embedded **RocksDB** (no separate DB). Same CPU/mem envelope as every other SUT.
**Boot-verified** locally: health + CRUD green, and the RocksDB snapshot/restore
round-trips (write a row → restore → count back to baseline).

- Port `8080` (host `8082`), base path `/fhir`, readiness `GET /health`.
- Engine: `rocksdb` → `dataset/snapshot_rocksdb.sh` / `restore_rocksdb.sh`. Because
  RocksDB must be quiesced for a consistent copy, snapshot/restore briefly **stop the
  container**, tar/untar the `blazedata` volume, and restart it; the orchestrator
  re-waits `/health` after a restore.

## Usage

```bash
./build.sh && ./up.sh      # start + wait for /health
./down.sh                  # stop (-v to wipe the RocksDB volume)
```

Ports/limits come from `bench.config.yaml` via `_lib/lib.sh`. `BLAZE_HEAP` (default 4g)
caps the JVM heap inside the SUT memory limit.
