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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# Mock curl: pops one response per invocation from MOCK_CURL_RESPONSES_FILE
# and logs the full arg list (never the secret, since run.sh never puts the
# key on argv) to MOCK_CURL_CALLS_LOG. Exhausting the responses file simulates
# a transport failure (non-zero exit).
#
# Each response line is either `BODY` (implicitly HTTP 200) or
# `STATUS<TAB>BODY`. Like real curl, the body is written to the --output file
# and the status is printed on stdout for --write-out '%{http_code}'.
# ---------------------------------------------------------------------------
make_mock_curl() {
  local mock_file="$1"
  cat > "${mock_file}" << 'MOCK_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
BODY=""
OUT=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--data" ]]; then
    j=$((i + 1))
    BODY="${!j}"
  fi
  if [[ "${!i}" == "--output" ]]; then
    j=$((i + 1))
    OUT="${!j}"
  fi
done
if [[ -n "${MOCK_CURL_CALLS_LOG:-}" ]]; then
  printf '%s %s\n' "$*" "${BODY}" >> "${MOCK_CURL_CALLS_LOG}"
fi
RESP_FILE="${MOCK_CURL_RESPONSES_FILE:?}"
if [[ ! -f "${RESP_FILE}" ]]; then
  echo 'mock exhausted' >&2
  exit 1
fi
LINE=""
REST=()
while IFS= read -r l; do
  if [[ -z "${LINE}" && -n "${l}" ]]; then
    LINE="${l}"
  elif [[ -n "${l}" ]]; then
    REST+=("${l}")
  fi
done < "${RESP_FILE}"
if [[ -z "${LINE}" ]]; then
  echo 'mock exhausted' >&2
  exit 1
fi
printf '%s\n' "${REST[@]:-}" > "${RESP_FILE}"
STATUS="200"
RESPONSE_BODY="${LINE}"
if [[ "${LINE}" == *$'\t'* ]]; then
  STATUS="${LINE%%$'\t'*}"
  RESPONSE_BODY="${LINE#*$'\t'}"
fi
if [[ -n "${OUT}" ]]; then
  printf '%s' "${RESPONSE_BODY}" > "${OUT}"
  printf '%s' "${STATUS}"
else
  printf '%s\n' "${RESPONSE_BODY}"
fi
MOCK_SCRIPT
  chmod +x "${mock_file}"
}

run_case() {
  local name="$1" responses_file="$2" expected_exit="$3"
  shift 3
  local extra_env=("$@")
  local mock_curl="${TMP_DIR}/curl_${name}"
  make_mock_curl "${mock_curl}"

  local app="${TMP_DIR}/app_${name}.apk"
  echo "dummy" > "${app}"

  local actual_exit=0
  env -i PATH="${PATH}" \
    KIFAS_API_KEY="test-secret-key-999" \
    KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
    KIFAS_SUITE_NAME="smoke" \
    KIFAS_BUILD_NAME="build-42" \
    KIFAS_BUILD_ID="ext-key-42" \
    KIFAS_APP_PATH="${app}" \
    KIFAS_TEST_COMMAND="true" \
    KIFAS_API_BASE="https://mock.kifas.io" \
    KIFAS_CURL="${mock_curl}" \
    MOCK_CURL_RESPONSES_FILE="${responses_file}" \
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

echo "Running run.sh tests..."
echo ""

# Case 1: APK upload + build open/close + successful test command -> exit 0.
RESP1="${TMP_DIR}/resp1.txt"
cat > "${RESP1}" << 'EOF'
{"app_build_id":"appbuild-1","build_uri":"kifas://build/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
{"suiteRunId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","suiteRunUrl":"https://app.kifas.io/acme/web/smoke/runs/bbbbbbbb"}
{"suiteRunId":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","closeRequested":true}
EOF
run_case "apk_success" "${RESP1}" 0

# Case 2: IPA upload works identically to APK — the action never branches on
# extension, it just uploads the file at KIFAS_APP_PATH.
RESP2="${TMP_DIR}/resp2.txt"
cat > "${RESP2}" << 'EOF'
{"app_build_id":"appbuild-2","build_uri":"kifas://build/cccccccc-cccc-cccc-cccc-cccccccccccc"}
{"suiteRunId":"dddddddd-dddd-dddd-dddd-dddddddddddd","suiteRunUrl":"https://app.kifas.io/acme/web/smoke/runs/dddddddd"}
{"suiteRunId":"dddddddd-dddd-dddd-dddd-dddddddddddd","closeRequested":true}
EOF
IPA="${TMP_DIR}/app2.ipa"
echo "dummy" > "${IPA}"
mock_ipa="${TMP_DIR}/curl_ipa"
make_mock_curl "${mock_ipa}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${IPA}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock_ipa}" \
  MOCK_CURL_RESPONSES_FILE="${RESP2}" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
if [[ "${actual_exit}" -eq 0 ]]; then
  echo "  PASS  ipa_success"
  (( PASS++ )) || true
else
  echo "  FAIL  ipa_success  (expected exit 0, got ${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 3: build open + build close happen, in that order, before/after the
# test command — assert call order via the calls log.
RESP3="${TMP_DIR}/resp3.txt"
cat > "${RESP3}" << 'EOF'
{"app_build_id":"appbuild-3","build_uri":"kifas://build/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"}
{"suiteRunId":"ffffffff-ffff-ffff-ffff-ffffffffffff","suiteRunUrl":"https://app.kifas.io/acme/web/smoke/runs/ffffffff"}
{"suiteRunId":"ffffffff-ffff-ffff-ffff-ffffffffffff","closeRequested":true}
EOF
CALLS3="${TMP_DIR}/calls3.log"
: > "${CALLS3}"
mock3="${TMP_DIR}/curl_order"
make_mock_curl "${mock3}"
app3="${TMP_DIR}/app3.apk"
echo dummy > "${app3}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app3}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock3}" \
  MOCK_CURL_RESPONSES_FILE="${RESP3}" \
  MOCK_CURL_CALLS_LOG="${CALLS3}" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
upload_ln="$(grep -n '/v1/app-builds/upload' "${CALLS3}" | head -1 | cut -d: -f1 || true)"
open_ln="$(grep -n '/v1/remote-webdriver/builds ' "${CALLS3}" | head -1 | cut -d: -f1 || true)"
close_ln="$(grep -n '/close' "${CALLS3}" | head -1 | cut -d: -f1 || true)"
if [[ "${actual_exit}" -eq 0 && -n "${upload_ln}" && -n "${open_ln}" && -n "${close_ln}" \
      && "${upload_ln}" -lt "${open_ln}" && "${open_ln}" -lt "${close_ln}" ]]; then
  echo "  PASS  upload_open_close_in_order"
  (( PASS++ )) || true
else
  echo "  FAIL  upload_open_close_in_order  (exit=${actual_exit} upload=${upload_ln:-<none>} open=${open_ln:-<none>} close=${close_ln:-<none>})"
  (( FAIL++ )) || true
fi

# Case 4: the customer's test command fails -> the action exits with that
# same non-zero code (build close is still attempted).
RESP4="${TMP_DIR}/resp4.txt"
cat > "${RESP4}" << 'EOF'
{"app_build_id":"appbuild-4","build_uri":"kifas://build/11110000-0000-0000-0000-000000000000"}
{"suiteRunId":"22220000-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/2222"}
{"suiteRunId":"22220000-0000-0000-0000-000000000000","closeRequested":true}
EOF
CALLS4="${TMP_DIR}/calls4.log"
: > "${CALLS4}"
run_case "test_command_failure" "${RESP4}" 7 "KIFAS_TEST_COMMAND=exit 7" "MOCK_CURL_CALLS_LOG=${CALLS4}"
if grep -q '/close' "${CALLS4}"; then
  echo "  PASS  close_attempted_after_test_failure"
  (( PASS++ )) || true
else
  echo "  FAIL  close_attempted_after_test_failure"
  (( FAIL++ )) || true
fi

# Case 5: the action receives SIGTERM while the test command is running ->
# it exits 143 and still attempts the build close.
RESP5="${TMP_DIR}/resp5.txt"
cat > "${RESP5}" << 'EOF'
{"app_build_id":"appbuild-5","build_uri":"kifas://build/33330000-0000-0000-0000-000000000000"}
{"suiteRunId":"44440000-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/4444"}
{"suiteRunId":"44440000-0000-0000-0000-000000000000","closeRequested":true}
EOF
CALLS5="${TMP_DIR}/calls5.log"
: > "${CALLS5}"
mock5="${TMP_DIR}/curl_signal"
make_mock_curl "${mock5}"
app5="${TMP_DIR}/app5.apk"
echo dummy > "${app5}"
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app5}" \
  KIFAS_TEST_COMMAND="sleep 30" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock5}" \
  MOCK_CURL_RESPONSES_FILE="${RESP5}" \
  MOCK_CURL_CALLS_LOG="${CALLS5}" \
  bash "${RUN_SH}" >/dev/null 2>&1 &
run_pid=$!
# Wait for the test command's own sleep to actually be running before killing.
for _ in $(seq 1 50); do
  if pgrep -P "${run_pid}" -f 'sleep 30' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
kill -TERM "${run_pid}" 2>/dev/null || true
set +e
wait "${run_pid}" 2>/dev/null
actual_exit=$?
set -e
if [[ "${actual_exit}" -eq 143 ]] && grep -q '/close' "${CALLS5}"; then
  echo "  PASS  signal_term_exits_143_and_closes"
  (( PASS++ )) || true
else
  echo "  FAIL  signal_term_exits_143_and_closes  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 6: the app upload fails (mock responses exhausted before the upload
# call gets a line) -> the action fails loudly before ever opening a build.
RESP6="${TMP_DIR}/resp6.txt"
: > "${RESP6}"
CALLS6="${TMP_DIR}/calls6.log"
: > "${CALLS6}"
run_case "upload_failure" "${RESP6}" 1 "MOCK_CURL_CALLS_LOG=${CALLS6}"
if ! grep -q '/v1/remote-webdriver/builds' "${CALLS6}"; then
  echo "  PASS  upload_failure_never_opens_build"
  (( PASS++ )) || true
else
  echo "  FAIL  upload_failure_never_opens_build"
  (( FAIL++ )) || true
fi

# Case 7: build close fails, but the test command already succeeded -> the
# action still exits 0, and it warns (by suite run id) that the close failed
# rather than staying silent about it.
RESP7="${TMP_DIR}/resp7.txt"
cat > "${RESP7}" << 'EOF'
{"app_build_id":"appbuild-7","build_uri":"kifas://build/55550000-0000-0000-0000-000000000000"}
{"suiteRunId":"66660000-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/6666"}
EOF
OUT7="${TMP_DIR}/out7.log"
mock7="${TMP_DIR}/curl_close_fail_success"
make_mock_curl "${mock7}"
app7="${TMP_DIR}/app7.apk"
echo dummy > "${app7}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app7}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock7}" \
  MOCK_CURL_RESPONSES_FILE="${RESP7}" \
  bash "${RUN_SH}" > "${OUT7}" 2>&1 || actual_exit=$?
ok7=1
[[ "${actual_exit}" -eq 0 ]] || ok7=0
grep -q '^::warning::failed to close Kifas suite build 66660000-0000-0000-0000-000000000000$' "${OUT7}" || ok7=0
if [[ "${ok7}" -eq 1 ]]; then
  echo "  PASS  close_failure_does_not_mask_success"
  (( PASS++ )) || true
else
  echo "  FAIL  close_failure_does_not_mask_success  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 8: build close fails AND the test command failed -> the action still
# reports the test's own exit code (not a close-related one) and still warns
# that the close itself failed.
RESP8="${TMP_DIR}/resp8.txt"
cat > "${RESP8}" << 'EOF'
{"app_build_id":"appbuild-8","build_uri":"kifas://build/77770000-0000-0000-0000-000000000000"}
{"suiteRunId":"88880000-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/8888"}
EOF
OUT8="${TMP_DIR}/out8.log"
mock8="${TMP_DIR}/curl_close_fail_test_fail"
make_mock_curl "${mock8}"
app8="${TMP_DIR}/app8.apk"
echo dummy > "${app8}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app8}" \
  KIFAS_TEST_COMMAND="exit 5" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock8}" \
  MOCK_CURL_RESPONSES_FILE="${RESP8}" \
  bash "${RUN_SH}" > "${OUT8}" 2>&1 || actual_exit=$?
ok8=1
[[ "${actual_exit}" -eq 5 ]] || ok8=0
grep -q '^::warning::failed to close Kifas suite build 88880000-0000-0000-0000-000000000000$' "${OUT8}" || ok8=0
if [[ "${ok8}" -eq 1 ]]; then
  echo "  PASS  close_failure_preserves_test_failure_code"
  (( PASS++ )) || true
else
  echo "  FAIL  close_failure_preserves_test_failure_code  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 9: the suite run URL reaches the log as a top-level line, a ::notice::
# annotation, and the step summary.
RESP9="${TMP_DIR}/resp9.txt"
cat > "${RESP9}" << 'EOF'
{"app_build_id":"appbuild-9","build_uri":"kifas://build/99990000-0000-0000-0000-000000000000"}
{"suiteRunId":"12120000-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/acme/web/smoke/runs/1212"}
{"suiteRunId":"12120000-0000-0000-0000-000000000000","closeRequested":true}
EOF
OUT9="${TMP_DIR}/out9.log"
SUMMARY9="${TMP_DIR}/summary9.md"
: > "${SUMMARY9}"
mock9="${TMP_DIR}/curl_url"
make_mock_curl "${mock9}"
app9="${TMP_DIR}/app9.apk"
echo dummy > "${app9}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app9}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock9}" \
  MOCK_CURL_RESPONSES_FILE="${RESP9}" \
  GITHUB_STEP_SUMMARY="${SUMMARY9}" \
  bash "${RUN_SH}" > "${OUT9}" 2>&1 || actual_exit=$?
ok9=1
[[ "${actual_exit}" -eq 0 ]] || ok9=0
grep -q '^Kifas suite run: https://app.kifas.io/acme/web/smoke/runs/1212$' "${OUT9}" || ok9=0
grep -q '^::notice title=Kifas suite run::https://app.kifas.io/acme/web/smoke/runs/1212$' "${OUT9}" || ok9=0
grep -q 'https://app.kifas.io/acme/web/smoke/runs/1212' "${SUMMARY9}" || ok9=0
if [[ "${ok9}" -eq 1 ]]; then
  echo "  PASS  url_summary"
  (( PASS++ )) || true
else
  echo "  FAIL  url_summary  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 10: the API key is never printed except through the GitHub mask
# directive, never appears on any curl command line (it travels via a header
# config file, not argv), and is not exposed even when the script is traced
# with `bash -x`.
RESP10="${TMP_DIR}/resp10.txt"
cat > "${RESP10}" << 'EOF'
{"app_build_id":"appbuild-10","build_uri":"kifas://build/00001111-0000-0000-0000-000000000000"}
{"suiteRunId":"00002222-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/0000"}
{"suiteRunId":"00002222-0000-0000-0000-000000000000","closeRequested":true}
EOF
CALLS10="${TMP_DIR}/calls10.log"
: > "${CALLS10}"
OUT10="${TMP_DIR}/out10.log"
mock10="${TMP_DIR}/curl_mask"
make_mock_curl "${mock10}"
app10="${TMP_DIR}/app10.apk"
echo dummy > "${app10}"
SECRET="super-secret-mask-me-9000"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="${SECRET}" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app10}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock10}" \
  MOCK_CURL_RESPONSES_FILE="${RESP10}" \
  MOCK_CURL_CALLS_LOG="${CALLS10}" \
  bash -x "${RUN_SH}" > "${OUT10}" 2>&1 || actual_exit=$?
ok10=1
[[ "${actual_exit}" -eq 0 ]] || ok10=0
grep -q "^::add-mask::${SECRET}\$" "${OUT10}" || ok10=0
# Outside the add-mask directive line itself, the secret must never appear.
if grep -v "^::add-mask::${SECRET}\$" "${OUT10}" | grep -q "${SECRET}"; then
  ok10=0
fi
if grep -q "${SECRET}" "${CALLS10}"; then
  ok10=0
fi
if [[ "${ok10}" -eq 1 ]]; then
  echo "  PASS  key_masked_and_never_on_curl_argv_or_trace"
  (( PASS++ )) || true
else
  echo "  FAIL  key_masked_and_never_on_curl_argv_or_trace  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 11: the app upload returns garbled, non-JSON garbage — jq must fail
# loudly (set -euo pipefail propagates its exit through the assignment), the
# action exits non-zero with a usable error, the test command never runs
# (proven by the marker file it would have created never appearing), and
# KIFAS_APP is therefore never exported at all — never empty, never the
# literal string "null".
RESP11="${TMP_DIR}/resp11.txt"
cat > "${RESP11}" << 'EOF'
not valid json at all
EOF
MARKER11="${TMP_DIR}/marker11"
rm -f "${MARKER11}"
OUT11="${TMP_DIR}/out11.log"
mock11="${TMP_DIR}/curl_garbled"
make_mock_curl "${mock11}"
app11="${TMP_DIR}/app11.apk"
echo dummy > "${app11}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app11}" \
  KIFAS_TEST_COMMAND="echo ran > ${MARKER11}" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock11}" \
  MOCK_CURL_RESPONSES_FILE="${RESP11}" \
  bash "${RUN_SH}" > "${OUT11}" 2>&1 || actual_exit=$?
ok11=1
[[ "${actual_exit}" -ne 0 ]] || ok11=0
[[ ! -f "${MARKER11}" ]] || ok11=0
grep -qE '::error::' "${OUT11}" || ok11=0
! grep -q '^KIFAS_APP=$' "${OUT11}" || ok11=0
! grep -q 'KIFAS_APP=null' "${OUT11}" || ok11=0
if [[ "${ok11}" -eq 1 ]]; then
  echo "  PASS  garbled_upload_response_fails_loudly"
  (( PASS++ )) || true
else
  echo "  FAIL  garbled_upload_response_fails_loudly  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 12: the app upload returns well-formed JSON but with build_uri
# explicitly null — this must fail exactly like a missing build_uri (never
# export the literal string "null" as KIFAS_APP, never run the test command).
RESP12="${TMP_DIR}/resp12.txt"
cat > "${RESP12}" << 'EOF'
{"app_build_id":"appbuild-12","build_uri":null}
EOF
MARKER12="${TMP_DIR}/marker12"
rm -f "${MARKER12}"
OUT12="${TMP_DIR}/out12.log"
mock12="${TMP_DIR}/curl_null_build_uri"
make_mock_curl "${mock12}"
app12="${TMP_DIR}/app12.apk"
echo dummy > "${app12}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app12}" \
  KIFAS_TEST_COMMAND="echo ran > ${MARKER12}" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock12}" \
  MOCK_CURL_RESPONSES_FILE="${RESP12}" \
  bash "${RUN_SH}" > "${OUT12}" 2>&1 || actual_exit=$?
ok12=1
[[ "${actual_exit}" -ne 0 ]] || ok12=0
[[ ! -f "${MARKER12}" ]] || ok12=0
grep -qE '::error::.*build_uri' "${OUT12}" || ok12=0
! grep -q 'KIFAS_APP=null' "${OUT12}" || ok12=0
if [[ "${ok12}" -eq 1 ]]; then
  echo "  PASS  null_build_uri_fails_loudly"
  (( PASS++ )) || true
else
  echo "  FAIL  null_build_uri_fails_loudly  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# ---------------------------------------------------------------------------
# HTTP status handling: a non-2xx answer must surface the server's own message
# and the status, not "response missing build_uri". Covered for BOTH calls,
# with a JSON error body and with a non-JSON one.
# ---------------------------------------------------------------------------

# Case 13: the upload is refused 403 with a JSON error body — the server's own
# message and the status reach the job log, and the test command never runs.
RESP13="${TMP_DIR}/resp13.txt"
printf '403\t{"error":{"code":"forbidden","message":"api key is missing the workflow:run scope"}}\n' > "${RESP13}"
MARKER13="${TMP_DIR}/marker13"
rm -f "${MARKER13}"
OUT13="${TMP_DIR}/out13.log"
CALLS13="${TMP_DIR}/calls13.log"
: > "${CALLS13}"
mock13="${TMP_DIR}/curl_upload_403"
make_mock_curl "${mock13}"
app13="${TMP_DIR}/app13.apk"
echo dummy > "${app13}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app13}" \
  KIFAS_TEST_COMMAND="echo ran > ${MARKER13}" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock13}" \
  MOCK_CURL_RESPONSES_FILE="${RESP13}" \
  MOCK_CURL_CALLS_LOG="${CALLS13}" \
  bash "${RUN_SH}" > "${OUT13}" 2>&1 || actual_exit=$?
ok13=1
[[ "${actual_exit}" -ne 0 ]] || ok13=0
[[ ! -f "${MARKER13}" ]] || ok13=0
grep -q 'api key is missing the workflow:run scope' "${OUT13}" || ok13=0
grep -q 'HTTP 403' "${OUT13}" || ok13=0
! grep -q 'missing build_uri' "${OUT13}" || ok13=0
! grep -q '/v1/remote-webdriver/builds' "${CALLS13}" || ok13=0
if [[ "${ok13}" -eq 1 ]]; then
  echo "  PASS  upload_403_surfaces_server_message"
  (( PASS++ )) || true
else
  echo "  FAIL  upload_403_surfaces_server_message  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 14: the upload is refused with a NON-JSON body (an HTML error page from
# a proxy) — the status and a usable reason still reach the log, and the body
# itself is never echoed, since it can carry a presigned URL or a credential.
RESP14="${TMP_DIR}/resp14.txt"
printf '413\t<html><body>Request Entity Too Large SECRET_PROXY_TOKEN_42</body></html>\n' > "${RESP14}"
OUT14="${TMP_DIR}/out14.log"
mock14="${TMP_DIR}/curl_upload_413"
make_mock_curl "${mock14}"
app14="${TMP_DIR}/app14.apk"
echo dummy > "${app14}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app14}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock14}" \
  MOCK_CURL_RESPONSES_FILE="${RESP14}" \
  bash "${RUN_SH}" > "${OUT14}" 2>&1 || actual_exit=$?
ok14=1
[[ "${actual_exit}" -ne 0 ]] || ok14=0
grep -q 'HTTP 413' "${OUT14}" || ok14=0
grep -q '500 MB' "${OUT14}" || ok14=0
! grep -q 'SECRET_PROXY_TOKEN_42' "${OUT14}" || ok14=0
if [[ "${ok14}" -eq 1 ]]; then
  echo "  PASS  upload_non_json_error_reports_status_without_echoing_body"
  (( PASS++ )) || true
else
  echo "  FAIL  upload_non_json_error_reports_status_without_echoing_body  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 15: the upload succeeds but opening the build is refused 403 with a JSON
# error body — again the server's message and status, not a missing-field error.
RESP15="${TMP_DIR}/resp15.txt"
{
  printf '{"app_build_id":"appbuild-15","build_uri":"kifas://build/aaaa1111-0000-0000-0000-000000000000"}\n'
  printf '403\t{"error":{"code":"forbidden","message":"api key is missing the session:create scope"}}\n'
} > "${RESP15}"
MARKER15="${TMP_DIR}/marker15"
rm -f "${MARKER15}"
OUT15="${TMP_DIR}/out15.log"
mock15="${TMP_DIR}/curl_open_403"
make_mock_curl "${mock15}"
app15="${TMP_DIR}/app15.apk"
echo dummy > "${app15}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app15}" \
  KIFAS_TEST_COMMAND="echo ran > ${MARKER15}" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock15}" \
  MOCK_CURL_RESPONSES_FILE="${RESP15}" \
  bash "${RUN_SH}" > "${OUT15}" 2>&1 || actual_exit=$?
ok15=1
[[ "${actual_exit}" -ne 0 ]] || ok15=0
[[ ! -f "${MARKER15}" ]] || ok15=0
grep -q 'api key is missing the session:create scope' "${OUT15}" || ok15=0
grep -q 'HTTP 403' "${OUT15}" || ok15=0
! grep -q 'missing suiteRunId' "${OUT15}" || ok15=0
if [[ "${ok15}" -eq 1 ]]; then
  echo "  PASS  open_403_surfaces_server_message"
  (( PASS++ )) || true
else
  echo "  FAIL  open_403_surfaces_server_message  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 16: opening the build fails with a non-JSON body — status plus a safe
# reason, and the raw body stays out of the log.
RESP16="${TMP_DIR}/resp16.txt"
{
  printf '{"app_build_id":"appbuild-16","build_uri":"kifas://build/bbbb1111-0000-0000-0000-000000000000"}\n'
  printf '502\tBad Gateway SECRET_UPSTREAM_TOKEN_77\n'
} > "${RESP16}"
OUT16="${TMP_DIR}/out16.log"
mock16="${TMP_DIR}/curl_open_502"
make_mock_curl "${mock16}"
app16="${TMP_DIR}/app16.apk"
echo dummy > "${app16}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app16}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock16}" \
  MOCK_CURL_RESPONSES_FILE="${RESP16}" \
  bash "${RUN_SH}" > "${OUT16}" 2>&1 || actual_exit=$?
ok16=1
[[ "${actual_exit}" -ne 0 ]] || ok16=0
grep -q 'HTTP 502' "${OUT16}" || ok16=0
grep -q 'temporarily unavailable' "${OUT16}" || ok16=0
! grep -q 'SECRET_UPSTREAM_TOKEN_77' "${OUT16}" || ok16=0
if [[ "${ok16}" -eq 1 ]]; then
  echo "  PASS  open_non_json_error_reports_status_without_echoing_body"
  (( PASS++ )) || true
else
  echo "  FAIL  open_non_json_error_reports_status_without_echoing_body  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# ---------------------------------------------------------------------------
# Build identity: without version/build_number every CI build lands in Kifas
# as 0.0.0 / 0 and the build list cannot tell one push from another.
# ---------------------------------------------------------------------------

# Case 17: the upload carries a version derived from the commit sha and a build
# number from the run number, as --form-string (never -F, which would read a
# leading @ in a value as a file path).
RESP17="${TMP_DIR}/resp17.txt"
cat > "${RESP17}" << 'EOF'
{"app_build_id":"appbuild-17","build_uri":"kifas://build/cccc1111-0000-0000-0000-000000000000"}
{"suiteRunId":"dddd1111-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/dddd"}
{"suiteRunId":"dddd1111-0000-0000-0000-000000000000","closeRequested":true}
EOF
CALLS17="${TMP_DIR}/calls17.log"
: > "${CALLS17}"
mock17="${TMP_DIR}/curl_identity"
make_mock_curl "${mock17}"
app17="${TMP_DIR}/app17.apk"
echo dummy > "${app17}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app17}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock17}" \
  MOCK_CURL_RESPONSES_FILE="${RESP17}" \
  MOCK_CURL_CALLS_LOG="${CALLS17}" \
  GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12" \
  GITHUB_RUN_NUMBER="57" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
upload_line17="$(grep '/v1/app-builds/upload' "${CALLS17}" | head -1 || true)"
ok17=1
[[ "${actual_exit}" -eq 0 ]] || ok17=0
grep -Fq -- '--form-string version=abcdef1' <<< "${upload_line17}" || ok17=0
grep -Fq -- '--form-string build_number=57' <<< "${upload_line17}" || ok17=0
# Linkage is opt-in, so an unconnected repo is never implied by default.
! grep -Fq -- '--form-string repo=' <<< "${upload_line17}" || ok17=0
! grep -Fq -- '--form-string commit_sha=' <<< "${upload_line17}" || ok17=0
if [[ "${ok17}" -eq 1 ]]; then
  echo "  PASS  upload_sends_version_and_build_number"
  (( PASS++ )) || true
else
  echo "  FAIL  upload_sends_version_and_build_number  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

# Case 18: with link-github-build enabled the upload also carries repo, commit,
# branch, PR number and the CI run URL.
RESP18="${TMP_DIR}/resp18.txt"
cat > "${RESP18}" << 'EOF'
{"app_build_id":"appbuild-18","build_uri":"kifas://build/eeee1111-0000-0000-0000-000000000000"}
{"suiteRunId":"ffff1111-0000-0000-0000-000000000000","suiteRunUrl":"https://app.kifas.io/x/y/z/runs/ffff"}
{"suiteRunId":"ffff1111-0000-0000-0000-000000000000","closeRequested":true}
EOF
CALLS18="${TMP_DIR}/calls18.log"
: > "${CALLS18}"
mock18="${TMP_DIR}/curl_linkage"
make_mock_curl "${mock18}"
app18="${TMP_DIR}/app18.apk"
echo dummy > "${app18}"
actual_exit=0
env -i PATH="${PATH}" \
  KIFAS_API_KEY="test-secret-key-999" \
  KIFAS_PROJECT_ID="11111111-1111-1111-1111-111111111111" \
  KIFAS_SUITE_NAME="smoke" \
  KIFAS_BUILD_NAME="build-42" \
  KIFAS_BUILD_ID="ext-key-42" \
  KIFAS_APP_PATH="${app18}" \
  KIFAS_TEST_COMMAND="true" \
  KIFAS_API_BASE="https://mock.kifas.io" \
  KIFAS_CURL="${mock18}" \
  MOCK_CURL_RESPONSES_FILE="${RESP18}" \
  MOCK_CURL_CALLS_LOG="${CALLS18}" \
  KIFAS_LINK_GITHUB_BUILD="true" \
  GITHUB_REPOSITORY="workiz/mobile-app" \
  GITHUB_SHA="abcdef1234567890abcdef1234567890abcdef12" \
  GITHUB_REF="refs/pull/314/merge" \
  GITHUB_REF_NAME="314/merge" \
  GITHUB_RUN_ID="9911" \
  GITHUB_RUN_NUMBER="57" \
  GITHUB_SERVER_URL="https://github.com" \
  bash "${RUN_SH}" >/dev/null 2>&1 || actual_exit=$?
upload_line18="$(grep '/v1/app-builds/upload' "${CALLS18}" | head -1 || true)"
ok18=1
[[ "${actual_exit}" -eq 0 ]] || ok18=0
grep -Fq -- '--form-string repo=workiz/mobile-app' <<< "${upload_line18}" || ok18=0
grep -Fq -- '--form-string commit_sha=abcdef1234567890abcdef1234567890abcdef12' <<< "${upload_line18}" || ok18=0
grep -Fq -- '--form-string branch=314/merge' <<< "${upload_line18}" || ok18=0
grep -Fq -- '--form-string pr_number=314' <<< "${upload_line18}" || ok18=0
grep -Fq -- '--form-string ci_run_url=https://github.com/workiz/mobile-app/actions/runs/9911' <<< "${upload_line18}" || ok18=0
if [[ "${ok18}" -eq 1 ]]; then
  echo "  PASS  link_github_build_sends_commit_and_pr_linkage"
  (( PASS++ )) || true
else
  echo "  FAIL  link_github_build_sends_commit_and_pr_linkage  (exit=${actual_exit})"
  (( FAIL++ )) || true
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
