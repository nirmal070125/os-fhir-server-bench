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

# Offered-rate ladder (req/s) for a scenario (space-separated). RATE_LEVELS env (e.g.
# "50 200") overrides the config ladder for ALL scenarios — used by smoke/iteration.
rate_levels() { # <scenario>
  if [[ -n "${RATE_LEVELS:-}" ]]; then echo "$RATE_LEVELS"; return; fi
  yq -r ".workload.\"$1\".rate_levels | join(\" \")" "$ROOT/bench.config.yaml"
}

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

# Stop/start just the app container (service "server", same in every profile). The
# Postgres template-clone reset drops & recreates the working DB, so the app must hold
# no connections to it during the swap: reset_state stops the app first, then starts it
# after — which also gives pooled/cached servers (HAPI, Medplum, IBM) fresh connections
# + metadata against the restored data. The warm-up that follows absorbs the cold start.
stop_app() {  # <server> — stop just the app container (db keeps running)
  sut_run "cd servers/$1 && { [ -f .env ] && docker compose --env-file .env stop server || docker compose stop server; }"
}
start_app() { # <server>
  sut_run "cd servers/$1 && { [ -f .env ] && docker compose --env-file .env start server || docker compose start server; }"
}

# Wait (on the SUT) for the server to be ready — needed after a rocksdb restart;
# a no-op once the server is already up.
sut_wait_ready() {
  local url; url="$(sut_local_health "$1")"
  sut_run "deadline=\$((SECONDS+300)); until curl -fsS -o /dev/null '$url'; do (( SECONDS>=deadline )) && { echo 'not ready'>&2; exit 1; }; sleep 3; done"
}

# --- phases ----------------------------------------------------------------
phase_seed() {
  local server="$1" engine snap commit skey dkey csas
  engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"
  csas="${BENCH_CACHE_SAS:-}"
  # Cache keys: the snapshot depends on the server BUILD (commit) + dataset (size); the
  # dataset depends only on the size name (= its deterministic identity, by convention —
  # change the size name if you change generation params). See dataset/blobcache.sh.
  commit="$(cfg "servers.$server.commit" 2>/dev/null | cut -c1-12)"; commit="${commit:-nocommit}"
  skey="snapshots/${server}-${SIZE}-${commit}.dump"
  dkey="datasets/${SIZE}.tar.gz"

  if sut_run "[ -f '$snap' ]" 2>/dev/null; then log "seed: snapshot exists ($snap) — skipping"; return; fi

  # (1) Snapshot cached in Blob? Build the server image (measurement needs it) then pull
  # the snapshot and SKIP generate + the ~hour-long seed entirely. Verify it landed
  # non-empty; on any failure, fall through to a full seed.
  if [[ -n "$csas" ]] && sut_run "BENCH_CACHE_SAS='$csas' dataset/blobcache.sh exists '$skey'" 2>/dev/null; then
    log "seed: reusing cached snapshot from Blob ($skey) — building server, skipping seed"
    [[ "${SKIP_BUILD:-0}" == "1" ]] || sut_run "servers/$server/build.sh"
    if sut_run "mkdir -p '$SNAP_DIR' && BENCH_CACHE_SAS='$csas' dataset/blobcache.sh get '$skey' '$snap' && [ -s '$snap' ]"; then
      log "seed: cached snapshot restored to $snap — seed phase skipped"; return
    fi
    log "seed: cached-snapshot pull failed — falling back to full seed"
  fi

  log "seed: $server — generate+load (loadgen) -> snapshot (SUT)"
  # Seeding requires a CLEAN DB: the dataset uses a fixed seed, so resource IDs are
  # deterministic — re-seeding onto leftover data from a prior/interrupted run
  # collides and 500s. Wipe the server + its volume first (no-op if not present).
  sut_run "servers/$server/down.sh -v" >/dev/null 2>&1 || true
  # (2) Dataset cached in Blob? Pull + extract on the loadgen (skips ~min of generation);
  # else generate and upload it for next time. generate + seed run on the loadgen (JDK +
  # dataset live there); seed POSTs to the SUT's API over the private network.
  if [[ -n "$csas" ]] && loadgen_run "BENCH_CACHE_SAS='$csas' dataset/blobcache.sh exists '$dkey'" 2>/dev/null; then
    log "seed: reusing cached dataset from Blob ($dkey)"
    loadgen_run "mkdir -p dataset/output/$SIZE && BENCH_CACHE_SAS='$csas' dataset/blobcache.sh get '$dkey' /tmp/bench-ds.tgz && tar xzf /tmp/bench-ds.tgz -C dataset/output/$SIZE && rm -f /tmp/bench-ds.tgz"
  else
    loadgen_run "[ -d dataset/output/$SIZE/fhir ] || SIZE=$SIZE dataset/generate.sh"
    [[ -n "$csas" ]] && loadgen_run "tar czf /tmp/bench-ds.tgz -C dataset/output/$SIZE fhir && BENCH_CACHE_SAS='$csas' dataset/blobcache.sh put /tmp/bench-ds.tgz '$dkey'; rm -f /tmp/bench-ds.tgz" || true
  fi
  start_server "$server"
  # Seed-only durability relaxation: fsync-per-commit on large bundles makes the load
  # disk-bound (a ~24h seed on Azure Premium). synchronous_commit=off removes the wait;
  # reset to default (on) right after, BEFORE the snapshot, so a snapshot always implies
  # normal durability — measured runs restore from it and are unaffected. (postgres only.)
  [[ "$engine" == "postgres" ]] && sut_run "$(db_env_prefix "$server")dataset/seed_tune_postgres.sh off"
  loadgen_run "SIZE=$SIZE dataset/seed.sh '$(k6_target_base "$server")'"
  [[ "$engine" == "postgres" ]] && sut_run "$(db_env_prefix "$server")dataset/seed_tune_postgres.sh on"
  sut_run "mkdir -p '$SNAP_DIR' && $(db_env_prefix "$server")dataset/snapshot_${engine}.sh '$snap'"
  # (3) Cache the freshly-built snapshot so future runs skip this entire phase.
  [[ -n "$csas" ]] && sut_run "BENCH_CACHE_SAS='$csas' dataset/blobcache.sh put '$snap' '$skey'" || true
}

# Restore the frozen snapshot to identical starting state, then gate on readiness.
# postgres restore swaps the schema under a live server -> restart so pooled/cached
# servers (HAPI, Medplum, IBM) see the restored data. (rocksdb/mssql restore handle
# their own container lifecycle.)
reset_state() { # <server>
  local server="$1" engine snap; engine="$(server_engine "$server")"; snap="$(snapshot_path "$server")"
  if [[ "$engine" == "postgres" ]]; then
    # The template-clone reset drops & recreates the working DB, so the app must hold
    # no connections to it — stop the app first, swap the DB, then start it back up.
    stop_app "$server"
    sut_run "$(db_env_prefix "$server")dataset/restore_${engine}.sh '$snap' >/dev/null"
    start_app "$server"
  else
    sut_run "$(db_env_prefix "$server")dataset/restore_${engine}.sh '$snap' >/dev/null"
  fi
  sut_wait_ready "$server"
}

# Measure ONE offered-rate level (capture) -> pull results -> cooldown. k6 exit 99
# (SLO not met at this rate, expected at the high end) is tolerated by run.sh; a real
# failure here is operational and aborts the rep.
measure_level() { # <server> <scenario> <rep> <rate> <target>
  local server="$1" scenario="$2" rep="$3" rate="$4" target="$5" outdir
  outdir="results/$server/$scenario/rep-$rep/rate-$rate"
  log "    rate=$rate/s: measure ${MEASURE_S}s (capture)"
  if ! loadgen_run "RATE=$rate CAPTURE=1 OUTDIR='$outdir' scenarios/run.sh '$scenario' '$target' '${MEASURE_S}s'"; then
    echo "ERROR: $scenario @ rate=$rate failed" >&2; return 1
  fi
  # Pull ONLY the small summary.json to the operator (that's all report.py needs).
  # The raw per-point metrics.json can be large (high rate) and stays on the loadgen
  # VM. PULL_RAW=1 to also fetch it (rarely wanted; large).
  pull_results "$outdir/summary.json"
  [[ "${PULL_RAW:-0}" == "1" ]] && pull_results "$outdir/metrics.json" || true
  [[ "$COOLDOWN_S" -gt 0 ]] && sleep "$COOLDOWN_S" || true
}

# One repetition = sweep the offered-rate ladder. Reads are read-only, so one restore
# + one warm-up serves the whole ladder; writes mutate state, so we restore (clean
# baseline) + warm before EVERY level. Warm-up (discarded) at a level's own offered
# rate warms JIT/cache/pools; reads warm at the top of the ladder (max stress).
run_sweep() {
  local server="$1" scenario="$2" rep="$3" target levels rate
  target="$(k6_target_base "$server")"
  read -r -a levels <<< "$(rate_levels "$scenario")"
  if [[ "$scenario" == "ingest" ]]; then
    for rate in "${levels[@]}"; do
      log "  rep $rep rate=$rate/s: restore -> warm-up ${WARMUP_S}s (discard) -> measure ${MEASURE_S}s"
      reset_state "$server"
      loadgen_run "RATE=$rate CAPTURE=0 scenarios/run.sh '$scenario' '$target' '${WARMUP_S}s'" || true
      measure_level "$server" "$scenario" "$rep" "$rate" "$target" || return 1
    done
  else
    # read-only: state can't change across reps, so restore + warm-up ONCE (on rep 1)
    # and reuse the warmed baseline for every rep — no point paying a reset per rep.
    if [[ "$rep" == "1" ]]; then
      log "  rep $rep: restore -> warm-up ${WARMUP_S}s (discard) -> sweep offered rate [${levels[*]}]/s"
      reset_state "$server"
      loadgen_run "RATE=${levels[$(( ${#levels[@]} - 1 ))]} CAPTURE=0 scenarios/run.sh '$scenario' '$target' '${WARMUP_S}s'" || true
    else
      log "  rep $rep: reuse warmed read-only baseline -> sweep offered rate [${levels[*]}]/s"
    fi
    for rate in "${levels[@]}"; do
      measure_level "$server" "$scenario" "$rep" "$rate" "$target" || return 1
    done
  fi
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
  local slo_map="" rate_map="" s p lv
  for s in "${SCENARIOS[@]}"; do
    p="$(cfg "slo.per_scenario.\"$s\".p99_ms" 2>/dev/null || cfg slo.p99_ms)"
    slo_map+="\"$s\": $p, "
    lv="$(rate_levels "$s")"
    rate_map+="\"$s\": [$(echo "$lv" | tr ' ' ',')], "
  done
  slo_map="${slo_map%, }"; rate_map="${rate_map%, }"
  # Seed outcome (bundles loaded vs failed) — written by seed.sh on the loadgen; fold it
  # into the dataset object so the report records exactly how complete the dataset is.
  local seed_json seed_fields=""
  seed_json="$(loadgen_run "cat dataset/output/$SIZE/seed-summary.json 2>/dev/null" 2>/dev/null || true)"
  seed_json="$(echo "$seed_json" | tr -d '\r\n' | grep -o '{.*}' || true)"
  if [[ -n "$seed_json" ]]; then seed_fields=", ${seed_json#\{}"; seed_fields="${seed_fields%\}}"; fi
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
    echo "  \"dataset\": { \"size\": \"$SIZE\", \"hash\": \"$hash\"${seed_fields} },"
    echo "  \"slo\": { \"p99_ms\": $(cfg slo.p99_ms), \"max_error_rate\": $(cfg slo.max_error_rate), \"p99_ms_by_scenario\": { $slo_map } },"
    echo "  \"run\": { \"repetitions\": $REPS, \"warmup_s\": $WARMUP_S, \"measure_s\": $MEASURE_S, \"cooldown_s\": $COOLDOWN_S },"
    echo "  \"load_model\": \"open (constant-arrival-rate sweep)\","
    echo "  \"rate_levels\": { $rate_map },"
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
    log "$server / $scenario — $REPS rep(s) × offered rate [$(rate_levels "$scenario")]/s"
    for rep in $(seq 1 "$REPS"); do run_sweep "$server" "$scenario" "$rep"; done
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
