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
BODY=""
if [[ " $* " == *" --data @- "* ]]; then
  BODY="$(cat)"
fi
if [[ -n "${MOCK_CURL_CALLS_LOG:-}" ]]; then
  printf '%s %s\n' "$*" "${BODY}" >> "${MOCK_CURL_CALLS_LOG}"
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
# A line may name the HTTP status as "@<code> <body>", or a transport failure
# as "!<curl exit code>". Plain lines are a 200.
CODE=200
if [[ "${LINE}" =~ ^@([0-9]{3})\ (.*)$ ]]; then
  CODE="${BASH_REMATCH[1]}"
  LINE="${BASH_REMATCH[2]}"
fi
WANTS_CODE=0
[[ " $* " == *"%{http_code}"* ]] && WANTS_CODE=1
if [[ "${LINE}" =~ ^!([0-9]+)$ ]]; then
  echo "curl: (${BASH_REMATCH[1]}) Failed to connect" >&2
  [[ "${WANTS_CODE}" -eq 1 ]] && printf '\n000'
  exit "${BASH_REMATCH[1]}"
fi
if [[ "${WANTS_CODE}" -eq 1 ]]; then
  printf '%s\n%s' "${LINE}" "${CODE}"
else
  echo "${LINE}"
fi
if [[ "${CODE}" -ge 400 && " $* " == *" --fail"* ]]; then
  exit 22
fi
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
{"run_id":"00000000-0000-4000-8000-000000000001","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000001/status"}
{"status":"running","conclusion":null}
{"status":"completed","conclusion":"success"}
EOF
run_case "success_flow" "${RESP1}" 0

# Case 2: failed run (running → completed/failure) → exit 1
RESP2="${TMP_DIR}/responses_failure.txt"
cat > "${RESP2}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000002","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000002/status"}
{"status":"running","conclusion":null}
{"status":"completed","conclusion":"failure"}
EOF
run_case "failure_flow" "${RESP2}" 1

# Case 3: aborted run → exit 1
RESP3="${TMP_DIR}/responses_aborted.txt"
cat > "${RESP3}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000003","poll_url":"https://mock.kifas.io/v1/github/runs/00000000-0000-4000-8000-000000000003/status"}
{"status":"aborted","conclusion":"aborted"}
EOF
run_case "aborted_flow" "${RESP3}" 1

# Case 4: poll_url is absolute → still resolves correctly → success
RESP4="${TMP_DIR}/responses_abs_url.txt"
cat > "${RESP4}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000004","poll_url":"https://mock.kifas.io/v1/github/runs/00000000-0000-4000-8000-000000000004/status"}
{"status":"completed","conclusion":"success"}
EOF
run_case "absolute_poll_url" "${RESP4}" 0

# Case 5: PR number extracted from GITHUB_REF → success (env override)
RESP5="${TMP_DIR}/responses_pr.txt"
cat > "${RESP5}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000005","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000005/status"}
{"status":"completed","conclusion":"success"}
EOF
run_case "pr_number_from_ref" "${RESP5}" 0 \
  GITHUB_REF="refs/pull/42/merge"

# Case 6: missing api-key → exit 1 (set -u catches unset var via :? expansion)
RESP6="${TMP_DIR}/responses_nokey.txt"
cat > "${RESP6}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000006","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000006/status"}
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
{"run_id":"00000000-0000-4000-8000-000000000007","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000007/status","run_url":"https://app.kifas.io/acme/web/runs/00000000-0000-4000-8000-000000000007"}
[]
{"id":1}
{"status":"completed","conclusion":"success","run_url":"https://app.kifas.io/acme/web/runs/00000000-0000-4000-8000-000000000007"}
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
if [[ "${actual_exit}" -eq 0 ]] && grep -q "passed" "${SUMMARY7}" && grep -q "00000000-0000-4000-8000-000000000007" "${SUMMARY7}"; then
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
{"run_id":"00000000-0000-4000-8000-000000000008","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000008/status"}
{"status":"completed","conclusion":"success"}
EOF
CALLS8="${TMP_DIR}/calls8.log"
OUT8="${TMP_DIR}/out8.log"
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
  bash "${RUN_SH}" >"${OUT8}" 2>&1 || actual_exit=$?
UPLOAD_LINE="$(grep -n '/v1/app-builds/upload' "${CALLS8}" | head -1 | cut -d: -f1 || true)"
TRIGGER_LINE="$(grep -n '/v1/github/runs' "${CALLS8}" | head -1 | cut -d: -f1 || true)"
ok8=1
[[ "${actual_exit}" -eq 0 ]] || ok8=0
[[ -n "${UPLOAD_LINE}" && -n "${TRIGGER_LINE}" && "${UPLOAD_LINE}" -lt "${TRIGGER_LINE}" ]] || ok8=0
grep -q '^app_build:   build-abc123$' "${OUT8}" || ok8=0
if [[ "${ok8}" -eq 1 ]]; then
  echo "  PASS  uploads_artifact_before_triggering"
  (( PASS++ )) || true
else
  echo "  FAIL  uploads_artifact_before_triggering  (exit=${actual_exit} upload_line=${UPLOAD_LINE:-<none>} trigger_line=${TRIGGER_LINE:-<none>})"
  (( FAIL++ )) || true
fi

# Case 9: no app artifact → never calls /v1/app-builds/upload.
RESP9="${TMP_DIR}/responses_noartifact.txt"
cat > "${RESP9}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000009","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000009/status"}
{"status":"completed","conclusion":"success"}
EOF
CALLS9="${TMP_DIR}/calls9.log"
OUT9="${TMP_DIR}/out9.log"
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
  bash "${RUN_SH}" >"${OUT9}" 2>&1 || actual_exit=$?
ok9=1
[[ "${actual_exit}" -eq 0 ]] || ok9=0
! grep -q '/v1/app-builds/upload' "${CALLS9}" || ok9=0
grep -q '^app_build:   <none>$' "${OUT9}" || ok9=0
if [[ "${ok9}" -eq 1 ]]; then
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
{"run_id":"00000000-0000-4000-8000-000000000011","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000011/status","run_url":"https://app.kifas.io/acme/web/runs/00000000-0000-4000-8000-000000000011"}
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
# The link must be its own top-level line and an ::notice:: annotation. The
# raw trigger JSON must NOT be echoed: it contains run_url, so echoing it
# both leaks "how to build the URL" instead of the URL and would let a naive
# assertion here pass for the wrong reason.
ok11=1
grep -q '^Kifas run: https://app.kifas.io/acme/web/runs/00000000-0000-4000-8000-000000000011$' "${OUT11}" || ok11=0
grep -q '^::notice title=Kifas E2E run::https://app.kifas.io/acme/web/runs/00000000-0000-4000-8000-000000000011$' "${OUT11}" || ok11=0
! grep -q '^Trigger response:' "${OUT11}" || ok11=0
# "Outside the collapsed group" is a matter of line ORDER, not presence — the
# group's contents are in the log either way. Assert the status endpoint sits
# before ::endgroup:: and the run link after it.
endgroup_ln="$(grep -n '^::endgroup::' "${OUT11}" | tail -1 | cut -d: -f1)"
status_ln="$(grep -n '^status_api:' "${OUT11}" | tail -1 | cut -d: -f1)"
link_ln="$(grep -n '^Kifas run: ' "${OUT11}" | head -1 | cut -d: -f1)"
[[ -n "${endgroup_ln}" && -n "${status_ln}" && -n "${link_ln}" ]] || ok11=0
[[ -n "${status_ln}" && -n "${endgroup_ln}" && "${status_ln}" -lt "${endgroup_ln}" ]] || ok11=0
[[ -n "${link_ln}" && -n "${endgroup_ln}" && "${link_ln}" -gt "${endgroup_ln}" ]] || ok11=0
if [[ "${actual_exit}" -eq 0 && "${ok11}" -eq 1 ]]; then
  echo "  PASS  logs_dashboard_run_url"
  (( PASS++ )) || true
else
  echo "  FAIL  logs_dashboard_run_url  (exit=${actual_exit}; link not in the forefront slot)"
  (( FAIL++ )) || true
fi

# Case 12: a suite terminal status of "passed" gates green, and the report lines
# reach the step summary.
RESP12="${TMP_DIR}/responses_suite.txt"
cat > "${RESP12}" << 'EOF'
{"run_id":"50000000-0000-4000-8000-000000000012","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000012/status","run_url":"https://app.kifas.io/acme/web/suites/default/runs/50000000-0000-4000-8000-000000000012"}
{"status":"running","conclusion":null}
{"status":"passed","conclusion":"success","run_url":"https://app.kifas.io/acme/web/suites/default/runs/50000000-0000-4000-8000-000000000012","report":"✅ Checkout\n✅ Login","counts":{"total":2,"passed":2,"failed":0,"aborted":0,"skipped":0}}
EOF
SUMMARY12="${TMP_DIR}/summary12.md"
: > "${SUMMARY12}"
mock_curl12="${TMP_DIR}/curl_suite"
make_mock_curl "${mock_curl12}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl12}" \
  MOCK_CURL_RESPONSES_FILE="${RESP12}" \
  GITHUB_STEP_SUMMARY="${SUMMARY12}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 0 ]] && grep -q -- "- ✅ Checkout" "${SUMMARY12}" && grep -q -- "- ✅ Login" "${SUMMARY12}" && grep -q "2 passed, 0 failed of 2" "${SUMMARY12}"; then
  echo "  PASS  suite_passed_lists_report_lines"
  (( PASS++ )) || true
else
  echo "  FAIL  suite_passed_lists_report_lines  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 13: a failed suite lists the failing workflow's reason and gates red.
RESP13="${TMP_DIR}/responses_suite_fail.txt"
cat > "${RESP13}" << 'EOF'
{"run_id":"50000000-0000-4000-8000-000000000013","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000013/status"}
{"status":"failed","conclusion":"failure","report":"✅ Login\n❌ Checkout — button not found","counts":{"total":2,"passed":1,"failed":1,"aborted":0,"skipped":0}}
EOF
SUMMARY13="${TMP_DIR}/summary13.md"
: > "${SUMMARY13}"
mock_curl13="${TMP_DIR}/curl_suite_fail"
make_mock_curl "${mock_curl13}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl13}" \
  MOCK_CURL_RESPONSES_FILE="${RESP13}" \
  GITHUB_STEP_SUMMARY="${SUMMARY13}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 1 ]] && grep -q -- "- ❌ Checkout — button not found" "${SUMMARY13}"; then
  echo "  PASS  suite_failed_lists_failure_reason"
  (( PASS++ )) || true
else
  echo "  FAIL  suite_failed_lists_failure_reason  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 14: the suite input and multiline params reach the trigger payload as
# `suite` + a `params` JSON object (values keep their own '=' characters).
RESP14="${TMP_DIR}/responses_params.txt"
cat > "${RESP14}" << 'EOF'
{"run_id":"50000000-0000-4000-8000-000000000014","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000014/status"}
{"status":"passed","conclusion":"success"}
EOF
CALLS14="${TMP_DIR}/calls14.log"
: > "${CALLS14}"
mock_curl14="${TMP_DIR}/curl_params"
make_mock_curl "${mock_curl14}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl14}" \
  MOCK_CURL_RESPONSES_FILE="${RESP14}" \
  MOCK_CURL_CALLS_LOG="${CALLS14}" \
  KIFAS_SUITE="web/smoke" \
  KIFAS_PARAMS="$(printf 'locale=en-GB\n\n# a comment\ncoupon = A=B\n')" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
TRIGGER_CALL="$(tr -d '[:space:]' < "${CALLS14}")"
ok14=1
[[ "${actual_exit}" -eq 0 ]] || ok14=0
grep -q '"suite":"web/smoke"' <<< "${TRIGGER_CALL}" || ok14=0
grep -q '"locale":"en-GB"' <<< "${TRIGGER_CALL}" || ok14=0
grep -q '"coupon":"A=B"' <<< "${TRIGGER_CALL}" || ok14=0
! grep -q 'acomment' <<< "${TRIGGER_CALL}" || ok14=0
if [[ "${ok14}" -eq 1 ]]; then
  echo "  PASS  sends_suite_and_parsed_params"
  (( PASS++ )) || true
else
  echo "  FAIL  sends_suite_and_parsed_params  (exit=${actual_exit}) ${TRIGGER_CALL}"
  (( FAIL++ )) || true
fi

# Case 15: no params input → an empty params object, never a malformed payload.
RESP15="${TMP_DIR}/responses_noparams.txt"
cat > "${RESP15}" << 'EOF'
{"run_id":"50000000-0000-4000-8000-000000000015","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000015/status"}
{"status":"passed","conclusion":"success"}
EOF
CALLS15="${TMP_DIR}/calls15.log"
: > "${CALLS15}"
mock_curl15="${TMP_DIR}/curl_noparams"
make_mock_curl "${mock_curl15}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl15}" \
  MOCK_CURL_RESPONSES_FILE="${RESP15}" \
  MOCK_CURL_CALLS_LOG="${CALLS15}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
TRIGGER_CALL15="$(tr -d '[:space:]' < "${CALLS15}")"
ok15=1
[[ "${actual_exit}" -eq 0 ]] || ok15=0
grep -q '"params":{}' <<< "${TRIGGER_CALL15}" || ok15=0
! grep -q '"suite"' <<< "${TRIGGER_CALL15}" || ok15=0
if [[ "${ok15}" -eq 1 ]]; then
  echo "  PASS  empty_params_and_no_suite_key"
  (( PASS++ )) || true
else
  echo "  FAIL  empty_params_and_no_suite_key  (exit=${actual_exit}) ${TRIGGER_CALL15}"
  (( FAIL++ )) || true
fi

# Case 16: an app artifact URL is forwarded to /v1/github/runs without uploading.
RESP16="${TMP_DIR}/responses_artifact_url.txt"
cat > "${RESP16}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000016","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000016/status"}
{"status":"completed","conclusion":"success"}
EOF
CALLS16="${TMP_DIR}/calls16.log"
OUT16="${TMP_DIR}/out16.log"
: > "${CALLS16}"
mock_curl16="${TMP_DIR}/curl_artifact_url"
make_mock_curl "${mock_curl16}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl16}" \
  MOCK_CURL_RESPONSES_FILE="${RESP16}" \
  MOCK_CURL_CALLS_LOG="${CALLS16}" \
  KIFAS_APP_ARTIFACT="https://builds.example.com/app-release.apk?sig=abc" \
  GITHUB_REPOSITORY="acme/my-app" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >"${OUT16}" 2>&1 || actual_exit=$?
ok16=1
[[ "${actual_exit}" -eq 0 ]] || ok16=0
! grep -q '/v1/app-builds/upload' "${CALLS16}" || ok16=0
grep -q 'https://builds.example.com/app-release.apk?sig=abc' "${CALLS16}" || ok16=0
grep -q '^app_build:   url$' "${OUT16}" || ok16=0
! grep -v '^::add-mask::' "${OUT16}" | grep -q 'sig=abc' || ok16=0
grep -qx '::add-mask::https://builds.example.com/app-release.apk?sig=abc' "${OUT16}" || ok16=0
if [[ "${ok16}" -eq 1 ]]; then
  echo "  PASS  forwards_artifact_url_without_upload"
  (( PASS++ )) || true
else
  echo "  FAIL  forwards_artifact_url_without_upload  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# ---------------------------------------------------------------------------
# Merge-gate (managed) calls: gate-id + a fresh GitHub OIDC token per call.
# ---------------------------------------------------------------------------
EVENT_FILE="${TMP_DIR}/event.json"
cat > "${EVENT_FILE}" << 'EOF_EVENT'
{"pull_request":{"number":42,"head":{"sha":"1111111111111111111111111111111111111111"}}}
EOF_EVENT

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [[ "${ok}" -eq 1 ]]; then
    echo "  PASS  ${name}"
    (( PASS++ )) || true
  else
    echo "  FAIL  ${name}  ${detail}"
    (( FAIL++ )) || true
  fi
}

# run_managed <name> <responses> [extra env...] — sets M_EXIT, M_OUT, M_CALLS, M_OUTPUTS
run_managed() {
  local name="$1" responses="$2"
  shift 2
  M_OUT="${TMP_DIR}/${name}.out"
  M_CALLS="${TMP_DIR}/${name}.calls"
  M_OUTPUTS="${TMP_DIR}/${name}.outputs"
  : > "${M_CALLS}"
  : > "${M_OUTPUTS}"
  local mock="${TMP_DIR}/curl_${name}"
  make_mock_curl "${mock}"
  M_EXIT=0
  env \
    KIFAS_API_KEY="kifas_test_gatekey" \
    KIFAS_GATE_ID="019f0000-0000-7000-8000-00000000abcd" \
    KIFAS_SUITE="44444444-4444-4444-8444-444444444444" \
    KIFAS_API_BASE="https://mock.kifas.io" \
    KIFAS_POLL_INTERVAL_S="0" \
    KIFAS_TIMEOUT_S="60" \
    KIFAS_RETRY_DELAY_S="0" \
    KIFAS_CURL="${mock}" \
    MOCK_CURL_RESPONSES_FILE="${responses}" \
    MOCK_CURL_CALLS_LOG="${M_CALLS}" \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://token.mock/request?api-version=2.0" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
    GITHUB_OUTPUT="${M_OUTPUTS}" \
    GITHUB_REPOSITORY="acme/web" \
    GITHUB_REPOSITORY_ID="4242" \
    GITHUB_SHA="2222222222222222222222222222222222222222" \
    GITHUB_REF_NAME="42/merge" \
    GITHUB_REF="refs/pull/42/merge" \
    GITHUB_RUN_ID="9001" \
    GITHUB_RUN_ATTEMPT="2" \
    GITHUB_EVENT_NAME="pull_request" \
    GITHUB_EVENT_PATH="${EVENT_FILE}" \
    GITHUB_WORKFLOW_REF="acme/web/.github/workflows/preview.yml@refs/pull/42/merge" \
    GITHUB_WORKFLOW_SHA="2222222222222222222222222222222222222222" \
    "$@" \
    bash "${RUN_SH}" > "${M_OUT}" 2>&1 || M_EXIT=$?
}

# Case 17: a managed web run sends the gate id, the identity token and the
# full Actions context, and sets both outputs from the terminal result.
R17="${TMP_DIR}/r17.txt"
cat > "${R17}" << 'EOF_R'
{"value":"oidc.jwt.one"}
{"run_id":"50000000-0000-4000-8000-000000000017","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000017/status"}
{"status":"running","conclusion":null}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_web "${R17}" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
grep -q 'token.mock/request?api-version=2.0&audience=kifas-github-gate' "${M_CALLS}" || ok=0
TRIG="$(tr -d '[:space:]' < "${M_CALLS}")"
grep -q 'X-Kifas-Github-OIDC:oidc.jwt.one' <<< "${TRIG}" || ok=0
grep -q '"gate_id":"019f0000-0000-7000-8000-00000000abcd"' <<< "${TRIG}" || ok=0
grep -q '"run_attempt":2' <<< "${TRIG}" || ok=0
grep -q '"repository_id":4242' <<< "${TRIG}" || ok=0
grep -q '"head_sha":"1111111111111111111111111111111111111111"' <<< "${TRIG}" || ok=0
grep -q '"tested_sha":"2222222222222222222222222222222222222222"' <<< "${TRIG}" || ok=0
grep -q '"event":"pull_request"' <<< "${TRIG}" || ok=0
grep -q '"workflow_ref":"acme/web/.github/workflows/preview.yml@refs/pull/42/merge"' <<< "${TRIG}" || ok=0
grep -qx 'suite-run-id=50000000-0000-4000-8000-000000000017' "${M_OUTPUTS}" || ok=0
grep -qx 'suite-result=passed' "${M_OUTPUTS}" || ok=0
grep -qx '::add-mask::oidc.jwt.one' "${M_OUT}" || ok=0
[[ "$(grep -c 'oidc.jwt.one' "${M_OUT}")" -eq 1 ]] || ok=0
check managed_web_sends_identity_and_sets_outputs "${ok}" "(exit=${M_EXIT})"

# Case 18: a failed suite gates red and reports suite-result=failed.
R18="${TMP_DIR}/r18.txt"
cat > "${R18}" << 'EOF_R'
{"value":"oidc.jwt"}
{"run_id":"50000000-0000-4000-8000-000000000018","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000018/status"}
{"status":"failed","conclusion":"failure"}
EOF_R
run_managed managed_failed "${R18}" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 1 ]] || ok=0
grep -qx 'suite-run-id=50000000-0000-4000-8000-000000000018' "${M_OUTPUTS}" || ok=0
grep -qx 'suite-result=failed' "${M_OUTPUTS}" || ok=0
check managed_failed_suite_exits_1_with_failed_result "${ok}" "(exit=${M_EXIT})"

# Case 19: without id-token permission a managed call stops before reaching
# Kifas, with no outputs.
R19="${TMP_DIR}/r19.txt"
: > "${R19}"
run_managed managed_no_identity "${R19}" KIFAS_TARGET_URL="https://pr-42.preview.example.com" \
  ACTIONS_ID_TOKEN_REQUEST_URL="" ACTIONS_ID_TOKEN_REQUEST_TOKEN=""
ok=1
[[ "${M_EXIT}" -eq 1 ]] || ok=0
! grep -q 'mock.kifas.io' "${M_CALLS}" || ok=0
[[ ! -s "${M_OUTPUTS}" ]] || ok=0
grep -q "id-token: write" "${M_OUT}" || ok=0
check managed_without_id_token_permission_fails_before_kifas "${ok}" "(exit=${M_EXIT})"

# Case 20: a lost answer is retried with a fresh token and the same payload;
# the reservation makes the retry safe.
R20="${TMP_DIR}/r20.txt"
cat > "${R20}" << 'EOF_R'
{"value":"oidc.first"}
!28
{"value":"oidc.second"}
@502 {"error":{"code":"orchestrator_unavailable","message":"could not contact orchestrator"}}
{"value":"oidc.third"}
{"run_id":"50000000-0000-4000-8000-000000000020","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000020/status"}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_retry "${R20}" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
[[ "$(grep -c 'mock.kifas.io/v1/github/runs {' "${M_CALLS}")" -eq 3 ]] || ok=0
[[ "$(grep -c '"gate_id": "019f0000-0000-7000-8000-00000000abcd"' "${M_CALLS}")" -eq 3 ]] || ok=0
[[ "$(grep -c '"run_attempt": 2,' "${M_CALLS}")" -eq 3 ]] || ok=0
grep -q 'X-Kifas-Github-OIDC: oidc.third' "${M_CALLS}" || ok=0
grep -qx 'suite-result=passed' "${M_OUTPUTS}" || ok=0
check managed_retries_lost_answers_with_fresh_token "${ok}" "(exit=${M_EXIT})"

# Case 21: a refusal (4xx) is final: one call, no outputs, exit 1.
R21="${TMP_DIR}/r21.txt"
cat > "${R21}" << 'EOF_R'
{"value":"oidc.jwt"}
@403 {"error":{"code":"github_context_mismatch","message":"The run did not build the head revision in the request."}}
EOF_R
run_managed managed_refused "${R21}" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 1 ]] || ok=0
[[ "$(grep -c 'mock.kifas.io/v1/github/runs {' "${M_CALLS}")" -eq 1 ]] || ok=0
[[ ! -s "${M_OUTPUTS}" ]] || ok=0
grep -q 'did not build the head revision' "${M_OUT}" || ok=0
check managed_refusal_is_final_and_sets_no_result "${ok}" "(exit=${M_EXIT})"

# Case 22: a managed build file is uploaded with the gate id, the identity and
# the context, then triggered by the build id it got back.
A22="${TMP_DIR}/app22.apk"
echo "dummy" > "${A22}"
R22="${TMP_DIR}/r22.txt"
cat > "${R22}" << 'EOF_R'
{"value":"oidc.upload"}
{"app_build_id":"0d0d0d0d-0000-4000-8000-000000000001"}
{"value":"oidc.trigger"}
{"run_id":"50000000-0000-4000-8000-000000000022","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000022/status"}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_upload "${R22}" KIFAS_APP_ARTIFACT="${A22}"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
UP="$(grep '/v1/app-builds/upload' "${M_CALLS}")"
grep -q 'X-Kifas-Github-OIDC: oidc.upload' <<< "${UP}" || ok=0
grep -q -- '--form-string gate_id=019f0000-0000-7000-8000-00000000abcd' <<< "${UP}" || ok=0
grep -q -- '--form-string run_attempt=2' <<< "${UP}" || ok=0
grep -q -- '--form-string workflow_ref=acme/web/.github/workflows/preview.yml@refs/pull/42/merge' <<< "${UP}" || ok=0
grep -q -- "-F file=@${A22}" <<< "${UP}" || ok=0
TRIG22="$(tr -d '[:space:]' < "${M_CALLS}")"
grep -q '"app_artifact":"0d0d0d0d-0000-4000-8000-000000000001"' <<< "${TRIG22}" || ok=0
grep -q 'X-Kifas-Github-OIDC:oidc.trigger' <<< "${TRIG22}" || ok=0
check managed_upload_carries_identity_then_triggers_by_build_id "${ok}" "(exit=${M_EXIT})"

# Case 23: a signed build address is masked (and its query on its own) and
# never printed anywhere else.
R23="${TMP_DIR}/r23.txt"
cat > "${R23}" << 'EOF_R'
{"value":"oidc.jwt"}
{"run_id":"50000000-0000-4000-8000-000000000023","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000023/status"}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_signed_url "${R23}" \
  KIFAS_APP_ARTIFACT="https://builds.example.com/app.apk?X-Amz-Signature=s3cr3tsig&X-Amz-Expires=300"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
grep -qx '::add-mask::https://builds.example.com/app.apk?X-Amz-Signature=s3cr3tsig&X-Amz-Expires=300' "${M_OUT}" || ok=0
grep -qx '::add-mask::X-Amz-Signature=s3cr3tsig&X-Amz-Expires=300' "${M_OUT}" || ok=0
[[ "$(grep -c 's3cr3tsig' "${M_OUT}")" -eq 2 ]] || ok=0
grep -q '^App artifact URL will be fetched by Kifas: https://builds.example.com/app.apk$' "${M_OUT}" || ok=0
check managed_signed_url_is_masked_and_never_logged "${ok}" "(exit=${M_EXIT})"

# Case 24: a timeout reaches no terminal result: exit 1, the run id is known,
# suite-result is never written.
R24="${TMP_DIR}/r24.txt"
cat > "${R24}" << 'EOF_R'
{"value":"oidc.jwt"}
{"run_id":"50000000-0000-4000-8000-000000000024","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000024/status"}
{"status":"running","conclusion":null}
EOF_R
run_managed managed_timeout "${R24}" KIFAS_TARGET_URL="https://pr-42.preview.example.com" KIFAS_TIMEOUT_S="0"
ok=1
[[ "${M_EXIT}" -eq 1 ]] || ok=0
grep -qx 'suite-run-id=50000000-0000-4000-8000-000000000024' "${M_OUTPUTS}" || ok=0
! grep -q 'suite-result' "${M_OUTPUTS}" || ok=0
grep -q 'timed out' "${M_OUT}" || ok=0
check timeout_sets_no_result_and_fails "${ok}" "(exit=${M_EXIT})"

# Case 25: a cancelled job (SIGTERM mid-poll) exits non-zero and leaves no
# result, so the required check cannot read a pass.
R25="${TMP_DIR}/r25.txt"
{
  echo '{"value":"oidc.jwt"}'
  echo '{"run_id":"50000000-0000-4000-8000-000000000025","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000025/status"}'
  for _ in $(seq 1 400); do echo '{"status":"running","conclusion":null}'; done
} > "${R25}"
M_OUTPUTS25="${TMP_DIR}/cancel.outputs"
: > "${M_OUTPUTS25}"
mock25="${TMP_DIR}/curl_cancel"
make_mock_curl "${mock25}"
env \
  KIFAS_API_KEY="kifas_test_gatekey" \
  KIFAS_GATE_ID="019f0000-0000-7000-8000-00000000abcd" \
  KIFAS_TARGET_URL="https://pr-42.preview.example.com" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0.2" \
  KIFAS_TIMEOUT_S="120" \
  KIFAS_CURL="${mock25}" \
  MOCK_CURL_RESPONSES_FILE="${R25}" \
  ACTIONS_ID_TOKEN_REQUEST_URL="https://token.mock/request?api-version=2.0" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN="request-token" \
  GITHUB_OUTPUT="${M_OUTPUTS25}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_REPOSITORY_ID="4242" \
  GITHUB_SHA="2222222222222222222222222222222222222222" \
  GITHUB_REF="refs/pull/42/merge" \
  GITHUB_RUN_ID="9001" \
  GITHUB_EVENT_NAME="pull_request" \
  bash "${RUN_SH}" > "${TMP_DIR}/cancel.out" 2>&1 &
PID25=$!
for _ in $(seq 1 100); do
  grep -q 'suite-run-id=50000000-0000-4000-8000-000000000025' "${M_OUTPUTS25}" 2>/dev/null && break
  sleep 0.1
done
sleep 0.5
kill -TERM "${PID25}" 2>/dev/null || true
E25=0
wait "${PID25}" || E25=$?
ok=1
[[ "${E25}" -ne 0 ]] || ok=0
grep -qx 'suite-run-id=50000000-0000-4000-8000-000000000025' "${M_OUTPUTS25}" || ok=0
! grep -q 'suite-result' "${M_OUTPUTS25}" || ok=0
grep -q 'cancelled' "${TMP_DIR}/cancel.out" || ok=0
check cancelled_job_exits_nonzero_without_result "${ok}" "(exit=${E25})"

# Case 26: an ordinary key (no gate-id) keeps the legacy call — no identity
# token is requested — and still reports its outputs.
R26="${TMP_DIR}/r26.txt"
cat > "${R26}" << 'EOF_R'
{"run_id":"00000000-0000-4000-8000-000000000026","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000026/status"}
{"status":"completed","conclusion":"success"}
EOF_R
run_managed legacy_outputs "${R26}" KIFAS_GATE_ID="" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
! grep -q 'token.mock' "${M_CALLS}" || ok=0
! grep -q 'X-Kifas-Github-OIDC' "${M_CALLS}" || ok=0
! grep -q 'gate_id' "${M_CALLS}" || ok=0
grep -qx 'suite-run-id=00000000-0000-4000-8000-000000000026' "${M_OUTPUTS}" || ok=0
grep -qx 'suite-result=passed' "${M_OUTPUTS}" || ok=0
check legacy_key_sends_no_identity_and_sets_outputs "${ok}" "(exit=${M_EXIT})"

# Case 27: a run id that is not a UUID is refused before it can become an
# output — a newline in it would otherwise write outputs of its own.
R27="${TMP_DIR}/r27.txt"
cat > "${R27}" << 'EOF_R'
{"value":"oidc.jwt"}
{"run_id":"x\nsuite-result=passed","poll_url":"/v1/github/runs/x/status"}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_bad_run_id "${R27}" KIFAS_TARGET_URL="https://pr-42.preview.example.com"
ok=1
[[ "${M_EXIT}" -eq 1 ]] || ok=0
! grep -q 'suite-result' "${M_OUTPUTS}" || ok=0
! grep -q 'suite-run-id' "${M_OUTPUTS}" || ok=0
check run_id_that_is_not_a_uuid_is_refused "${ok}" "(exit=${M_EXIT})"

# Case 28: a preview address with a protection token is masked (whole, and its
# query alone) and logged without the query; the trigger still sends it whole.
R28="${TMP_DIR}/r28.txt"
cat > "${R28}" << 'EOF_R'
{"value":"oidc.jwt"}
{"run_id":"50000000-0000-4000-8000-000000000028","poll_url":"/v1/github/runs/50000000-0000-4000-8000-000000000028/status"}
{"status":"passed","conclusion":"success"}
EOF_R
run_managed managed_token_url "${R28}" \
  KIFAS_TARGET_URL="https://pr-42.preview.example.com/?x-vercel-protection-bypass=byp4ss"
ok=1
[[ "${M_EXIT}" -eq 0 ]] || ok=0
grep -qx '::add-mask::https://pr-42.preview.example.com/?x-vercel-protection-bypass=byp4ss' "${M_OUT}" || ok=0
grep -qx '::add-mask::x-vercel-protection-bypass=byp4ss' "${M_OUT}" || ok=0
[[ "$(grep -c 'byp4ss' "${M_OUT}")" -eq 2 ]] || ok=0
grep -qx 'target_url:  https://pr-42.preview.example.com/' "${M_OUT}" || ok=0
grep -q 'x-vercel-protection-bypass=byp4ss' "${M_CALLS}" || ok=0
check tokenized_target_url_is_masked_and_sent_whole "${ok}" "(exit=${M_EXIT})"

# Case 29: a run that ends `action_required` gates red and says why — in the
# log, the ::error:: line and the step summary.
RESP17="${TMP_DIR}/responses_action_required.txt"
cat > "${RESP17}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000029","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000029/status"}
{"status":"completed","conclusion":"action_required","reason":"The test this run built needs a person to review its result before it is published."}
EOF
SUMMARY17="${TMP_DIR}/summary17.md"
: > "${SUMMARY17}"
OUT17="${TMP_DIR}/out17.txt"
mock_curl17="${TMP_DIR}/curl_action_required"
make_mock_curl "${mock_curl17}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl17}" \
  MOCK_CURL_RESPONSES_FILE="${RESP17}" \
  GITHUB_STEP_SUMMARY="${SUMMARY17}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >"${OUT17}" 2>&1 || actual_exit=$?
ok17=1
[[ "${actual_exit}" -eq 1 ]] || ok17=0
grep -q '^Reason: The test this run built needs a person to review' "${OUT17}" || ok17=0
grep -q '::error::Kifas gate FAILED — run_id=00000000-0000-4000-8000-000000000029 conclusion=action_required — The test this run built needs a person' "${OUT17}" || ok17=0
grep -q '\*\*Why:\*\* The test this run built needs a person to review' "${SUMMARY17}" || ok17=0
if [[ "${ok17}" -eq 1 ]]; then
  echo "  PASS  action_required_prints_reason"
  (( PASS++ )) || true
else
  echo "  FAIL  action_required_prints_reason  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 30: a failure with no reason keeps the old ::error:: line exactly.
RESP18="${TMP_DIR}/responses_no_reason.txt"
cat > "${RESP18}" << 'EOF'
{"run_id":"00000000-0000-4000-8000-000000000030","poll_url":"/v1/github/runs/00000000-0000-4000-8000-000000000030/status"}
{"status":"completed","conclusion":"failure"}
EOF
OUT18="${TMP_DIR}/out18.txt"
mock_curl18="${TMP_DIR}/curl_no_reason"
make_mock_curl "${mock_curl18}"
actual_exit=0
env \
  KIFAS_API_KEY="test-key-123" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_POLL_INTERVAL_S="0" \
  KIFAS_TIMEOUT_S="60" \
  KIFAS_CURL="${mock_curl18}" \
  MOCK_CURL_RESPONSES_FILE="${RESP18}" \
  GITHUB_REPOSITORY="acme/web" \
  GITHUB_SHA="abc123def456" \
  GITHUB_REF_NAME="main" \
  GITHUB_RUN_ID="99" \
  GITHUB_REF="refs/heads/main" \
  bash "${RUN_SH}" >"${OUT18}" 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 1 ]] && grep -qx '::error::Kifas gate FAILED — run_id=00000000-0000-4000-8000-000000000030 conclusion=failure' "${OUT18}" && ! grep -q '^Reason:' "${OUT18}"; then
  echo "  PASS  failure_without_reason_unchanged"
  (( PASS++ )) || true
else
  echo "  FAIL  failure_without_reason_unchanged  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
