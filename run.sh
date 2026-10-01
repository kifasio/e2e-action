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
#   KIFAS_GATE_ID      — the GitHub checks setup ID. Required with a key a gate setup
#                        issued: every call to Kifas then carries a fresh GitHub
#                        Actions OIDC token (audience kifas-github-gate), which
#                        needs `permissions: id-token: write` on this job.
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
#   KIFAS_TRIGGER_ATTEMPTS  — gate calls retried after a lost or 5xx answer (default: 3)
#   KIFAS_RETRY_DELAY_S     — seconds between those retries (default: 5)
#   KIFAS_OUTCOME_WAIT_MINUTES — after the tests finish, how long to wait for
#                               Kifas's final outcome (default: 10)
#   KIFAS_WAIT_FOR_RESULT     — "false" ends the job right after dispatch when
#                               Kifas posts the Kifas check (default: true)
#
# Step outputs (written to $GITHUB_OUTPUT):
#   suite-run-id — the Kifas suite run this job started
#   suite-result — passed | failed | aborted | unreported, set only from the run's terminal
#                  result; never from the trigger succeeding
# ---------------------------------------------------------------------------

: "${KIFAS_API_KEY:?KIFAS_API_KEY is required}"
: "${KIFAS_GATE_ID:=}"
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
: "${KIFAS_TRIGGER_ATTEMPTS:=3}"
: "${KIFAS_RETRY_DELAY_S:=5}"
: "${KIFAS_OUTCOME_WAIT_MINUTES:=10}"
: "${KIFAS_WAIT_FOR_RESULT:=true}"
if [[ ! "${KIFAS_OUTCOME_WAIT_MINUTES}" =~ ^[0-9]+$ ]]; then KIFAS_OUTCOME_WAIT_MINUTES=10; fi

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

# The identity Kifas checks against the run's signed OIDC token: the run and its
# attempt, the repository's immutable id, the workflow file and revision, the
# event, and both revisions — the pull request's head and the one this run
# tested (GitHub's synthetic merge commit on a pull_request run).
REPOSITORY_ID="${GITHUB_REPOSITORY_ID:-}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
WORKFLOW_REF="${GITHUB_WORKFLOW_REF:-}"
WORKFLOW_SHA="${GITHUB_WORKFLOW_SHA:-}"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
TESTED_SHA="${COMMIT_SHA}"
HEAD_SHA=""
if [[ -f "${GITHUB_EVENT_PATH:-}" ]]; then
  HEAD_SHA="$(jq -r '.pull_request.head.sha // .merge_group.head_sha // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || true)"
fi
HEAD_SHA="${HEAD_SHA:-${COMMIT_SHA}}"

# ---------------------------------------------------------------------------
# What this run tests, for Kifas's records and its check on the commit: the
# branch, the pull request and the commit. It is descriptive and separate from
# the signed identity above, which stays exactly as GitHub reports it. An event
# that names no pull request leaves it empty; Kifas looks it up from the commit.
# ---------------------------------------------------------------------------
event_field() {
  [[ -f "${GITHUB_EVENT_PATH:-}" ]] || return 0
  jq -r "$1 // empty" "${GITHUB_EVENT_PATH}" 2>/dev/null || true
}
branch_of_ref() {
  case "$1" in
    refs/heads/*) printf '%s' "${1#refs/heads/}" ;;
    refs/* | "") ;;
    *) if [[ ! "$1" =~ ^[0-9a-fA-F]{40}$ ]]; then printf '%s' "$1"; fi ;;
  esac
}
GIT_BRANCH=""
GIT_PR_NUMBER=""
GIT_HEAD_SHA=""
case "${EVENT_NAME}" in
  pull_request | pull_request_target)
    GIT_BRANCH="$(event_field '.pull_request.head.ref')"
    GIT_PR_NUMBER="$(event_field '.pull_request.number')"
    GIT_HEAD_SHA="$(event_field '.pull_request.head.sha')"
    ;;
  deployment_status | deployment)
    GIT_BRANCH="$(branch_of_ref "$(event_field '.deployment.ref')")"
    GIT_HEAD_SHA="$(event_field '.deployment.sha')"
    ;;
  workflow_run)
    GIT_BRANCH="$(event_field '.workflow_run.head_branch')"
    GIT_PR_NUMBER="$(event_field '.workflow_run.pull_requests[0].number')"
    GIT_HEAD_SHA="$(event_field '.workflow_run.head_sha')"
    ;;
  push)
    GIT_BRANCH="$(branch_of_ref "${GITHUB_REF:-}")"
    GIT_HEAD_SHA="$(event_field '.after')"
    ;;
  *)
    GIT_BRANCH="$(branch_of_ref "${GITHUB_REF:-}")"
    ;;
esac
GIT_HEAD_SHA="${GIT_HEAD_SHA:-${COMMIT_SHA}}"
if [[ ! "${GIT_PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then GIT_PR_NUMBER=""; fi
if [[ ! "${GIT_HEAD_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then GIT_HEAD_SHA=""; fi

MANAGED=0
if [[ -n "${KIFAS_GATE_ID}" ]]; then
  MANAGED=1
fi

# ---------------------------------------------------------------------------
# Step outputs. suite-result is written only from a terminal result.
# ---------------------------------------------------------------------------
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"
  fi
}

# ---------------------------------------------------------------------------
# A fresh GitHub Actions OIDC token for Kifas, requested before every managed
# call so none is sent stale. It is masked before anything could print it.
# ---------------------------------------------------------------------------
GATE_OIDC=""
fetch_identity() {
  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    echo "::error::These Kifas checks need a GitHub identity token. Add 'permissions: id-token: write' to the job that runs the Kifas action." >&2
    return 1
  fi
  local sep='?' response
  [[ "${ACTIONS_ID_TOKEN_REQUEST_URL}" == *\?* ]] && sep='&'
  response="$(
    "${KIFAS_CURL}" --silent --show-error --fail --max-time 15 \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}${sep}audience=kifas-github-gate" 2>/dev/null
  )" || {
    echo "::error::GitHub did not issue an identity token for this job." >&2
    return 1
  }
  GATE_OIDC="$(printf '%s' "${response}" | jq -r '.value // empty' 2>/dev/null || true)"
  if [[ -z "${GATE_OIDC}" ]]; then
    echo "::error::GitHub did not issue an identity token for this job." >&2
    return 1
  fi
  echo "::add-mask::${GATE_OIDC}"
}

# gate_request <max-time> <stdin body, or ""> <curl args...> — one managed
# call, retried after a lost answer or a 5xx: Kifas reserves each run attempt
# once, so a retry reuses the same admission and can never start a second
# suite. A 4xx is final. The body is sent again on every attempt.
# Sets GATE_BODY and GATE_STATUS.
GATE_BODY=""
GATE_STATUS=""
gate_request() {
  local max_time="$1" body="$2"
  shift 2
  local attempt=1 out rc
  while :; do
    fetch_identity || return 1
    rc=0
    out="$(
      "${KIFAS_CURL}" --silent --show-error --max-time "${max_time}" \
        --write-out '\n%{http_code}' \
        -H "Authorization: Bearer ${KIFAS_API_KEY}" \
        -H "X-Kifas-Github-OIDC: ${GATE_OIDC}" \
        "$@" 2>&1 <<<"${body}"
    )" || rc=$?
    GATE_STATUS="${out##*$'\n'}"
    GATE_BODY="${out%$'\n'*}"
    [[ "${GATE_STATUS}" =~ ^[0-9]{3}$ ]] || GATE_STATUS="000"
    if [[ "${rc}" -eq 0 && "${GATE_STATUS}" -ge 200 && "${GATE_STATUS}" -lt 300 ]]; then
      return 0
    fi
    if [[ "${GATE_STATUS}" -ge 400 && "${GATE_STATUS}" -lt 500 ]]; then
      return 1
    fi
    if (( attempt >= KIFAS_TRIGGER_ATTEMPTS )); then
      return 1
    fi
    echo "::warning::Kifas did not answer (HTTP ${GATE_STATUS}); retrying the same run attempt (${attempt}/${KIFAS_TRIGGER_ATTEMPTS})."
    attempt=$(( attempt + 1 ))
    sleep "${KIFAS_RETRY_DELAY_S}"
  done
}

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

# A cancelled or terminated job never leaves a result behind: suite-result stays
# unset, so the required check that reads it fails instead of passing.
on_cancel() {
  trap - INT TERM
  echo "::error::Kifas check cancelled before the suite reached a result${KIFAS_RUN_ID:+ (run_id=${KIFAS_RUN_ID})}." >&2
  write_step_summary "$(printf '### ⏹️ Kifas E2E — cancelled\n\n**Result:** no result — the job was cancelled')"
  exit 1
}
trap on_cancel INT TERM

# ---------------------------------------------------------------------------
# Upload the app artifact, if any. A GitHub Actions artifact has no publicly
# fetchable URL, so the file is uploaded directly and the trigger below gets
# the resulting Kifas app_build id instead of the local path.
# Alternatively, if KIFAS_APP_ARTIFACT is an http(s) URL, it is forwarded
# directly to Kifas to download.
# ---------------------------------------------------------------------------
# A preview address can carry a protection token in its query or fragment:
# hide it, and that part on its own, from every later log line.
if [[ -n "${KIFAS_TARGET_URL}" && "${KIFAS_TARGET_URL}" =~ [?#] ]]; then
  echo "::add-mask::${KIFAS_TARGET_URL}"
  TARGET_SECRET="${KIFAS_TARGET_URL#*[?#]}"
  if [[ -n "${TARGET_SECRET}" ]]; then
    echo "::add-mask::${TARGET_SECRET}"
  fi
fi

APP_BUILD_ID=""
APP_ARTIFACT_URL=""
if [[ -n "${KIFAS_APP_ARTIFACT}" && "${KIFAS_APP_ARTIFACT}" =~ ^https?:// ]]; then
  APP_ARTIFACT_URL="${KIFAS_APP_ARTIFACT}"
  # A signed address is a credential: hide it, and its query on its own, from
  # every later log line.
  echo "::add-mask::${APP_ARTIFACT_URL}"
  if [[ "${APP_ARTIFACT_URL}" == *\?* ]]; then
    echo "::add-mask::${APP_ARTIFACT_URL#*\?}"
  fi
  echo "App artifact URL will be fetched by Kifas: ${APP_ARTIFACT_URL%%\?*}"
elif [[ -n "${KIFAS_APP_ARTIFACT}" && "${MANAGED}" -eq 1 ]]; then
  if [[ ! -f "${KIFAS_APP_ARTIFACT}" ]]; then
    echo "::error::app-artifact not found: ${KIFAS_APP_ARTIFACT}" >&2
    exit 1
  fi

  echo "::group::Kifas — upload app artifact"
  if ! gate_request "${KIFAS_UPLOAD_TIMEOUT_S}" "" \
    -X POST \
    -F "file=@${KIFAS_APP_ARTIFACT}" \
    --form-string "gate_id=${KIFAS_GATE_ID}" \
    --form-string "repository_id=${REPOSITORY_ID}" \
    --form-string "repo=${REPO}" \
    --form-string "workflow_ref=${WORKFLOW_REF}" \
    --form-string "workflow_sha=${WORKFLOW_SHA}" \
    --form-string "run_id=${RUN_ID}" \
    --form-string "run_attempt=${RUN_ATTEMPT}" \
    --form-string "pr_number=${PR_NUMBER}" \
    --form-string "head_sha=${HEAD_SHA}" \
    --form-string "tested_sha=${TESTED_SHA}" \
    --form-string "event=${EVENT_NAME}" \
    --form-string "branch=${BRANCH}" \
    "${KIFAS_API_BASE}/v1/app-builds/upload"; then
    echo "::error::app-artifact upload failed (HTTP ${GATE_STATUS}):" >&2
    echo "${GATE_BODY}" >&2
    exit 1
  fi
  APP_BUILD_ID="$(echo "${GATE_BODY}" | jq -r '.app_build_id // empty' 2>/dev/null || true)"
  if [[ -z "${APP_BUILD_ID}" ]]; then
    echo "::error::app-artifact upload response missing app_build_id. Response: ${GATE_BODY}" >&2
    exit 1
  fi
  echo "Uploaded app artifact -> app_build_id: ${APP_BUILD_ID}"
  echo "::endgroup::"
elif [[ -n "${KIFAS_APP_ARTIFACT}" ]]; then
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
echo "git:         branch=${GIT_BRANCH:-<none>} pr=${GIT_PR_NUMBER:-<none>} commit=${GIT_HEAD_SHA:0:7}"
echo "run_id:      ${RUN_ID}"
if [[ "${MANAGED}" -eq 1 ]]; then
  echo "gate_id:     ${KIFAS_GATE_ID}"
  echo "run_attempt: ${RUN_ATTEMPT}"
fi
if [[ -n "${KIFAS_TARGET_URL}" ]]; then
  echo "target_url:  ${KIFAS_TARGET_URL%%[?#]*}"
else
  echo "target_url:  <none>"
fi
echo "suite:       ${KIFAS_SUITE:-<default suite>}"
APP_BUILD_LABEL="${APP_BUILD_ID:-${APP_ARTIFACT_URL:+url}}"
echo "app_build:   ${APP_BUILD_LABEL:-<none>}"
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
  --arg app_artifact  "${APP_BUILD_ID:-${APP_ARTIFACT_URL}}" \
  --arg environment   "${KIFAS_ENVIRONMENT}" \
  --arg suite         "${KIFAS_SUITE}" \
  --argjson params    "${PARAMS_JSON}" \
  --arg repo          "${REPO}" \
  --arg commit_sha    "${COMMIT_SHA}" \
  --arg branch        "${BRANCH}" \
  --arg pr_number     "${PR_NUMBER}" \
  --arg run_id        "${RUN_ID}" \
  --arg gate_id       "${KIFAS_GATE_ID}" \
  --arg repository_id "${REPOSITORY_ID}" \
  --arg run_attempt   "${RUN_ATTEMPT}" \
  --arg workflow_ref  "${WORKFLOW_REF}" \
  --arg workflow_sha  "${WORKFLOW_SHA}" \
  --arg event         "${EVENT_NAME}" \
  --arg head_sha      "${HEAD_SHA}" \
  --arg tested_sha    "${TESTED_SHA}" \
  --arg git_branch    "${GIT_BRANCH}" \
  --arg git_pr_number "${GIT_PR_NUMBER}" \
  --arg git_head_sha  "${GIT_HEAD_SHA}" \
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
      run_id:     (if $run_id    != "" then ($run_id    | tonumber) else null end),
      run_attempt:   (if $run_attempt   != "" then ($run_attempt   | tonumber) else null end),
      repository_id: (if $repository_id != "" then ($repository_id | tonumber) else null end),
      workflow_ref:  (if $workflow_ref  != "" then $workflow_ref  else null end),
      workflow_sha:  (if $workflow_sha  != "" then $workflow_sha  else null end),
      event:         (if $event         != "" then $event         else null end),
      head_sha:      (if $head_sha      != "" then $head_sha      else null end),
      tested_sha:    (if $tested_sha    != "" then $tested_sha    else null end),
      git: {
        repo:      $repo,
        branch:    (if $git_branch    != "" then $git_branch                      else null end),
        pr_number: (if $git_pr_number != "" then ($git_pr_number | tonumber)      else null end),
        head_sha:  (if $git_head_sha  != "" then ($git_head_sha | ascii_downcase) else null end)
      }
    }
  }
  + (if $suite != "" then { suite: $suite } else {} end)
  + (if $gate_id != "" then { gate_id: $gate_id } else {} end)'
)"

# ---------------------------------------------------------------------------
# POST /v1/github/runs
# ---------------------------------------------------------------------------
if [[ "${MANAGED}" -eq 1 ]]; then
  # Downloading a build from an address happens inside this call, so it gets
  # the upload's time budget.
  TRIGGER_MAX_TIME=30
  if [[ -n "${APP_ARTIFACT_URL}" ]]; then
    TRIGGER_MAX_TIME="${KIFAS_UPLOAD_TIMEOUT_S}"
  fi
  if ! gate_request "${TRIGGER_MAX_TIME}" "${PAYLOAD}" \
    -X POST \
    -H "Content-Type: application/json" \
    --data @- \
    "${KIFAS_API_BASE}/v1/github/runs"; then
    echo "::error::Kifas trigger request failed (HTTP ${GATE_STATUS}):" >&2
    echo "${GATE_BODY}" >&2
    exit 1
  fi
  TRIGGER_RESPONSE="${GATE_BODY}"
else
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
fi

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
# The run id becomes a step output and part of a URL: anything but a UUID
# (a newline could write outputs of its own) is refused.
if [[ ! "${KIFAS_RUN_ID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "::error::Kifas returned a run id that is not a run id; refusing to use it." >&2
  exit 1
fi
set_output suite-run-id "${KIFAS_RUN_ID}"

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

# Kifas posts the result as the Kifas check on this commit when the GitHub App
# may; a workflow that requires that check instead of this job can stop here.
WAIT_FOR_OUTCOME="$(echo "${TRIGGER_RESPONSE}" | jq -r 'if .wait_for_outcome == false then "no" else "yes" end' 2>/dev/null || echo yes)"
CHECK_URL="$(echo "${TRIGGER_RESPONSE}" | jq -r '.check.url // empty' 2>/dev/null || true)"
if [[ "${KIFAS_WAIT_FOR_RESULT}" == "false" && "${WAIT_FOR_OUTCOME}" == "no" ]]; then
  CHECK_LINK="the Kifas check on this commit"
  if [[ -n "${CHECK_URL}" ]]; then
    CHECK_LINK="$(printf '[the Kifas check](%s) on this commit' "${CHECK_URL}")"
  fi
  write_step_summary "$(printf '### Kifas · running\n\nKifas posts the result as %s, including any test it updates to match your change.\n\n%s' "${CHECK_LINK}" "$(run_link)")"
  echo "Kifas reports the result as the Kifas check on this commit${CHECK_URL:+: ${CHECK_URL}}"
  exit 0
fi

# Report #1: run started.
notify "$(printf '### 🔄 Kifas E2E — run started\n\n**Status:** running\n\n%s\n\n<sub>commit `%s`</sub>' "$(run_link)" "${COMMIT_SHA:0:7}")"

# ---------------------------------------------------------------------------
# Poll until terminal status or timeout
# ---------------------------------------------------------------------------
START_TS="$(date +%s)"
LAST_STATUS=""
SETTLE_START_TS=""

while true; do
  NOW_TS="$(date +%s)"
  ELAPSED=$(( NOW_TS - START_TS ))

  if (( ELAPSED >= KIFAS_TIMEOUT_S )) && [[ -z "${SETTLE_START_TS}" ]]; then
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
    passed|completed|failed|aborted|unreported)
      # The tests are done; Kifas may still be deciding what a failure means or
      # proving an update. Wait for that, within the outcome budget.
      OUTCOME_STATE="$(echo "${POLL_RESPONSE}" | jq -r 'if (.outcome | type) != "object" then "none" elif .outcome.settled == true then "settled" else "unsettled" end')"
      if [[ "${OUTCOME_STATE}" == "unsettled" ]]; then
        if [[ -z "${SETTLE_START_TS}" ]]; then
          SETTLE_START_TS="${NOW_TS}"
          echo "[+${ELAPSED}s] tests finished; waiting up to ${KIFAS_OUTCOME_WAIT_MINUTES} min for Kifas to finish checking"
        fi
        if (( NOW_TS - SETTLE_START_TS < KIFAS_OUTCOME_WAIT_MINUTES * 60 )); then
          sleep "${KIFAS_POLL_INTERVAL_S}"
          continue
        fi
        echo "Kifas is still checking; reporting what it knows now."
      fi

      # Prefer the run_url from the poll (authoritative); fall back to trigger's.
      RUN_URL_POLL="$(echo "${POLL_RESPONSE}" | jq -r '.run_url // empty')"
      if [[ -n "${RUN_URL_POLL}" ]]; then KIFAS_RUN_URL="${RUN_URL_POLL}"; fi
      REPORT="$(echo "${POLL_RESPONSE}" | jq -r '.report // empty')"
      REPORT_MD="$(echo "${POLL_RESPONSE}" | jq -r '.report_markdown // empty')"
      # Why a single run ended the way it did — e.g. an `action_required` test
      # waiting on a person to review it before it is published.
      REASON="$(echo "${POLL_RESPONSE}" | jq -r '.reason // empty')"

      COUNTS="$(echo "${POLL_RESPONSE}" | jq -r '
        if .counts then "\(.counts.passed) passed, \(.counts.failed) failed of \(.counts.total)" else empty end
      ')"

      # The one place suite-result is written: the run's own terminal result.
      case "${STATUS}" in
        completed) SUITE_RESULT="$([[ "${CONCLUSION}" == "success" ]] && echo passed || echo failed)" ;;
        *) SUITE_RESULT="${STATUS}" ;;
      esac
      set_output suite-result "${SUITE_RESULT}"

      echo ""
      echo "Kifas run finished — status=${STATUS} conclusion=${CONCLUSION}"
      if [[ -n "${REASON}" ]]; then
        echo "Reason: ${REASON}"
      fi

      # Kifas's final outcome: success, a test updated, waiting for you, a bug,
      # or on us. On us is neutral and never fails the job.
      OUTCOME_CONCLUSION=""
      if [[ "${OUTCOME_STATE}" != "none" ]]; then
        OUTCOME_CONCLUSION="$(echo "${POLL_RESPONSE}" | jq -r '.outcome.conclusion // empty')"
      fi
      if [[ -n "${OUTCOME_CONCLUSION}" ]]; then
        OUTCOME_TITLE="$(echo "${POLL_RESPONSE}" | jq -r '.outcome.title // "Kifas"')"
        OUTCOME_SUMMARY="$(echo "${POLL_RESPONSE}" | jq -r '.outcome.summary // empty')"
        set_output conclusion "${OUTCOME_CONCLUSION}"
        echo "${OUTCOME_TITLE}"
        if [[ -n "${OUTCOME_SUMMARY}" ]]; then echo "${OUTCOME_SUMMARY}"; fi
        notify "$(printf '### %s\n\n%s\n\n%s' "${OUTCOME_TITLE}" "${OUTCOME_SUMMARY}" "$(run_link)")"
        case "${OUTCOME_CONCLUSION}" in
          success | neutral)
            echo "Kifas check PASSED (${OUTCOME_CONCLUSION})."
            exit 0
            ;;
          *)
            echo "::error::Kifas check FAILED — run_id=${KIFAS_RUN_ID} conclusion=${OUTCOME_CONCLUSION}" >&2
            exit 1
            ;;
        esac
      fi

      if [[ -n "${REPORT}" ]]; then
        echo "${REPORT}"
      fi

      # Prefer the Markdown report, printed as is: a multi-line error stays one
      # fenced block. An older server sends only the plain lines.
      REPORT_BLOCK=""
      if [[ -n "${REPORT_MD}" ]]; then
        REPORT_BLOCK="$(printf '\n\n%s' "${REPORT_MD}")"
      elif [[ -n "${REPORT}" ]]; then
        REPORT_BLOCK="$(printf '\n\n%s' "$(echo "${REPORT}" | sed 's/^/- /')")"
      fi
      REASON_BLOCK=""
      if [[ -n "${REASON}" ]]; then
        REASON_BLOCK="$(printf '\n\n**Why:** %s' "${REASON}")"
      fi
      COUNTS_BLOCK=""
      if [[ -n "${COUNTS}" ]]; then
        COUNTS_BLOCK="$(printf '\n\n**Tests:** %s' "${COUNTS}")"
      fi

      if [[ "${CONCLUSION}" == "success" ]]; then
        notify "$(printf '### ✅ Kifas E2E — passed\n\n**Result:** success%s\n\n%s%s' "${COUNTS_BLOCK}" "$(run_link)" "${REPORT_BLOCK}")"
        echo "Kifas check PASSED."
        exit 0
      else
        notify "$(printf '### ❌ Kifas E2E — %s\n\n**Result:** %s%s%s\n\n%s%s' "${STATUS}" "${CONCLUSION}" "${REASON_BLOCK}" "${COUNTS_BLOCK}" "$(run_link)" "${REPORT_BLOCK}")"
        echo "::error::Kifas check FAILED — run_id=${KIFAS_RUN_ID} conclusion=${CONCLUSION}${REASON:+ — ${REASON}}" >&2
        exit 1
      fi
      ;;
  esac

  sleep "${KIFAS_POLL_INTERVAL_S}"
done
