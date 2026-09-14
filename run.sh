#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Kifas E2E Gate — trigger a Kifas run and block until terminal status.
# Exit 0 = gate pass (conclusion: success), Exit 1 = gate fail.
#
# Posts the run link + status to GitHub twice: once when the run starts and
# once when it finishes (a sticky PR comment + the Actions step summary). The
# failing case includes a short report. PR comments require KIFAS_GITHUB_TOKEN
# and `permissions: pull-requests: write`; without a token the gate still works,
# it just skips the comment.
#
# Required env:
#   KIFAS_API_KEY      — Bearer token
#   KIFAS_API_BASE     — base URL (default: https://api.kifas.io)
#
# Optional env:
#   KIFAS_TARGET_URL   — preview URL to test
#   KIFAS_APP_ARTIFACT — local path to a built app artifact (e.g. an APK) to
#                        upload and gate this PR on. Uploaded to Kifas before
#                        the trigger — a GitHub Actions artifact has no
#                        publicly fetchable URL, so the file itself is sent.
#   KIFAS_ENVIRONMENT  — environment label
#   KIFAS_SUITE        — suite to run (slug, project/slug, or id). Default: the
#                        project's "All workflows" suite.
#   KIFAS_PARAMS       — suite parameters, one key=value per line
#   KIFAS_GITHUB_TOKEN — token to post the PR comment (default: none → skip)
#
# Tunable env (with sane defaults):
#   KIFAS_POLL_INTERVAL_S   — seconds between polls (default: 5)
#   KIFAS_TIMEOUT_S         — max seconds to wait (default: 1200 = 20 min)
#   KIFAS_UPLOAD_TIMEOUT_S  — max seconds for the artifact upload (default: 300)
#   KIFAS_CURL              — curl binary override for testing (default: curl)
# ---------------------------------------------------------------------------

: "${KIFAS_API_KEY:?KIFAS_API_KEY is required}"
: "${KIFAS_API_BASE:=https://api.kifas.io}"
: "${KIFAS_TARGET_URL:=}"
: "${KIFAS_APP_ARTIFACT:=}"
: "${KIFAS_ENVIRONMENT:=}"
: "${KIFAS_SUITE:=}"
: "${KIFAS_PARAMS:=}"
: "${KIFAS_GITHUB_TOKEN:=}"
: "${KIFAS_POLL_INTERVAL_S:=5}"
: "${KIFAS_TIMEOUT_S:=1200}"
: "${KIFAS_UPLOAD_TIMEOUT_S:=300}"
: "${KIFAS_CURL:=curl}"

GH_API="${GITHUB_API_URL:-https://api.github.com}"
COMMENT_MARKER="<!-- kifas-e2e-run -->"
KIFAS_RUN_URL=""

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

# ---------------------------------------------------------------------------
# GitHub reporting helpers (all best-effort; never fail the gate)
# ---------------------------------------------------------------------------
gh_comment_enabled() {
  [[ -n "${KIFAS_GITHUB_TOKEN}" && -n "${PR_NUMBER}" && -n "${REPO}" ]]
}

run_link() {
  if [[ -n "${KIFAS_RUN_URL}" ]]; then
    printf '[View run in Kifas](%s)' "${KIFAS_RUN_URL}"
  else
    printf 'Run ID: `%s`' "${KIFAS_RUN_ID:-unknown}"
  fi
}

# Create or update the single sticky PR comment (identified by COMMENT_MARKER).
upsert_pr_comment() {
  gh_comment_enabled || return 0
  local body="$1" payload existing_id
  payload="$(jq -n --arg b "${body}" '{body:$b}')"
  existing_id="$(
    "${KIFAS_CURL}" --silent --max-time 15 \
      -H "Authorization: Bearer ${KIFAS_GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GH_API}/repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
      | jq -r --arg m "${COMMENT_MARKER}" 'map(select((.body // "") | contains($m))) | (.[0].id // empty)' 2>/dev/null || true
  )"
  if [[ -n "${existing_id}" ]]; then
    "${KIFAS_CURL}" --silent --max-time 15 -X PATCH \
      -H "Authorization: Bearer ${KIFAS_GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "${payload}" \
      "${GH_API}/repos/${REPO}/issues/comments/${existing_id}" >/dev/null 2>&1 || true
  else
    "${KIFAS_CURL}" --silent --max-time 15 -X POST \
      -H "Authorization: Bearer ${KIFAS_GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "${payload}" \
      "${GH_API}/repos/${REPO}/issues/${PR_NUMBER}/comments" >/dev/null 2>&1 || true
  fi
}

write_step_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n\n' "$1" >> "${GITHUB_STEP_SUMMARY}" || true
  fi
}

# notify <markdown> — posts to the sticky PR comment (with marker) + step summary.
notify() {
  local md="$1"
  upsert_pr_comment "$(printf '%s\n%s' "${COMMENT_MARKER}" "${md}")"
  write_step_summary "${md}"
}

# ---------------------------------------------------------------------------
# Upload the app artifact, if any. A GitHub Actions artifact has no publicly
# fetchable URL, so the file is uploaded directly and the trigger below gets
# the resulting Kifas app_build id instead of the local path.
# ---------------------------------------------------------------------------
APP_BUILD_ID=""
if [[ -n "${KIFAS_APP_ARTIFACT}" ]]; then
  if [[ ! -f "${KIFAS_APP_ARTIFACT}" ]]; then
    echo "::error::app-artifact not found: ${KIFAS_APP_ARTIFACT}" >&2
    exit 1
  fi

  echo "::group::Kifas — upload app artifact"
  UPLOAD_RESPONSE="$(
    "${KIFAS_CURL}" \
      --silent \
      --show-error \
      --fail-with-body \
      --max-time "${KIFAS_UPLOAD_TIMEOUT_S}" \
      -X POST \
      -H "Authorization: Bearer ${KIFAS_API_KEY}" \
      -F "file=@${KIFAS_APP_ARTIFACT}" \
      "${KIFAS_API_BASE}/v1/app-builds/upload" \
    2>&1
  )" || {
    echo "::error::app-artifact upload failed:" >&2
    echo "${UPLOAD_RESPONSE}" >&2
    exit 1
  }
  APP_BUILD_ID="$(echo "${UPLOAD_RESPONSE}" | jq -r '.app_build_id // empty')"
  if [[ -z "${APP_BUILD_ID}" ]]; then
    echo "::error::app-artifact upload response missing app_build_id. Response: ${UPLOAD_RESPONSE}" >&2
    exit 1
  fi
  echo "Uploaded app artifact -> app_build_id: ${APP_BUILD_ID}"
  echo "::endgroup::"
fi

echo "::group::Kifas — trigger run"
echo "repo:        ${REPO}"
echo "commit_sha:  ${COMMIT_SHA}"
echo "branch:      ${BRANCH}"
echo "pr_number:   ${PR_NUMBER:-<none>}"
echo "run_id:      ${RUN_ID}"
echo "target_url:  ${KIFAS_TARGET_URL:-<none>}"
echo "suite:       ${KIFAS_SUITE:-<default suite>}"
echo "app_build:   ${APP_BUILD_ID:-<none>}"
echo "environment: ${KIFAS_ENVIRONMENT:-<none>}"
echo "api_base:    ${KIFAS_API_BASE}"

# ---------------------------------------------------------------------------
# Build trigger payload
# ---------------------------------------------------------------------------
# Suite params arrive as `key=value` lines; blank lines, comments and anything
# that isn't `name=value` are ignored. The value keeps its own `=` characters.
PARAMS_JSON="$(printf '%s' "${KIFAS_PARAMS}" | jq -R -s '
  split("\n")
  | map(capture("^\\s*(?<k>[A-Za-z_][A-Za-z0-9_]*)\\s*=(?<v>.*)$")?)
  | map({ (.k): (.v | sub("^\\s+"; "") | sub("\\s+$"; "")) })
  | add // {}
')"
echo "params:      $(echo "${PARAMS_JSON}" | jq -r 'keys | join(",")')"

PAYLOAD="$(jq -n \
  --arg target_url    "${KIFAS_TARGET_URL}" \
  --arg app_artifact  "${APP_BUILD_ID}" \
  --arg environment   "${KIFAS_ENVIRONMENT}" \
  --arg suite         "${KIFAS_SUITE}" \
  --argjson params    "${PARAMS_JSON}" \
  --arg repo          "${REPO}" \
  --arg commit_sha    "${COMMIT_SHA}" \
  --arg branch        "${BRANCH}" \
  --arg pr_number     "${PR_NUMBER}" \
  --arg run_id        "${RUN_ID}" \
  '{
    target_url:   (if $target_url   != "" then $target_url   else null end),
    app_artifact: (if $app_artifact != "" then $app_artifact else null end),
    environment:  (if $environment  != "" then $environment  else null end),
    params:       $params,
    context: {
      repo:       $repo,
      commit_sha: $commit_sha,
      branch:     $branch,
      pr_number:  (if $pr_number != "" then ($pr_number | tonumber) else null end),
      run_id:     (if $run_id    != "" then ($run_id    | tonumber) else null end)
    }
  }
  + (if $suite != "" then { suite: $suite } else {} end)'
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
    --data @- \
    "${KIFAS_API_BASE}/v1/github/runs" \
  2>&1 <<PAYLOAD_EOF
${PAYLOAD}
PAYLOAD_EOF
)" || {
  echo "::error::Kifas trigger request failed:" >&2
  echo "${TRIGGER_RESPONSE}" >&2
  exit 1
}

KIFAS_RUN_ID="$(echo "${TRIGGER_RESPONSE}" | jq -r '.run_id // empty')"
POLL_URL_RAW="$(echo "${TRIGGER_RESPONSE}" | jq -r '.poll_url // empty')"
KIFAS_RUN_URL="$(echo "${TRIGGER_RESPONSE}" | jq -r '.run_url // empty')"

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

# The machine status endpoint and the raw trigger JSON are debugging detail —
# they stay inside the collapsed group. Only the human-facing run link is
# promoted below it.
echo "kifas_run_id: ${KIFAS_RUN_ID}"
echo "status_api:   ${POLL_URL}"
echo "::endgroup::"

# The one line a human wants from this job: a clickable link to the run in
# Kifas, at top level (never inside a ::group::, which renders collapsed).
# ::notice:: additionally surfaces it in the run's Annotations panel, above
# the log. Falls back to the status API only if the dashboard link can't be
# resolved, so this slot is never empty.
if [[ -n "${KIFAS_RUN_URL}" ]]; then
  echo "Kifas run: ${KIFAS_RUN_URL}"
  echo "::notice title=Kifas E2E run::${KIFAS_RUN_URL}"
else
  echo "Kifas run: ${KIFAS_RUN_ID} (dashboard link unavailable; status API: ${POLL_URL})"
fi

# Report #1: run started.
notify "$(printf '### 🔄 Kifas E2E — run started\n\n**Status:** running\n\n%s\n\n<sub>commit `%s`</sub>' "$(run_link)" "${COMMIT_SHA:0:7}")"

# ---------------------------------------------------------------------------
# Poll until terminal status or timeout
# ---------------------------------------------------------------------------
START_TS="$(date +%s)"
LAST_STATUS=""

while true; do
  NOW_TS="$(date +%s)"
  ELAPSED=$(( NOW_TS - START_TS ))

  if (( ELAPSED >= KIFAS_TIMEOUT_S )); then
    notify "$(printf '### ⏱️ Kifas E2E — timed out\n\n**Result:** timed out after %ss\n\n%s' "${KIFAS_TIMEOUT_S}" "$(run_link)")"
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
    passed|completed|failed|aborted)
      # Prefer the run_url from the poll (authoritative); fall back to trigger's.
      RUN_URL_POLL="$(echo "${POLL_RESPONSE}" | jq -r '.run_url // empty')"
      if [[ -n "${RUN_URL_POLL}" ]]; then KIFAS_RUN_URL="${RUN_URL_POLL}"; fi
      REPORT="$(echo "${POLL_RESPONSE}" | jq -r '.report // empty')"

      COUNTS="$(echo "${POLL_RESPONSE}" | jq -r '
        if .counts then "\(.counts.passed) passed, \(.counts.failed) failed of \(.counts.total)" else empty end
      ')"

      echo ""
      echo "Kifas run finished — status=${STATUS} conclusion=${CONCLUSION}"
      if [[ -n "${REPORT}" ]]; then
        echo "${REPORT}"
      fi

      # The report is one line per workflow in the suite ("✅ name" / "❌ name — why").
      REPORT_BLOCK=""
      if [[ -n "${REPORT}" ]]; then
        REPORT_BLOCK="$(printf '\n\n%s' "$(echo "${REPORT}" | sed 's/^/- /')")"
      fi
      COUNTS_BLOCK=""
      if [[ -n "${COUNTS}" ]]; then
        COUNTS_BLOCK="$(printf '\n\n**Tests:** %s' "${COUNTS}")"
      fi

      if [[ "${CONCLUSION}" == "success" ]]; then
        notify "$(printf '### ✅ Kifas E2E — passed\n\n**Result:** success%s\n\n%s%s' "${COUNTS_BLOCK}" "$(run_link)" "${REPORT_BLOCK}")"
        echo "Gate PASSED."
        exit 0
      else
        notify "$(printf '### ❌ Kifas E2E — %s\n\n**Result:** %s%s\n\n%s%s' "${STATUS}" "${CONCLUSION}" "${COUNTS_BLOCK}" "$(run_link)" "${REPORT_BLOCK}")"
        echo "::error::Kifas gate FAILED — run_id=${KIFAS_RUN_ID} conclusion=${CONCLUSION}" >&2
        exit 1
      fi
      ;;
  esac

  sleep "${KIFAS_POLL_INTERVAL_S}"
done
