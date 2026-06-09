#!/usr/bin/env bash
# Benchmark run driver. Two phases (also the Makefile `seed` / `run` targets):
#
#   seed : per enabled server -> build, start, load the dataset via the public
#          API, snapshot the loaded+indexed DB. Done once; the snapshot is reused.
#   run  : per enabled server x scenario x repetition ->
#            restore snapshot (identical starting state)  ->  warm-up (discarded)
#            ->  measure (captured)  ->  cooldown.  Then write a run manifest.
#
# EXECUTION MODES
#   Local  (default): every step runs on this machine against localhost. Used for
#          development and the CI smoke test.
#   Remote (REMOTE=1): this process is the operator/controller. It ssh-routes each
#          step to the right VM — ALL server + dataset work (build/up/down, generate,
#          seed, snapshot, restore) runs on the SUT VM; ONLY the measured k6 load
#          runs on the loadgen VM, targeting the SUT's private IP. Nothing heavy
#          touches the operator's disk; only the small results/ are pulled back.
#          No VM->VM ssh: the operator drives both legs. Set by reproduce.sh from
#          Terraform outputs:
#            REMOTE=1 SUT_SSH=user@host LOADGEN_SSH=user@host
#            SUT_REPO=/path LOADGEN_REPO=/path SUT_PRIVATE_HOST=10.x.x.x
#            SSH_OPTS="-i ~/.ssh/id_rsa -o StrictHostKeyChecking=accept-new"
#
# Everything tunable comes from bench.config.yaml; env overrides exist for local
# iteration (REPS, WARMUP_S, MEASURE_S, COOLDOWN_S, SERVERS, SCENARIOS, SKIP_BUILD,
# KEEP_UP).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
cfg() { bin/cfg "$1"; }
log() { printf '\033[36m[orchestrate]\033[0m %s\n' "$*"; }

CMD="${1:-all}"   # seed | run | all

# --- resolve config (env overrides win) ------------------------------------
SIZE="${SIZE:-$(cfg dataset.size)}"
SERVERS_CFG=()   # portable to bash 3.2 — no mapfile/readarray
while IFS= read -r _s; do [[ -n "$_s" ]] && SERVERS_CFG+=("$_s"); done \
  < <(yq -r '.servers | to_entries | map(select(.value.enabled)) | .[].key' bench.config.yaml)
read -r -a SERVERS <<< "${SERVERS:-${SERVERS_CFG[*]}}"
read -r -a SCENARIOS <<< "${SCENARIOS:-$(yq -r '.run.scenarios | join(" ")' bench.config.yaml)}"
REPS="${REPS:-$(cfg run.repetitions)}"
WARMUP_S="${WARMUP_S:-$(cfg run.warmup_s)}"
MEASURE_S="${MEASURE_S:-$(cfg run.measure_s)}"
COOLDOWN_S="${COOLDOWN_S:-$(cfg run.cooldown_s)}"
SNAP_DIR="dataset/snapshots"   # repo-relative; resolves on whichever host runs it

# --- execution routing -----------------------------------------------------
REMOTE="${REMOTE:-0}"
SSH_OPTS="${SSH_OPTS:-}"
# Run a command string in the repo root on the SUT (remote) or here (local).
# Commands use repo-relative paths so the same string works in both modes.
sut_run() {
  if [[ "$REMOTE" == "1" ]]; then ssh $SSH_OPTS "$SUT_SSH" "cd '$SUT_REPO' && $1"
  else ( cd "$ROOT" && eval "$1" ); fi
}
# LOADGEN_LOCAL=1 means THIS host IS the loadgen (detached mode: the controller runs
# on the loadgen VM in tmux, so generate/seed/k6 are local and only the SUT leg ssh's).
loadgen_run() {
  if [[ "$REMOTE" == "1" && "${LOADGEN_LOCAL:-0}" != "1" ]]; then ssh $SSH_OPTS "$LOADGEN_SSH" "cd '$LOADGEN_REPO' && $1"
  else ( cd "$ROOT" && eval "$1" ); fi
}
# Pull a results subtree produced on the loadgen back to the operator. No-op when the
# loadgen is local (operator-on-loadgen / local dev): results are already here.
pull_results() { # <repo-relative-path>
  [[ "$REMOTE" == "1" && "${LOADGEN_LOCAL:-0}" != "1" ]] || return 0
  mkdir -p "$ROOT/$(dirname "$1")"
  scp $SSH_OPTS -q -r "$LOADGEN_SSH:$LOADGEN_REPO/$1" "$ROOT/$(dirname "$1")/" \
    || echo "WARN: could not pull $1 (continuing)" >&2
}

# --- per-server helpers ----------------------------------------------------
profile_dir() { echo "servers/$1"; }
server_engine() { yq -r '.engine' "$ROOT/servers/$1/manifest.yaml"; }
snapshot_path() { echo "$SNAP_DIR/$1-$SIZE.dump"; }

# SUT-side URLs are always localhost (these steps run ON the SUT).
sut_local_base() { echo "http://localhost:$(cfg "servers.$1.port")$(cfg "servers.$1.base_path")"; }
sut_local_health() { echo "http://localhost:$(cfg "servers.$1.port")$(cfg "servers.$1.health_path")"; }
# The k6 load target: SUT private IP in remote mode, localhost locally.
k6_target_base() {
  local host="localhost"; [[ "$REMOTE" == "1" ]] && host="$SUT_PRIVATE_HOST"
  echo "http://${host}:$(cfg "servers.$1.port")$(cfg "servers.$1.base_path")"
}

# Build the engine's DB-connection env PREFIX string (evaluated where the dataset
# script runs — i.e. on the SUT, so the DB is always localhost). Snapshot/restore
# for every engine run SUT-side, so docker-based engines (rocksdb/mssql) work too.
db_env_prefix() {
  local server="$1" engine mf; engine="$(server_engine "$server")"; mf="$ROOT/servers/$server/manifest.yaml"
  case "$engine" in
    postgres)
      printf 'PGHOST=localhost PGPORT=%s PGUSER=%s PGPASSWORD=%s PGDATABASE=%s ' \
        "$(cfg "servers.$server.db_port")" \
        "$(yq -r '.dataset.pg.user' "$mf")" "$(yq -r '.dataset.pg.password' "$mf")" \
        "$(yq -r '.dataset.pg.database' "$mf")" ;;
    rocksdb)
      printf 'BLAZE_VOLUME=%s BLAZE_CONTAINER=%s ' \
        "$(yq -r '.dataset.volume' "$mf")" "$(yq -r '.dataset.container' "$mf")" ;;
    mssql)
      printf 'MSSQL_HOST=localhost MSSQL_PORT=%s MSSQL_SA_PASSWORD=%s MSSQL_DATABASE=%s MSSQL_CONTAINER=%s MSSQL_BACKUP_DIR=%s ' \
        "$(cfg "servers.$server.db_port")" "$(yq -r '.dataset.mssql.sa_password' "$mf")" \
        "$(yq -r '.dataset.mssql.database' "$mf")" "bench-${server}-sql-1" "servers/${server}/backup" ;;
    *) echo "ERROR: engine '$engine' not supported" >&2; exit 1 ;;
  esac
}

start_server() {
  local server="$1"
  [[ "${SKIP_BUILD:-0}" == "1" ]] || sut_run "servers/$server/build.sh"
  sut_run "servers/$server/up.sh"
}
stop_server() {
  [[ "${KEEP_UP:-0}" == "1" ]] && { log "KEEP_UP=1 — leaving $1 running"; return; }
  sut_run "servers/$1/down.sh -v"
}

# Wait (on the SUT) for the server to be ready — needed after a rocksdb restart;
# a no-op once the server is already up.
sut_wait_ready() {
  local url; url="$(sut_local_health "$1")"
  sut_run "deadline=\$((SECONDS+300)); until curl -fsS -o /dev/null '$url'; do (( SECONDS>=deadline )) && { echo 'not ready'>&2; exit 1; }; sleep 3; done"
}

# --- phases ----------------------------------------------------------------
phase_seed() {
  local server="$1" engine snap; engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"
  if sut_run "[ -f '$snap' ]" 2>/dev/null; then log "seed: snapshot exists ($snap) — skipping"; return; fi

  log "seed: $server — generate+load (loadgen) -> snapshot (SUT)"
  # Seeding requires a CLEAN DB: the dataset uses a fixed seed, so resource IDs are
  # deterministic — re-seeding onto leftover data from a prior/interrupted run
  # collides and 500s. Wipe the server + its volume first (no-op if not present).
  sut_run "servers/$server/down.sh -v" >/dev/null 2>&1 || true
  # generate + seed run on the loadgen (JDK + dataset live there); seed POSTs to the
  # SUT's API over the private network. build/up + snapshot run on the SUT.
  # SIZE=$SIZE is embedded so a SIZE override reaches the VM (it re-derives from its
  # own config copy otherwise). snapshot/restore take an explicit path, so they don't.
  loadgen_run "[ -d dataset/output/$SIZE/fhir ] || SIZE=$SIZE dataset/generate.sh"
  start_server "$server"
  loadgen_run "SIZE=$SIZE dataset/seed.sh '$(k6_target_base "$server")'"
  sut_run "mkdir -p '$SNAP_DIR' && $(db_env_prefix "$server")dataset/snapshot_${engine}.sh '$snap'"
}

# One measured repetition: reset state (SUT) -> warm up (loadgen, discard) ->
# measure (loadgen, capture) -> pull results -> cooldown.
run_rep() {
  local server="$1" scenario="$2" rep="$3" engine snap outdir target
  engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"
  outdir="results/$server/$scenario/rep-$rep"; target="$(k6_target_base "$server")"
  log "  rep $rep: restore -> warm-up ${WARMUP_S}s (discard) -> measure ${MEASURE_S}s (capture)"
  sut_run "$(db_env_prefix "$server")dataset/restore_${engine}.sh '$snap' >/dev/null"
  sut_wait_ready "$server"
  loadgen_run "CAPTURE=0 scenarios/run.sh '$scenario' '$target' '${WARMUP_S}s'" || true
  # saturation is DESIGNED to abort at the latency breakpoint (k6 exits non-zero) —
  # that's its successful outcome, not a failure. Tolerate it; fail other scenarios.
  if ! loadgen_run "CAPTURE=1 OUTDIR='$outdir' scenarios/run.sh '$scenario' '$target' '${MEASURE_S}s'"; then
    if [[ "$scenario" == "saturation" ]]; then
      log "  saturation reached its latency breakpoint and stopped (expected)"
    else
      echo "ERROR: $scenario measurement failed" >&2; return 1
    fi
  fi
  # Pull ONLY the small summary.json to the operator (that's all report.py needs).
  # The raw per-point metrics.json can be GBs (saturation/high throughput) and stays
  # on the loadgen VM — archived to Blob if configured, discarded on teardown.
  # PULL_RAW=1 to also fetch it (rarely wanted; large).
  pull_results "$outdir/summary.json"
  [[ "${PULL_RAW:-0}" == "1" ]] && pull_results "$outdir/metrics.json" || true
  [[ "$COOLDOWN_S" -gt 0 ]] && sleep "$COOLDOWN_S" || true
}

write_manifest() {
  local server="$1" out="$ROOT/results/$server/run-manifest.json"
  local sha; sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  # dataset lives on the loadgen (where it was generated), so hash there.
  local hash; hash="$(loadgen_run "SIZE=$SIZE dataset/hash.sh 2>/dev/null | awk 'NR==1{print \$1}'" 2>/dev/null || true)"; hash="${hash:-unknown}"
  local k6ver nproc
  k6ver="$(loadgen_run 'k6 version 2>/dev/null | head -1' 2>/dev/null || echo unknown)"
  nproc="$(sut_run 'getconf _NPROCESSORS_ONLN 2>/dev/null' 2>/dev/null || echo '?')"
  # Effective p99 SLO per scenario (per_scenario override, else default) — so the
  # report is self-contained and can mark each scenario against its own bar.
  local slo_map="" s p
  for s in "${SCENARIOS[@]}"; do
    p="$(cfg "slo.per_scenario.\"$s\".p99_ms" 2>/dev/null || cfg slo.p99_ms)"
    slo_map+="\"$s\": $p, "
  done
  slo_map="${slo_map%, }"
  mkdir -p "$(dirname "$out")"
  {
    echo '{'
    echo "  \"server\": \"$server\","
    echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"mode\": \"$([ "$REMOTE" = 1 ] && echo azure-multi-host || echo local)\","
    echo "  \"bench_repo_sha\": \"$sha\","
    echo "  \"k6_version\": \"$k6ver\","
    echo "  \"host\": { \"sut_nproc\": \"$nproc\" },"
    echo "  \"pin\": { \"repo\": \"$(cfg "servers.$server.repo" 2>/dev/null || echo n/a)\", \"ref\": \"$(cfg "servers.$server.ref" 2>/dev/null || echo n/a)\", \"commit\": \"$(cfg "servers.$server.commit" 2>/dev/null || echo n/a)\" },"
    echo "  \"limits\": { \"sut_cpus\": $(cfg limits.sut_cpus), \"sut_mem\": \"$(cfg limits.sut_mem)\", \"db_cpus\": $(cfg limits.db_cpus), \"db_mem\": \"$(cfg limits.db_mem)\" },"
    echo "  \"dataset\": { \"size\": \"$SIZE\", \"hash\": \"$hash\" },"
    echo "  \"slo\": { \"p99_ms\": $(cfg slo.p99_ms), \"max_error_rate\": $(cfg slo.max_error_rate), \"p99_ms_by_scenario\": { $slo_map } },"
    echo "  \"run\": { \"repetitions\": $REPS, \"warmup_s\": $WARMUP_S, \"measure_s\": $MEASURE_S, \"cooldown_s\": $COOLDOWN_S },"
    echo "  \"saturation_ramp\": { \"start_rate\": ${START_RATE:-$(cfg workload.saturation.start_rate)}, \"step_rate\": ${STEP_RATE:-$(cfg workload.saturation.step_rate)}, \"step_duration\": \"${STEP_DURATION:-$(cfg workload.saturation.step_duration)}\", \"max_rate\": ${MAX_RATE:-$(cfg workload.saturation.max_rate)}, \"abort_delay_s\": 10 },"
    echo "  \"scenarios\": [$(printf '"%s",' "${SCENARIOS[@]}" | sed 's/,$//')]"
    echo '}'
  } > "$out"
  log "wrote manifest: $out"
}

phase_run() {
  local server="$1" snap; snap="$(snapshot_path "$server")"
  sut_run "[ -f '$snap' ]" 2>/dev/null || { echo "ERROR: no snapshot for $server ($snap) — run the seed phase first" >&2; exit 1; }
  start_server "$server"
  for scenario in "${SCENARIOS[@]}"; do
    log "$server / $scenario — $REPS rep(s)"
    for rep in $(seq 1 "$REPS"); do run_rep "$server" "$scenario" "$rep"; done
  done
  write_manifest "$server"
  stop_server "$server"
}

# --- main ------------------------------------------------------------------
log "command=$CMD  mode=$([ "$REMOTE" = 1 ] && echo remote || echo local)  servers=[${SERVERS[*]}]  scenarios=[${SCENARIOS[*]}]  size=$SIZE  reps=$REPS"
for server in "${SERVERS[@]}"; do
  case "$CMD" in
    seed) phase_seed "$server"; stop_server "$server" ;;
    run)  phase_run "$server" ;;
    all)  phase_seed "$server"; SKIP_BUILD=1 phase_run "$server" ;;  # seed already built it
    *) echo "usage: orchestrate.sh <seed|run|all>" >&2; exit 1 ;;
  esac
done
log "done."
