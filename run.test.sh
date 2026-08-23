#!/usr/bin/env bash
# Hermetic test suite for run.sh.
# No network calls — curl is replaced by a mock script via KIFAS_CURL.
# Usage: bash run.test.sh
# Exit 0 = all tests passed, Exit 1 = one or more tests failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="${SCRIPT_DIR}/run.sh"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_mock_curl() {
  local mock_file="$1"    # path to a script that will be the curl replacement
  cat > "${mock_file}" << 'MOCK_SCRIPT'
#!/usr/bin/env bash
# Reads MOCK_CURL_RESPONSES_FILE: one JSON line per call.
# Each invocation pops the first line and prints it to stdout.
# Exits 0 always (simulates HTTP 2xx).
# When MOCK_CURL_CALLS_LOG is set, appends the full arg list of each
# invocation as one line, so tests can assert call order/content.
set -euo pipefail
if [[ -n "${MOCK_CURL_CALLS_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "${MOCK_CURL_CALLS_LOG}"
fi
RESP_FILE="${MOCK_CURL_RESPONSES_FILE:?}"
if [[ ! -f "${RESP_FILE}" ]]; then
  echo '{"error":"mock exhausted"}' >&2
  exit 1
fi
# Pop first non-empty line
LINE=""
REST=()
while IFS= read -r l; do
  if [[ -z "${LINE}" && -n "${l}" ]]; then
    LINE="${l}"
  elif [[ -n "${l}" ]]; then
    REST+=("${l}")
  fi
done < "${RESP_FILE}"

printf '%s\n' "${REST[@]:-}" > "${RESP_FILE}"
echo "${LINE}"
MOCK_SCRIPT
  chmod +x "${mock_file}"
}

run_case() {
  local name="$1"
  local responses_file="$2"   # file whose lines are sequential mock responses
  local expected_exit="$3"
  shift 3
  local extra_env=("$@")

  local mock_curl="${TMP_DIR}/curl_${name}"
  make_mock_curl "${mock_curl}"

  local actual_exit=0
  env \
    KIFAS_API_KEY="test-key-123" \
    KIFAS_API_BASE="https://mock.kifas.io" \
    KIFAS_POLL_INTERVAL_S="0" \
    KIFAS_TIMEOUT_S="60" \
    KIFAS_CURL="${mock_curl}" \
    MOCK_CURL_RESPONSES_FILE="${responses_file}" \
    GITHUB_REPOSITORY="acme/my-app" \
    GITHUB_SHA="abc123def456" \
    GITHUB_REF_NAME="main" \
    GITHUB_RUN_ID="99" \
    GITHUB_REF="refs/heads/main" \
    "${extra_env[@]:+${extra_env[@]}}" \
    bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?

  if [[ "${actual_exit}" -eq "${expected_exit}" ]]; then
    echo "  PASS  ${name}"
    (( PASS++ )) || true
  else
    echo "  FAIL  ${name}  (expected exit ${expected_exit}, got ${actual_exit})"
    (( FAIL++ )) || true
  fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
echo "Running run.sh tests..."
echo ""

# Case 1: successful run (running → completed/success) → exit 0
RESP1="${TMP_DIR}/responses_success.txt"
cat > "${RESP1}" << 'EOF'
{"run_id":"run-001","poll_url":"/v1/github/runs/run-001/status"}
{"status":"running","conclusion":null}
{"status":"completed","conclusion":"success"}
EOF
run_case "success_flow" "${RESP1}" 0

# Case 2: failed run (running → completed/failure) → exit 1
RESP2="${TMP_DIR}/responses_failure.txt"
cat > "${RESP2}" << 'EOF'
{"run_id":"run-002","poll_url":"/v1/github/runs/run-002/status"}
{"status":"running","conclusion":null}
{"status":"completed","conclusion":"failure"}
EOF
run_case "failure_flow" "${RESP2}" 1

# Case 3: aborted run → exit 1
RESP3="${TMP_DIR}/responses_aborted.txt"
cat > "${RESP3}" << 'EOF'
{"run_id":"run-003","poll_url":"https://mock.kifas.io/v1/github/runs/run-003/status"}
{"status":"aborted","conclusion":"aborted"}
EOF
run_case "aborted_flow" "${RESP3}" 1

# Case 4: poll_url is absolute → still resolves correctly → success
RESP4="${TMP_DIR}/responses_abs_url.txt"
cat > "${RESP4}" << 'EOF'
{"run_id":"run-004","poll_url":"https://mock.kifas.io/v1/github/runs/run-004/status"}
{"status":"completed","conclusion":"success"}
EOF
run_case "absolute_poll_url" "${RESP4}" 0

# Case 5: PR number extracted from GITHUB_REF → success (env override)
RESP5="${TMP_DIR}/responses_pr.txt"
cat > "${RESP5}" << 'EOF'
{"run_id":"run-005","poll_url":"/v1/github/runs/run-005/status"}
{"status":"completed","conclusion":"success"}
EOF
run_case "pr_number_from_ref" "${RESP5}" 0 \
  GITHUB_REF="refs/pull/42/merge"

# Case 6: missing api-key → exit 1 (set -u catches unset var via :? expansion)
RESP6="${TMP_DIR}/responses_nokey.txt"
cat > "${RESP6}" << 'EOF'
{"run_id":"run-006","poll_url":"/v1/github/runs/run-006/status"}
EOF
actual_exit=0
env \
  KIFAS_API_KEY="" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${TMP_DIR}/curl_nokey" \
  MOCK_CURL_RESPONSES_FILE="${RESP6}" \
  GITHUB_REPOSITORY="acme/my-app" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -ne 0 ]]; then
  echo "  PASS  missing_api_key_exits_1"
  (( PASS++ )) || true
else
  echo "  FAIL  missing_api_key_exits_1  (expected non-zero exit, got 0)"
  (( FAIL++ )) || true
fi

# Case 7: with a GitHub token + step summary → posts the sticky comment, writes
# the summary, and still gates on success. Mock curl order: trigger, list(started),
# post, poll(completed), list(final), patch.
RESP7="${TMP_DIR}/responses_notify.txt"
cat > "${RESP7}" << 'EOF'
{"run_id":"run-007","poll_url":"/v1/github/runs/run-007/status","run_url":"https://app.kifas.io/acme/web/runs/run-007"}
[]
{"id":1}
{"status":"completed","conclusion":"success","run_url":"https://app.kifas.io/acme/web/runs/run-007"}
[{"id":1,"body":"<!-- kifas-e2e-run --> started"}]
{}
EOF
SUMMARY7="${TMP_DIR}/summary7.md"
: > "${SUMMARY7}"
mock_curl7="${TMP_DIR}/curl_notify"
make_mock_curl "${mock_curl7}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl7}" \
  MOCK_CURL_RESPONSES_FILE="${RESP7}" \
  KIFAS_GITHUB_TOKEN="ghtok" \
  GITHUB_API_URL="https://mock.github" \
  GITHUB_STEP_SUMMARY="${SUMMARY7}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="feature" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/pull/7/merge" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 0 ]] && grep -q "passed" "${SUMMARY7}" && grep -q "run-007" "${SUMMARY7}"; then
  echo "  PASS  notify_with_token_posts_and_summarizes"
  (( PASS++ )) || true
else
  echo "  FAIL  notify_with_token_posts_and_summarizes  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 8: an app artifact is present on disk → uploads it to
# /v1/app-builds/upload before triggering /v1/github/runs.
ARTIFACT8="${TMP_DIR}/fake8.apk"
echo "dummy" > "${ARTIFACT8}"
RESP8="${TMP_DIR}/responses_upload.txt"
cat > "${RESP8}" << 'EOF'
{"app_build_id":"build-abc123"}
{"run_id":"run-008","poll_url":"/v1/github/runs/run-008/status"}
{"status":"completed","conclusion":"success"}
EOF
CALLS8="${TMP_DIR}/calls8.log"
: > "${CALLS8}"
mock_curl8="${TMP_DIR}/curl_upload"
make_mock_curl "${mock_curl8}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl8}" \
  MOCK_CURL_RESPONSES_FILE="${RESP8}" \
  MOCK_CURL_CALLS_LOG="${CALLS8}" \
  KIFAS_APP_ARTIFACT="${ARTIFACT8}" \
  GITHUB_REPOSITORY="acme/my-app" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
UPLOAD_LINE="$(grep -n '/v1/app-builds/upload' "${CALLS8}" | head -1 | cut -d: -f1 || true)"
TRIGGER_LINE="$(grep -n '/v1/github/runs' "${CALLS8}" | head -1 | cut -d: -f1 || true)"
if [[ "${actual_exit}" -eq 0 && -n "${UPLOAD_LINE}" && -n "${TRIGGER_LINE}" && "${UPLOAD_LINE}" -lt "${TRIGGER_LINE}" ]]; then
  echo "  PASS  uploads_artifact_before_triggering"
  (( PASS++ )) || true
else
  echo "  FAIL  uploads_artifact_before_triggering  (exit=${actual_exit} upload_line=${UPLOAD_LINE:-<none>} trigger_line=${TRIGGER_LINE:-<none>})"
  (( FAIL++ )) || true
fi

# Case 9: no app artifact → never calls /v1/app-builds/upload.
RESP9="${TMP_DIR}/responses_noartifact.txt"
cat > "${RESP9}" << 'EOF'
{"run_id":"run-009","poll_url":"/v1/github/runs/run-009/status"}
{"status":"completed","conclusion":"success"}
EOF
CALLS9="${TMP_DIR}/calls9.log"
: > "${CALLS9}"
mock_curl9="${TMP_DIR}/curl_noartifact"
make_mock_curl "${mock_curl9}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl9}" \
  MOCK_CURL_RESPONSES_FILE="${RESP9}" \
  MOCK_CURL_CALLS_LOG="${CALLS9}" \
  GITHUB_REPOSITORY="acme/my-app" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 0 ]] && ! grep -q '/v1/app-builds/upload' "${CALLS9}"; then
  echo "  PASS  skips_upload_when_no_artifact"
  (( PASS++ )) || true
else
  echo "  FAIL  skips_upload_when_no_artifact  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 10: KIFAS_APP_ARTIFACT points at a file that doesn't exist → fails
# loudly (non-zero exit) before ever calling curl.
CALLS10="${TMP_DIR}/calls10.log"
: > "${CALLS10}"
mock_curl10="${TMP_DIR}/curl_missing"
make_mock_curl "${mock_curl10}"
RESP10="${TMP_DIR}/responses_missing.txt"
: > "${RESP10}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl10}" \
  MOCK_CURL_RESPONSES_FILE="${RESP10}" \
  MOCK_CURL_CALLS_LOG="${CALLS10}" \
  KIFAS_APP_ARTIFACT="${TMP_DIR}/does-not-exist.apk" \
  GITHUB_REPOSITORY="acme/my-app" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -ne 0 ]]; then
  echo "  PASS  fails_loudly_when_artifact_missing_on_disk"
  (( PASS++ )) || true
else
  echo "  FAIL  fails_loudly_when_artifact_missing_on_disk  (expected non-zero exit, got 0)"
  (( FAIL++ )) || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
# Case 11: the trigger response carries run_url → the log shows the dashboard
# deep link, not just the machine status endpoint. A customer reading the
# Actions log needs the link to the run in Kifas; the published action drifted
# without this once already.
RESP11="${TMP_DIR}/responses_runurl.txt"
cat > "${RESP11}" << 'EOF'
{"run_id":"run-011","poll_url":"/v1/github/runs/run-011/status","run_url":"https://app.kifas.io/acme/web/runs/run-011"}
{"status":"completed","conclusion":"success"}
EOF
OUT11="${TMP_DIR}/out11.log"
mock_curl11="${TMP_DIR}/curl_runurl"
make_mock_curl "${mock_curl11}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl11}" \
  MOCK_CURL_RESPONSES_FILE="${RESP11}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" > "${OUT11}" 2>&1 || actual_exit=$?
# Match the labelled line, not the raw `Trigger response:` JSON echo — that
# echo contains run_url too and would pass this test for the wrong reason.
if [[ "${actual_exit}" -eq 0 ]] \
  && grep -q '^View run: https://app.kifas.io/acme/web/runs/run-011$' "${OUT11}"; then
  echo "  PASS  logs_dashboard_run_url"
  (( PASS++ )) || true
else
  echo "  FAIL  logs_dashboard_run_url  (exit=${actual_exit}; run_url missing from log)"
  (( FAIL++ )) || true
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
