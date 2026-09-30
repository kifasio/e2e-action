#!/usr/bin/env bash
set -euo pipefail
set +x

# ---------------------------------------------------------------------------
# Kifas Remote WebDriver — run one test command against the Kifas gateway,
# a drop-in replacement for BrowserStack App Automate.
#
# 1. Uploads the app build (KIFAS_APP_PATH) and opens a Kifas suite build.
# 2. Exports the connection env vars the test command's WebDriver client reads
#    (KIFAS_REMOTE_URL, KIFAS_USERNAME, KIFAS_ACCESS_KEY, KIFAS_APP,
#    KIFAS_PROJECT_NAME, KIFAS_BUILD_NAME, KIFAS_BUILD_ID). The customer maps
#    these into its existing remote-driver config — see README.md.
# 3. Runs KIFAS_TEST_COMMAND. Its exit code is this action's exit code, always.
# 4. Closes the Kifas suite build on EXIT/INT/TERM, best-effort.
#
# Required env:
#   KIFAS_API_KEY      — Kifas API key with the session:create and workflow:run scopes
#   KIFAS_PROJECT_ID    — Kifas project uuid
#   KIFAS_SUITE_NAME    — suite name shown in Kifas
#   KIFAS_BUILD_NAME    — human build label (BrowserStack's buildName)
#   KIFAS_BUILD_ID      — caller-supplied idempotency key for this build
#   KIFAS_APP_PATH      — local path to the .apk/.ipa to upload
#   KIFAS_TEST_COMMAND  — shell command that runs the customer's test suite
#
# Optional env:
#   KIFAS_API_BASE      — Kifas REST API base (default: https://api.kifas.io)
#   KIFAS_REMOTE_URL    — WebDriver hub URL (default: https://hub.kifas.io/wd/hub)
#   KIFAS_BUILD_VERSION — build version label (default: the first 7 chars of
#                          GITHUB_SHA when it's a full 40-char commit SHA,
#                          otherwise KIFAS_BUILD_NAME)
#   KIFAS_LINK_GITHUB_BUILD — "true" also sends repo/commit/PR linkage (needs
#                             the Kifas GitHub App on the repo; see README.md)
#   KIFAS_CURL          — curl binary override for testing (default: curl)
# ---------------------------------------------------------------------------

: "${KIFAS_API_KEY:?KIFAS_API_KEY is required}"
: "${KIFAS_PROJECT_ID:?KIFAS_PROJECT_ID is required}"
: "${KIFAS_SUITE_NAME:?KIFAS_SUITE_NAME is required}"
: "${KIFAS_BUILD_NAME:?KIFAS_BUILD_NAME is required}"
: "${KIFAS_BUILD_ID:?KIFAS_BUILD_ID is required}"
: "${KIFAS_APP_PATH:?KIFAS_APP_PATH is required}"
: "${KIFAS_TEST_COMMAND:?KIFAS_TEST_COMMAND is required}"
: "${KIFAS_API_BASE:=https://api.kifas.io}"
: "${KIFAS_REMOTE_URL:=https://hub.kifas.io/wd/hub}"
: "${KIFAS_LINK_GITHUB_BUILD:=false}"
: "${KIFAS_CURL:=curl}"

EXTERNAL_KEY="${KIFAS_BUILD_ID}"

# The GitHub-mandated mask directive. It must run before any command that
# could emit the key, and the key is never handed to curl on argv or traced —
# xtrace is disabled at the top of this script for exactly that reason.
printf '::add-mask::%s\n' "${KIFAS_API_KEY}"

if [[ ! -f "${KIFAS_APP_PATH}" ]]; then
  echo "::error::app-path not found: ${KIFAS_APP_PATH}" >&2
  exit 1
fi

CURL_CONFIG="$(mktemp)"
chmod 600 "${CURL_CONFIG}"
printf 'header = "Authorization: Bearer %s"\n' "${KIFAS_API_KEY}" > "${CURL_CONFIG}"
# Responses land in a file so the HTTP status can come back on stdout via
# --write-out. 0600 because an error body may name the org or the build.
RESPONSE_BODY="$(mktemp)"
chmod 600 "${RESPONSE_BODY}"

SUITE_RUN_ID=""
CLOSED=0

# Kifas's own error message when the server sent a JSON one, else a reason
# derived from the status. A non-JSON body is deliberately never echoed: an
# HTML error page or proxy dump can carry a presigned URL or a credential.
server_reason() {
  local status="$1" message=""
  if [[ -s "${RESPONSE_BODY}" ]]; then
    message="$(jq -r 'if (.error.message | type) == "string" then .error.message else "" end' \
      "${RESPONSE_BODY}" 2>/dev/null || true)"
  fi
  message="${message//[$'\r\n\t']/ }"
  if [[ -n "${message}" ]]; then
    printf 'HTTP %s: %s' "${status}" "${message:0:400}"
    return
  fi
  local reason
  case "${status}" in
    400 | 422) reason='Kifas rejected the request as invalid' ;;
    401) reason='authentication failed — check the api-key input' ;;
    403) reason='the API key is missing a required scope (session:create and workflow:run are both needed)' ;;
    404) reason='the requested Kifas resource was not found' ;;
    408) reason='the Kifas request timed out' ;;
    413) reason='the app build exceeds the 500 MB upload limit' ;;
    429) reason='Kifas rate limit exceeded' ;;
    5??) reason='Kifas is temporarily unavailable' ;;
    *) reason='Kifas rejected the request' ;;
  esac
  printf 'HTTP %s: %s (no error message in the response)' "${status}" "${reason}"
}

# shellcheck disable=SC2317 # invoked only via the traps installed below
close_build() {
  if [[ "${CLOSED}" -eq 1 || -z "${SUITE_RUN_ID}" ]]; then
    return 0
  fi
  CLOSED=1
  if ! "${KIFAS_CURL}" --silent --show-error --config "${CURL_CONFIG}" --max-time 30 \
    -X POST "${KIFAS_API_BASE%/}/v1/remote-webdriver/builds/${SUITE_RUN_ID}/close" >/dev/null 2>&1; then
    echo "::warning::failed to close Kifas suite build ${SUITE_RUN_ID}" >&2
  fi
}

# shellcheck disable=SC2317 # invoked only via the traps installed below
on_exit() {
  local code=$?
  close_build
  rm -f "${CURL_CONFIG}" "${RESPONSE_BODY}"
  exit "${code}"
}

# shellcheck disable=SC2317 # invoked only via the traps installed below
on_signal() {
  local sig="$1"
  close_build
  trap - EXIT
  rm -f "${CURL_CONFIG}" "${RESPONSE_BODY}"
  case "${sig}" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
  esac
}

trap on_exit EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# --- Build identity -------------------------------------------------------
# Without these every CI build lands in Kifas as version 0.0.0 / build 0, so
# the build list cannot tell one push from another.
COMMIT_SHA="${GITHUB_SHA:-}"
BUILD_VERSION="${KIFAS_BUILD_VERSION:-}"
if [[ -z "${BUILD_VERSION}" ]]; then
  if [[ "${COMMIT_SHA}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    BUILD_VERSION="${COMMIT_SHA:0:7}"
  else
    BUILD_VERSION="${KIFAS_BUILD_NAME}"
  fi
fi
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-${GITHUB_RUN_ID:-}}"
[[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]] || BUILD_NUMBER='0'

# --form-string, never -F: -F reads a leading @ or < in the VALUE as a file
# path, so a branch named @release-candidate would try to upload a file.
IDENTITY_FORM=(
  --form-string "version=${BUILD_VERSION}"
  --form-string "build_number=${BUILD_NUMBER}"
)

# Commit/PR linkage is opt-in: the upload endpoint answers 404 "repo not
# connected to Kifas" when repo+commit_sha name a repo without the Kifas
# GitHub App, which would fail every upload for a customer who has not
# installed it. version/build_number above need no such connection.
if [[ "${KIFAS_LINK_GITHUB_BUILD}" == "true" ]]; then
  if [[ ! "${GITHUB_REPOSITORY:-}" =~ ^[[:alnum:]_.-]+/[[:alnum:]_.-]+$ ]]; then
    echo "::error::link-github-build needs GITHUB_REPOSITORY as owner/name" >&2
    exit 1
  fi
  if [[ ! "${COMMIT_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::link-github-build needs GITHUB_SHA as a 40-character lowercase commit sha" >&2
    exit 1
  fi
  IDENTITY_FORM+=(
    --form-string "repo=${GITHUB_REPOSITORY}"
    --form-string "commit_sha=${COMMIT_SHA}"
  )
  if [[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]]; then
    IDENTITY_FORM+=(
      --form-string "ci_run_url=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    )
  fi
  if [[ -n "${GITHUB_REF_NAME:-}" ]]; then
    IDENTITY_FORM+=(--form-string "branch=${GITHUB_REF_NAME}")
  fi
  if [[ "${GITHUB_REF:-}" =~ ^refs/pull/([0-9]+)/ ]]; then
    IDENTITY_FORM+=(--form-string "pr_number=${BASH_REMATCH[1]}")
  fi
fi

echo "::group::Kifas — upload app build"
UPLOAD_STATUS="$(
  "${KIFAS_CURL}" --silent --show-error --config "${CURL_CONFIG}" --max-time 300 \
    --output "${RESPONSE_BODY}" --write-out '%{http_code}' \
    -F "file=@${KIFAS_APP_PATH}" \
    "${IDENTITY_FORM[@]}" \
    "${KIFAS_API_BASE%/}/v1/app-builds/upload"
)" || {
  echo "::error::app build upload failed: could not reach Kifas" >&2
  exit 1
}
if [[ ! "${UPLOAD_STATUS}" =~ ^[0-9]{3}$ ]]; then
  echo "::error::app build upload failed: Kifas returned no HTTP status" >&2
  exit 1
fi
if [[ ! "${UPLOAD_STATUS}" =~ ^2[0-9]{2}$ ]]; then
  echo "::error::app build upload failed — $(server_reason "${UPLOAD_STATUS}")" >&2
  exit 1
fi
BUILD_URI="$(jq -r '.build_uri // empty' "${RESPONSE_BODY}")" || {
  echo "::error::app build upload response was not valid JSON" >&2
  exit 1
}
if [[ -z "${BUILD_URI}" || "${BUILD_URI}" == "null" ]]; then
  echo "::error::app build upload response missing build_uri" >&2
  exit 1
fi
echo "Uploaded app build ${BUILD_VERSION} (${BUILD_NUMBER}) -> ${BUILD_URI}"
echo "::endgroup::"

echo "::group::Kifas — open suite build"
OPEN_PAYLOAD="$(jq -n \
  --arg projectId "${KIFAS_PROJECT_ID}" \
  --arg suiteName "${KIFAS_SUITE_NAME}" \
  --arg externalKey "${EXTERNAL_KEY}" \
  --arg displayName "${KIFAS_BUILD_NAME}" \
  '{projectId: $projectId, suiteName: $suiteName, externalKey: $externalKey, displayName: $displayName}'
)"
OPEN_STATUS="$(
  "${KIFAS_CURL}" --silent --show-error --config "${CURL_CONFIG}" --max-time 30 \
    --output "${RESPONSE_BODY}" --write-out '%{http_code}' \
    -X POST -H 'Content-Type: application/json' --data "${OPEN_PAYLOAD}" \
    "${KIFAS_API_BASE%/}/v1/remote-webdriver/builds"
)" || {
  echo "::error::opening the Kifas suite build failed: could not reach Kifas" >&2
  exit 1
}
if [[ ! "${OPEN_STATUS}" =~ ^[0-9]{3}$ ]]; then
  echo "::error::opening the Kifas suite build failed: Kifas returned no HTTP status" >&2
  exit 1
fi
if [[ ! "${OPEN_STATUS}" =~ ^2[0-9]{2}$ ]]; then
  echo "::error::opening the Kifas suite build failed — $(server_reason "${OPEN_STATUS}")" >&2
  exit 1
fi
SUITE_RUN_ID="$(jq -r '.suiteRunId // empty' "${RESPONSE_BODY}")" || {
  echo "::error::open suite build response was not valid JSON" >&2
  exit 1
}
SUITE_RUN_URL="$(jq -r '.suiteRunUrl // empty' "${RESPONSE_BODY}")"
if [[ -z "${SUITE_RUN_ID}" || "${SUITE_RUN_ID}" == "null" ]]; then
  echo "::error::open suite build response missing suiteRunId" >&2
  exit 1
fi
echo "Opened suite build -> ${SUITE_RUN_ID}"
echo "::endgroup::"

if [[ -n "${SUITE_RUN_URL}" ]]; then
  echo "Kifas suite run: ${SUITE_RUN_URL}"
  echo "::notice title=Kifas suite run::${SUITE_RUN_URL}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Kifas remote WebDriver\n\n[View suite run](%s)\n' "${SUITE_RUN_URL}" >> "${GITHUB_STEP_SUMMARY}"
  fi
fi

export KIFAS_REMOTE_URL
export KIFAS_USERNAME="kifas"
export KIFAS_ACCESS_KEY="${KIFAS_API_KEY}"
export KIFAS_APP="${BUILD_URI}"
export KIFAS_PROJECT_NAME="${KIFAS_SUITE_NAME}"
export KIFAS_BUILD_NAME
export KIFAS_BUILD_ID="${SUITE_RUN_ID}"

echo "::group::Kifas — run test command"
set +e
bash -c "${KIFAS_TEST_COMMAND}"
TEST_EXIT=$?
set -e
echo "::endgroup::"

exit "${TEST_EXIT}"
