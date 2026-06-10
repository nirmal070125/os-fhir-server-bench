#!/usr/bin/env bash
# Post a run-finished notification to a webhook. No-op if BENCH_NOTIFY_URL is unset,
# so it's entirely opt-in. Default payload is Slack-style {"text":…} (also works for
# Discord, Mattermost, Google Chat); set BENCH_NOTIFY_KIND=teams for a Teams
# MessageCard. Reads run.exit in the CWD for pass/fail. curl + jq only; always exits 0
# (a failed notification must never fail the run).
#   env: BENCH_NOTIFY_URL [BENCH_NOTIFY_KIND] [BENCH_RUN_PREFIX] [BENCH_REPORT_URL] [BENCH_LOG_URL]
set -uo pipefail
url="${BENCH_NOTIFY_URL:-}"; [[ -n "$url" ]] || exit 0

status="$(cat run.exit 2>/dev/null || echo '?')"
prefix="${BENCH_RUN_PREFIX:-run}"
if [[ "$status" == "0" ]]; then
  msg="✅ FHIR benchmark *${prefix}* finished. Report: ${BENCH_REPORT_URL:-run \`make report\`}"
else
  msg="❌ FHIR benchmark *${prefix}* FAILED (exit ${status}). Log: ${BENCH_LOG_URL:-run \`make report\`}"
fi

if [[ "${BENCH_NOTIFY_KIND:-slack}" == "teams" ]]; then
  payload="$(jq -n --arg t "$msg" '{"@type":"MessageCard","@context":"http://schema.org/extensions","text":$t}')"
else
  payload="$(jq -n --arg t "$msg" '{text:$t}')"
fi

if curl -fsS -X POST -H 'Content-Type: application/json' --data "$payload" "$url" >/dev/null 2>&1; then
  echo "notify: sent (status=$status)"
else
  echo "notify: webhook POST failed (non-fatal)" >&2
fi
exit 0
