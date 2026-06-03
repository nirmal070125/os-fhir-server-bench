#!/usr/bin/env bash
# Benchmark run driver. Two phases (also the Makefile `seed` / `run` targets):
#
#   seed : per enabled server -> build, start, load the dataset via the public
#          API, snapshot the loaded+indexed DB. Done once; the snapshot is reused.
#   run  : per enabled server x scenario x repetition ->
#            restore snapshot (identical starting state)  ->  warm-up (discarded)
#            ->  measure (captured)  ->  cooldown.  Then write a run manifest.
#
# Everything tunable comes from bench.config.yaml; a few env overrides exist for
# iterating locally (REPS, WARMUP_S, MEASURE_S, COOLDOWN_S, SERVERS, SCENARIOS,
# SKIP_BUILD, KEEP_UP). Endpoints default to localhost but are overridable
# (SUT_API_HOST, SUT_DB_HOST) so the driver can run on the loadgen VM against the
# SUT VM without code changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
cfg() { bin/cfg "$1"; }
log() { printf '\033[36m[orchestrate]\033[0m %s\n' "$*"; }

CMD="${1:-all}"   # seed | run | all

# --- resolve config (env overrides win) ------------------------------------
SIZE="$(cfg dataset.size)"
# (portable to bash 3.2 — no mapfile/readarray)
SERVERS_CFG=()
while IFS= read -r _s; do [[ -n "$_s" ]] && SERVERS_CFG+=("$_s"); done \
  < <(yq -r '.servers | to_entries | map(select(.value.enabled)) | .[].key' bench.config.yaml)
read -r -a SERVERS <<< "${SERVERS:-${SERVERS_CFG[*]}}"
read -r -a SCENARIOS <<< "${SCENARIOS:-$(yq -r '.run.scenarios | join(" ")' bench.config.yaml)}"
REPS="${REPS:-$(cfg run.repetitions)}"
WARMUP_S="${WARMUP_S:-$(cfg run.warmup_s)}"
MEASURE_S="${MEASURE_S:-$(cfg run.measure_s)}"
COOLDOWN_S="${COOLDOWN_S:-$(cfg run.cooldown_s)}"
SUT_API_HOST="${SUT_API_HOST:-localhost}"
SUT_DB_HOST="${SUT_DB_HOST:-localhost}"
SNAP_DIR="$ROOT/dataset/snapshots"

# --- per-server helpers ----------------------------------------------------
profile_dir() { echo "$ROOT/servers/$1"; }
server_engine() { yq -r '.engine' "$(profile_dir "$1")/manifest.yaml"; }
server_base_url() { echo "http://${SUT_API_HOST}:$(cfg "servers.$1.port")$(cfg "servers.$1.base_path")"; }
server_health_url() { echo "http://${SUT_API_HOST}:$(cfg "servers.$1.port")$(cfg "servers.$1.health_path")"; }
wait_ready() { # <url>
  local url="$1" deadline=$((SECONDS + 300))
  until curl -fsS -o /dev/null "$url"; do
    (( SECONDS >= deadline )) && { echo "ERROR: not ready after 300s: $url" >&2; return 1; }
    sleep 3
  done
}
snapshot_path() { echo "$SNAP_DIR/$1-$SIZE.dump"; }

# Export the DB connection for the engine's snapshot/restore scripts.
set_db_env() {
  local server="$1" engine mf; engine="$(server_engine "$server")"
  mf="$(profile_dir "$server")/manifest.yaml"
  case "$engine" in
    postgres)
      # creds come from the server's manifest (each server uses its own db/user)
      export PGHOST="$SUT_DB_HOST"
      export PGPORT="$(cfg "servers.$server.db_port")"
      export PGUSER="$(yq -r '.dataset.pg.user' "$mf")"
      export PGPASSWORD="$(yq -r '.dataset.pg.password' "$mf")"
      export PGDATABASE="$(yq -r '.dataset.pg.database' "$mf")"
      ;;
    rocksdb)
      # Blaze: filesystem snapshot of the data volume; restore stops/starts the container.
      export BLAZE_VOLUME="$(yq -r '.dataset.volume' "$mf")"
      export BLAZE_CONTAINER="$(yq -r '.dataset.container' "$mf")"
      ;;
    mssql)
      export MSSQL_HOST="$SUT_DB_HOST"
      export MSSQL_PORT="$(cfg "servers.$server.db_port")"
      export MSSQL_SA_PASSWORD="$(yq -r '.dataset.mssql.sa_password' "$mf")"
      export MSSQL_DATABASE="$(yq -r '.dataset.mssql.database' "$mf")"
      export MSSQL_CONTAINER="bench-${server}-sql-1"
      export MSSQL_BACKUP_DIR="$(profile_dir "$server")/backup"
      ;;
    *) echo "ERROR: engine '$engine' not supported by the orchestrator" >&2; exit 1 ;;
  esac
}

start_server() {
  local server="$1"
  [[ "${SKIP_BUILD:-0}" == "1" ]] || "$(profile_dir "$server")/build.sh"
  "$(profile_dir "$server")/up.sh"
}
stop_server() {
  [[ "${KEEP_UP:-0}" == "1" ]] && { log "KEEP_UP=1 — leaving $1 running"; return; }
  "$(profile_dir "$1")/down.sh" -v
}

# --- phases ----------------------------------------------------------------
phase_seed() {
  local server="$1" engine snap base_url
  engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"; base_url="$(server_base_url "$server")"
  if [[ -f "$snap" ]]; then log "seed: snapshot exists ($snap) — skipping"; return; fi

  log "seed: $server — generate (if needed) -> load -> snapshot"
  [[ -d "$ROOT/dataset/output/$SIZE/fhir" ]] || "$ROOT/dataset/generate.sh"
  start_server "$server"
  "$ROOT/dataset/seed.sh" "$base_url"
  set_db_env "$server"
  mkdir -p "$SNAP_DIR"
  "$ROOT/dataset/snapshot_${engine}.sh" "$snap"
}

# One measured repetition: reset state, warm up (discard), measure (capture).
run_rep() {
  local server="$1" scenario="$2" rep="$3" engine snap base_url outdir
  engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"; base_url="$(server_base_url "$server")"
  outdir="$ROOT/results/$server/$scenario/rep-$rep"
  set_db_env "$server"
  log "  rep $rep: restore -> warm-up ${WARMUP_S}s (discard) -> measure ${MEASURE_S}s (capture)"
  "$ROOT/dataset/restore_${engine}.sh" "$snap" >/dev/null
  wait_ready "$(server_health_url "$server")"   # rocksdb restart needs this; no-op once up
  CAPTURE=0 "$ROOT/scenarios/run.sh" "$scenario" "$base_url" "${WARMUP_S}s"
  CAPTURE=1 OUTDIR="$outdir" "$ROOT/scenarios/run.sh" "$scenario" "$base_url" "${MEASURE_S}s"
  [[ "$COOLDOWN_S" -gt 0 ]] && sleep "$COOLDOWN_S" || true
}

write_manifest() {
  local server="$1" out="$ROOT/results/$server/run-manifest.json"
  local sha; sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  # `|| true` so a hash failure (e.g. no dataset yet, or no sha256sum) never aborts
  # manifest writing under `set -e`; NR==1 keeps it a single line for valid JSON.
  local hash; hash="$("$ROOT/dataset/hash.sh" 2>/dev/null | awk 'NR==1{print $1}' || true)"; hash="${hash:-unknown}"
  mkdir -p "$(dirname "$out")"
  {
    echo '{'
    echo "  \"server\": \"$server\","
    echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"bench_repo_sha\": \"$sha\","
    echo "  \"k6_version\": \"$(k6 version 2>/dev/null | head -1 || echo unknown)\","
    echo "  \"host\": { \"nproc\": \"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')\" },"
    echo "  \"pin\": { \"repo\": \"$(cfg "servers.$server.repo" 2>/dev/null || echo n/a)\", \"ref\": \"$(cfg "servers.$server.ref" 2>/dev/null || echo n/a)\", \"commit\": \"$(cfg "servers.$server.commit" 2>/dev/null || echo n/a)\" },"
    echo "  \"limits\": { \"sut_cpus\": $(cfg limits.sut_cpus), \"sut_mem\": \"$(cfg limits.sut_mem)\", \"db_cpus\": $(cfg limits.db_cpus), \"db_mem\": \"$(cfg limits.db_mem)\" },"
    echo "  \"dataset\": { \"size\": \"$SIZE\", \"hash\": \"$hash\" },"
    echo "  \"slo\": { \"p99_ms\": $(cfg slo.p99_ms), \"max_error_rate\": $(cfg slo.max_error_rate) },"
    echo "  \"run\": { \"repetitions\": $REPS, \"warmup_s\": $WARMUP_S, \"measure_s\": $MEASURE_S, \"cooldown_s\": $COOLDOWN_S },"
    echo "  \"scenarios\": [$(printf '"%s",' "${SCENARIOS[@]}" | sed 's/,$//')]"
    echo '}'
  } > "$out"
  log "wrote manifest: $out"
}

phase_run() {
  local server="$1" snap; snap="$(snapshot_path "$server")"
  [[ -f "$snap" ]] || { echo "ERROR: no snapshot for $server ($snap) — run the seed phase first" >&2; exit 1; }
  start_server "$server"
  for scenario in "${SCENARIOS[@]}"; do
    log "$server / $scenario — $REPS rep(s)"
    for rep in $(seq 1 "$REPS"); do run_rep "$server" "$scenario" "$rep"; done
  done
  write_manifest "$server"
  stop_server "$server"
}

# --- main ------------------------------------------------------------------
log "command=$CMD  servers=[${SERVERS[*]}]  scenarios=[${SCENARIOS[*]}]  size=$SIZE  reps=$REPS"
for server in "${SERVERS[@]}"; do
  case "$CMD" in
    seed) phase_seed "$server"; stop_server "$server" ;;
    run)  phase_run "$server" ;;
    all)  phase_seed "$server"; SKIP_BUILD=1 phase_run "$server" ;;  # seed already built it
    *) echo "usage: orchestrate.sh <seed|run|all>" >&2; exit 1 ;;
  esac
done
log "done."
