#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Kifas E2E Gate — trigger a Kifas run and block until terminal status.
# Exit 0 = gate pass (conclusion: success), Exit 1 = gate fail.
#
# Required env:
#   KIFAS_API_KEY      — Bearer token
#   KIFAS_API_BASE     — base URL (default: https://api.kifas.io)
#
# Optional env:
#   KIFAS_TARGET_URL   — preview URL to test
#   KIFAS_APP_ARTIFACT — artifact name/path
#   KIFAS_ENVIRONMENT  — environment label
#
# Tunable env (with sane defaults):
#   KIFAS_POLL_INTERVAL_S  — seconds between polls (default: 5)
#   KIFAS_TIMEOUT_S        — max seconds to wait (default: 1200 = 20 min)
#   KIFAS_CURL             — curl binary override for testing (default: curl)
# ---------------------------------------------------------------------------

: "${KIFAS_API_KEY:?KIFAS_API_KEY is required}"
: "${KIFAS_API_BASE:=https://api.kifas.io}"
: "${KIFAS_TARGET_URL:=}"
: "${KIFAS_APP_ARTIFACT:=}"
: "${KIFAS_ENVIRONMENT:=}"
: "${KIFAS_POLL_INTERVAL_S:=5}"
: "${KIFAS_TIMEOUT_S:=1200}"
: "${KIFAS_CURL:=curl}"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo "::error::jq is required but not found. ubuntu-latest runners include jq; install it if using a custom runner." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Collect GitHub run context
# ---------------------------------------------------------------------------
REPO="${GITHUB_REPOSITORY:-}"
COMMIT_SHA="${GITHUB_SHA:-}"
BRANCH="${GITHUB_REF_NAME:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

# Resolve PR number: first try GITHUB_REF (refs/pull/123/merge), then event payload.
PR_NUMBER=""
if [[ "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/ ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
elif [[ -f "${GITHUB_EVENT_PATH:-}" ]]; then
  PR_NUMBER="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || true)"
fi

echo "::group::Kifas — trigger run"
echo "repo:        ${REPO}"
echo "commit_sha:  ${COMMIT_SHA}"
echo "branch:      ${BRANCH}"
echo "pr_number:   ${PR_NUMBER:-<none>}"
echo "run_id:      ${RUN_ID}"
echo "target_url:  ${KIFAS_TARGET_URL:-<none>}"
echo "environment: ${KIFAS_ENVIRONMENT:-<none>}"
echo "api_base:    ${KIFAS_API_BASE}"

# ---------------------------------------------------------------------------
# Build trigger payload
# ---------------------------------------------------------------------------
PAYLOAD="$(jq -n \
  --arg target_url    "${KIFAS_TARGET_URL}" \
  --arg app_artifact  "${KIFAS_APP_ARTIFACT}" \
  --arg environment   "${KIFAS_ENVIRONMENT}" \
  --arg repo          "${REPO}" \
  --arg commit_sha    "${COMMIT_SHA}" \
  --arg branch        "${BRANCH}" \
  --arg pr_number     "${PR_NUMBER}" \
  --arg run_id        "${RUN_ID}" \
  '{
    target_url:   (if $target_url   != "" then $target_url   else null end),
    app_artifact: (if $app_artifact != "" then $app_artifact else null end),
    environment:  (if $environment  != "" then $environment  else null end),
    context: {
      repo:       $repo,
      commit_sha: $commit_sha,
      branch:     $branch,
      pr_number:  (if $pr_number != "" then ($pr_number | tonumber) else null end),
      run_id:     (if $run_id    != "" then ($run_id    | tonumber) else null end)
    }
  }'
)"

# ---------------------------------------------------------------------------
# POST /v1/github/runs
# ---------------------------------------------------------------------------
TRIGGER_RESPONSE="$(
  "${KIFAS_CURL}" \
    --silent \
    --show-error \
    --fail-with-body \
    --max-time 30 \
    -X POST \
    -H "Authorization: Bearer ${KIFAS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "${KIFAS_API_BASE}/v1/github/runs" \
  2>&1
)" || {
  echo "::error::Kifas trigger request failed:" >&2
  echo "${TRIGGER_RESPONSE}" >&2
  exit 1
}

echo "Trigger response: ${TRIGGER_RESPONSE}"
echo "::endgroup::"

KIFAS_RUN_ID="$(echo "${TRIGGER_RESPONSE}" | jq -r '.run_id // empty')"
POLL_URL_RAW="$(echo "${TRIGGER_RESPONSE}" | jq -r '.poll_url // empty')"

if [[ -z "${KIFAS_RUN_ID}" ]]; then
  echo "::error::Trigger response missing run_id. Response: ${TRIGGER_RESPONSE}" >&2
  exit 1
fi
if [[ -z "${POLL_URL_RAW}" ]]; then
  echo "::error::Trigger response missing poll_url. Response: ${TRIGGER_RESPONSE}" >&2
  exit 1
fi

# Resolve poll_url: if it starts with http, use as-is; otherwise prepend api-base.
if [[ "${POLL_URL_RAW}" == http* ]]; then
  POLL_URL="${POLL_URL_RAW}"
else
  POLL_URL="${KIFAS_API_BASE%/}/${POLL_URL_RAW#/}"
fi

echo "Kifas run started: ${KIFAS_RUN_ID}"
echo "Polling: ${POLL_URL}"

# ---------------------------------------------------------------------------
# Poll until terminal status or timeout
# ---------------------------------------------------------------------------
START_TS="$(date +%s)"
LAST_STATUS=""

while true; do
  NOW_TS="$(date +%s)"
  ELAPSED=$(( NOW_TS - START_TS ))

  if (( ELAPSED >= KIFAS_TIMEOUT_S )); then
    echo "::error::Kifas run timed out after ${KIFAS_TIMEOUT_S}s (run_id=${KIFAS_RUN_ID})" >&2
    exit 1
  fi

  POLL_RESPONSE="$(
    "${KIFAS_CURL}" \
      --silent \
      --show-error \
      --fail-with-body \
      --max-time 15 \
      -H "Authorization: Bearer ${KIFAS_API_KEY}" \
      "${POLL_URL}" \
    2>&1
  )" || {
    echo "::warning::Poll request failed (will retry): ${POLL_RESPONSE}"
    sleep "${KIFAS_POLL_INTERVAL_S}"
    continue
  }

  STATUS="$(echo "${POLL_RESPONSE}"     | jq -r '.status     // empty')"
  CONCLUSION="$(echo "${POLL_RESPONSE}" | jq -r '.conclusion // empty')"

  if [[ "${STATUS}" != "${LAST_STATUS}" ]]; then
    echo "[+${ELAPSED}s] status=${STATUS} conclusion=${CONCLUSION:-<pending>}"
    LAST_STATUS="${STATUS}"
  fi

  case "${STATUS}" in
    completed|failed|aborted)
      echo ""
      echo "Kifas run finished — status=${STATUS} conclusion=${CONCLUSION}"
      if [[ "${CONCLUSION}" == "success" ]]; then
        echo "Gate PASSED."
        exit 0
      else
        echo "::error::Kifas gate FAILED — run_id=${KIFAS_RUN_ID} conclusion=${CONCLUSION}" >&2
        exit 1
      fi
      ;;
  esac

  sleep "${KIFAS_POLL_INTERVAL_S}"
done
