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
set -euo pipefail
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
