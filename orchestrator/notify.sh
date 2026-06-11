#!/usr/bin/env bash
# Post a run-finished notification to a webhook. No-op if BENCH_NOTIFY_URL is unset,
# so it's entirely opt-in. Reads run.exit in the CWD for pass/fail. curl (+ jq for the
# JSON kinds) only; ALWAYS exits 0 (a failed notification must never fail the run).
#
# BENCH_NOTIFY_KIND picks the payload format:
#   ntfy   - ntfy.sh push (NO account needed; easiest). URL = https://ntfy.sh/<your-topic>.
#            Sends plain text + a Title/Tags/Click header so tapping opens the report.
#   slack  - {"text":…}  (default; also works for Discord, Mattermost, Google Chat)
#   teams  - Microsoft Teams MessageCard
#   env: BENCH_NOTIFY_URL [BENCH_NOTIFY_KIND] [BENCH_RUN_PREFIX] [BENCH_REPORT_URL] [BENCH_LOG_URL]
set -uo pipefail
url="${BENCH_NOTIFY_URL:-}"; [[ -n "$url" ]] || exit 0

status="$(cat run.exit 2>/dev/null || echo '?')"
prefix="${BENCH_RUN_PREFIX:-run}"
kind="${BENCH_NOTIFY_KIND:-slack}"

if [[ "$status" == "0" ]]; then
  state="finished"; tag="white_check_mark"; emoji="✅"; link="${BENCH_REPORT_URL:-}"
  msg="✅ FHIR benchmark *${prefix}* finished. Report: ${BENCH_REPORT_URL:-run \`make report\`}"
else
  state="FAILED (exit ${status})"; tag="x"; emoji="❌"; link="${BENCH_LOG_URL:-}"
  msg="❌ FHIR benchmark *${prefix}* FAILED (exit ${status}). Log: ${BENCH_LOG_URL:-run \`make report\`}"
fi

send() { # builds the request per kind; returns curl's status
  case "$kind" in
    ntfy)
      # ntfy.sh: plain-text body + headers. Click makes the notification open the link.
      local args=(-H "Title: FHIR benchmark ${prefix} — ${state}" -H "Tags: ${tag}")
      [[ -n "$link" ]] && args+=(-H "Click: ${link}")
      curl -fsS "${args[@]}" -d "${emoji} ${state}${link:+ — open for the report}" "$url" >/dev/null 2>&1
      ;;
    teams)
      curl -fsS -X POST -H 'Content-Type: application/json' \
        --data "$(jq -n --arg t "$msg" '{"@type":"MessageCard","@context":"http://schema.org/extensions","text":$t}')" \
        "$url" >/dev/null 2>&1
      ;;
    *) # slack / discord / mattermost / google chat
      curl -fsS -X POST -H 'Content-Type: application/json' \
        --data "$(jq -n --arg t "$msg" '{text:$t}')" "$url" >/dev/null 2>&1
      ;;
  esac
}

if send; then
  echo "notify: sent (kind=$kind status=$status)"
else
  echo "notify: webhook POST failed (non-fatal)" >&2
fi
exit 0
