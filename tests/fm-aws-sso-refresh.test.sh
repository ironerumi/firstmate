#!/usr/bin/env bash
# Deterministic behavior tests for bin/fm-aws-sso-refresh.sh.
# Every AWS, direnv, browser-harness, and agent-browser interaction is stubbed.
# No test reaches AWS, starts a login, attaches to Chrome, or controls a browser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBJECT="$ROOT/bin/fm-aws-sso-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-aws-sso-refresh)

make_case() {
  local name=$1 profile=${2:-example-admin} session=${3:-example-session} portal=${4:-https://example.awsapps.com/start}
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/state" "$dir/locks" "$dir/project"
  cat > "$dir/aws-config" <<EOF
[profile $profile]
sso_session = $session
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = us-east-1

[sso-session $session]
sso_start_url = $portal
sso_region = us-east-1
sso_registration_scopes = sso:account:access
EOF
  cat > "$dir/local.json" <<EOF
{
  "version": 1,
  "defaults": {
    "browserDriver": "browser-harness",
    "browserHarnessName": "aws-sso-test"
  },
  "sessions": {
    "$session": {
      "accountSelector": "saved-account-example",
      "expectedStartUrl": "$portal"
    }
  },
  "profiles": {
    "$profile": {
      "expectedAccount": "111122223333",
      "expectedRole": "AdministratorAccess"
    }
  }
}
EOF
  cat > "$dir/fakebin/aws" <<'EOF'
#!/usr/bin/env bash
set -u
profile=default
previous=
for arg in "$@"; do
  if [ "$previous" = --profile ]; then profile=$arg; fi
  previous=$arg
done
safe_profile=$(printf '%s' "$profile" | tr -c 'A-Za-z0-9._-' '_')
token="$FAKE_AWS_STATE/token-$safe_profile"
if [ "${1:-}" = sts ] && [ "${2:-}" = get-caller-identity ]; then
  if [ "${FAKE_INITIAL_VALID:-0}" = 1 ] || [ -f "$token" ]; then
    printf '{"UserId":"fake","Account":"%s","Arn":"arn:aws:sts::%s:assumed-role/AWSReservedSSO_AdministratorAccess_FAKE/session"}\n' \
      "${FAKE_ACCOUNT:-111122223333}" "${FAKE_ACCOUNT:-111122223333}"
    exit 0
  fi
  printf 'Error when retrieving token from sso: Token has expired and refresh failed\n' >&2
  exit 255
fi
if [ "${1:-}" = sso ] && [ "${2:-}" = login ]; then
  printf '%s\n' "login:$profile" >> "$FAKE_AWS_STATE/login-count"
  printf 'Browser approval is required.\n'
  printf '%s\n' "${FAKE_DEVICE_URL:-https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH}"
  printf 'Then enter the code ABCD-EFGH. token=SECRET-TOKEN-VALUE\n'
  if [ "${FAKE_LOGIN_MODE:-normal}" = child-hang ]; then
    sleep 30 &
    child=$!
    printf '%s\n' "$child" > "$FAKE_AWS_STATE/child-pid"
    wait "$child"
    exit 1
  fi
  overlap_dir="$FAKE_AWS_STATE/login-overlap"
  if mkdir "$overlap_dir" 2>/dev/null; then
    owns_overlap=1
  else
    owns_overlap=0
    : > "$FAKE_AWS_STATE/overlap-observed"
  fi
  trap '[ "$owns_overlap" -ne 1 ] || rmdir "$overlap_dir" 2>/dev/null || true' EXIT
  sleep "${FAKE_LOGIN_SLEEP:-0.1}"
  if [ "${FAKE_LOGIN_RC:-0}" -eq 0 ]; then
    : > "$token"
  fi
  exit "${FAKE_LOGIN_RC:-0}"
fi
printf 'unexpected fake aws invocation\n' >&2
exit 64
EOF
  cat > "$dir/fakebin/browser-adapter" <<'EOF'
#!/usr/bin/env bash
set -u
request=$(cat)
if [ -n "${FAKE_BROWSER_REQUEST_LOG:-}" ]; then
  printf '%s\n' "$request" >> "$FAKE_BROWSER_REQUEST_LOG"
fi
printf 'adapter secret SECRET-ADAPTER-VALUE\n' >&2
case "${FAKE_BROWSER_MODE:-approved}" in
  approved)
    sleep "${FAKE_BROWSER_SLEEP:-0}"
    printf '{"status":"approved"}\n'
    ;;
  ambiguous) printf '{"status":"human-action-required","reason":"account-ambiguous"}\n' ;;
  wrong-origin) printf '{"status":"human-action-required","reason":"unexpected-origin"}\n' ;;
  credential) printf '{"status":"human-action-required","reason":"credential-form"}\n' ;;
  mfa) printf '{"status":"human-action-required","reason":"mfa-required"}\n' ;;
  missing-account) printf '{"status":"human-action-required","reason":"account-not-saved"}\n' ;;
  timeout) sleep 30 ;;
  *) printf '{"status":"tool-error","reason":"request-state-ambiguous"}\n' ;;
esac
EOF
  chmod +x "$dir/fakebin/aws" "$dir/fakebin/browser-adapter"
  printf '%s\n' "$dir"
}

run_refresh() {
  local dir=$1
  shift
  local rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    PATH="$dir/fakebin:$PATH" \
    AWS_CONFIG_FILE="$dir/aws-config" \
    AWS_PROFILE="${CASE_PROFILE:-example-admin}" \
    FM_AWS_SSO_AWS_BIN=aws \
    FM_AWS_SSO_BROWSER_ADAPTER="$dir/fakebin/browser-adapter" \
    FM_AWS_SSO_LOCK_DIR="$dir/locks" \
    FAKE_AWS_STATE="$dir/state" \
    FAKE_BROWSER_REQUEST_LOG="$dir/browser-requests" \
    "$@" "$SUBJECT" --config "$dir/local.json" --timeout "${CASE_TIMEOUT:-10}" \
      > "$dir/out" 2> "$dir/err" || rc=$?
  printf '%s\n' "$rc"
}

assert_clean_output() {
  local dir=$1 output
  output=$(cat "$dir/out" "$dir/err")
  assert_not_contains "$output" "ABCD-EFGH" "device code leaked to output"
  assert_not_contains "$output" "user_code=" "device verification query leaked to output"
  assert_not_contains "$output" "SECRET-TOKEN-VALUE" "AWS token-shaped output leaked"
  assert_not_contains "$output" "SECRET-ADAPTER-VALUE" "browser adapter stderr leaked"
  assert_not_contains "$output" "saved-account-example" "private saved-account selector leaked"
}

# The operator-visible failure shape is expired SSO -> autonomous browser
# approval -> verified identity, not an immediate captain-only stall.
test_expired_session_refreshes_and_verifies_saved_selection() {
  local dir rc request
  dir=$(make_case happy)
  rc=$(run_refresh "$dir" env FAKE_BROWSER_MODE=approved)
  expect_code 0 "$rc" "expired SSO session should refresh through the shared mechanism"
  [ "$(wc -l < "$dir/state/login-count" | tr -d ' ')" -eq 1 ] || fail "happy path did not start exactly one login"
  assert_grep "AWS SSO refreshed and identity verified: account=111122223333" "$dir/out" \
    "happy path did not report the non-secret verified identity"
  request=$(cat "$dir/browser-requests")
  python3 - "$request" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
assert request["accountSelector"] == "saved-account-example"
assert request["expectedStartUrl"] == "https://example.awsapps.com/start"
assert request["verificationUrl"].startswith("https://device.sso.us-east-1.amazonaws.com/")
PY
  assert_clean_output "$dir"
  pass "AWS SSO: expired operator path self-refreshes, requests saved-account approval, and verifies identity"
}

# Still-valid credentials are the smallest disconfirming counterfactual: no
# login or browser action should occur.
test_still_valid_credentials_skip_login_and_browser() {
  local dir rc
  dir=$(make_case still-valid)
  rc=$(run_refresh "$dir" env FAKE_INITIAL_VALID=1)
  expect_code 0 "$rc" "still-valid credentials should succeed"
  assert_absent "$dir/state/login-count" "still-valid credentials still started aws sso login"
  assert_absent "$dir/browser-requests" "still-valid credentials still invoked the browser adapter"
  assert_grep "AWS identity verified" "$dir/out" "still-valid path did not report identity verification"
  assert_clean_output "$dir"
  pass "AWS SSO: still-valid credentials are a no-login/no-browser counterfactual"
}

# Unexpected device origins are stopped before any browser adapter receives the
# URL, while ambiguous accounts and credential/MFA pages use the human outcome.
test_human_action_boundaries() {
  local dir rc mode expected
  dir=$(make_case wrong-device-origin)
  rc=$(run_refresh "$dir" env FAKE_DEVICE_URL=https://evil.example/device)
  expect_code 10 "$rc" "wrong device origin should require human review"
  assert_absent "$dir/browser-requests" "wrong-origin URL was handed to the browser adapter"
  assert_grep "unexpected origin" "$dir/err" "wrong origin reason was not deterministic"
  assert_clean_output "$dir"

  for row in "ambiguous:saved-account selection is ambiguous" \
             "credential:requires credential entry" \
             "mfa:requires MFA" \
             "missing-account:configured saved account is unavailable"; do
    mode=${row%%:*}
    expected=${row#*:}
    dir=$(make_case "human-$mode")
    rc=$(run_refresh "$dir" env FAKE_BROWSER_MODE="$mode")
    expect_code 10 "$rc" "$mode browser state should require genuine human action"
    assert_grep "$expected" "$dir/err" "$mode browser state returned the wrong public reason"
    assert_clean_output "$dir"
  done

  dir=$(make_case unconfigured-account)
  python3 - "$dir/local.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["sessions"]["example-session"].pop("accountSelector")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  rc=$(run_refresh "$dir" env FAKE_BROWSER_MODE=approved)
  expect_code 10 "$rc" "an expired session without private account selection should require human action"
  assert_grep "no private saved-account selector is configured" "$dir/err" \
    "unconfigured private account selection returned the wrong public reason"
  assert_absent "$dir/browser-requests" "browser ran without a configured private account selection"
  assert_clean_output "$dir"
  pass "AWS SSO: wrong origin, ambiguity, credentials, MFA, and missing saved account stop safely"
}

# browser-harness must already be attached; agent-browser's current --cdp/tab
# surface is rejected because its help has no background/no-focus primitive.
test_browser_harness_is_preferred_and_embedded_adapter_compiles() {
  local dir rc
  dir=$(make_case browser-harness-preferred)
  rm -f "$dir/fakebin/browser-adapter"
  cat > "$dir/fakebin/browser-harness" <<'EOF'
#!/usr/bin/env python3
import sys
if len(sys.argv) == 2 and sys.argv[1] == "doctor":
    print("  [ok  ] daemon alive")
    print("  [ok  ] active browser connections - 1")
    raise SystemExit(0)
raise SystemExit(99)
EOF
  cat > "$dir/fakebin/agent-browser" <<'EOF'
#!/usr/bin/env bash
: > "$FAKE_AWS_STATE/agent-browser-invoked"
exit 99
EOF
  mkdir -p "$dir/fakepkg/browser_harness"
  : > "$dir/fakepkg/browser_harness/__init__.py"
  cat > "$dir/fakepkg/browser_harness/helpers.py" <<'PY'
import json
import os
with open(os.path.join(os.environ["FAKE_AWS_STATE"], "browser-harness-invoked"), "w", encoding="utf-8"):
    pass
print(json.dumps({"status": "human-action-required", "reason": "credential-form"}))
raise SystemExit(0)
PY
  chmod +x "$dir/fakebin/browser-harness" "$dir/fakebin/agent-browser"
  rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_PROFILE=example-admin \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" \
    PYTHONPATH="$dir/fakepkg" \
    "$SUBJECT" --config "$dir/local.json" --browser-driver auto --timeout 10 \
      > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 10 "$rc" "stubbed attached browser-harness should return its human boundary (stderr: $(cat "$dir/err"))"
  assert_present "$dir/state/browser-harness-invoked" "browser-harness was not preferred"
  assert_absent "$dir/state/agent-browser-invoked" "agent-browser ran despite a ready browser-harness attachment"
  assert_grep "requires credential entry" "$dir/err" "browser-harness adapter result was not honored"
  assert_clean_output "$dir"
  pass "AWS SSO: browser-harness is preferred and its embedded target-scoped adapter compiles"
}

test_missing_browser_attachment_refuses_focus_takeover() {
  local dir rc
  dir=$(make_case no-attachment)
  rm -f "$dir/fakebin/browser-adapter"
  cat > "$dir/fakebin/browser-harness" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = doctor ]; then
  printf '  [ok  ] daemon alive\n  [FAIL] active browser connections - 0\n'
  exit 0
fi
exit 99
EOF
  cat > "$dir/fakebin/agent-browser" <<'EOF'
#!/usr/bin/env bash
printf 'agent-browser help: --cdp <port>; tab new activates a tab\n'
EOF
  chmod +x "$dir/fakebin/browser-harness" "$dir/fakebin/agent-browser"
  rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_PROFILE=example-admin \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" \
    "$SUBJECT" --config "$dir/local.json" --browser-driver auto --timeout 10 \
      > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 10 "$rc" "missing safe browser attachment should require human action"
  assert_grep "no verified no-focus background-tab channel" "$dir/err" \
    "agent-browser focus-takeover boundary was not reported"
  assert_clean_output "$dir"
  pass "AWS SSO: unavailable attachment never falls into active-tab, isolated-browser, or physical control"
}

test_timeout_is_bounded_and_cleans_children() {
  local dir rc child
  dir=$(make_case timeout)
  CASE_TIMEOUT=1
  rc=$(run_refresh "$dir" env FAKE_LOGIN_SLEEP=30 FAKE_BROWSER_MODE=timeout)
  unset CASE_TIMEOUT
  expect_code 11 "$rc" "hung login/browser should return deterministic timeout"
  assert_grep "timed out" "$dir/err" "timeout result was not reported"
  assert_clean_output "$dir"

  dir=$(make_case child-cleanup)
  rc=$(run_refresh "$dir" env FAKE_LOGIN_MODE=child-hang FAKE_BROWSER_MODE=credential)
  expect_code 10 "$rc" "credential stop should terminate the owned login tree"
  child=$(cat "$dir/state/child-pid")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    fail "owned aws sso login child survived terminal browser outcome"
  fi
  assert_clean_output "$dir"
  pass "AWS SSO: timeout is bounded and terminal outcomes clean the owned child process group"
}

test_same_session_serializes_and_distinct_sessions_overlap() {
  local dir rc1 rc2 start elapsed dir_a dir_b
  dir=$(make_case same-session)
  (
    run_refresh "$dir" env FAKE_LOGIN_SLEEP=1 FAKE_BROWSER_MODE=approved > "$dir/rc1"
  ) &
  p1=$!
  sleep 0.1
  (
    run_refresh "$dir" env FAKE_LOGIN_SLEEP=1 FAKE_BROWSER_MODE=approved > "$dir/rc2"
  ) &
  p2=$!
  wait "$p1"; wait "$p2"
  rc1=$(cat "$dir/rc1"); rc2=$(cat "$dir/rc2")
  expect_code 0 "$rc1" "first same-session call failed"
  expect_code 0 "$rc2" "second same-session call failed"
  [ "$(wc -l < "$dir/state/login-count" | tr -d ' ')" -eq 1 ] || fail "same-session calls did not serialize to one login"
  assert_absent "$dir/state/overlap-observed" "same-session login calls overlapped"

  dir_a=$(make_case distinct-a profile-a session-a https://shared.awsapps.com/start)
  dir_b=$(make_case distinct-b profile-b session-b https://shared.awsapps.com/start)
  # Share the lock root, portal URL, and fake AWS state only for the overlap
  # observation. Distinct named SSO sessions must still have distinct lock keys.
  shared="$TMP_ROOT/distinct-shared"
  mkdir -p "$shared/locks" "$shared/state"
  start=$(date +%s)
  (
    CASE_PROFILE=profile-a \
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      PATH="$dir_a/fakebin:$PATH" AWS_CONFIG_FILE="$dir_a/aws-config" AWS_PROFILE=profile-a \
      FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_BROWSER_ADAPTER="$dir_a/fakebin/browser-adapter" \
      FM_AWS_SSO_LOCK_DIR="$shared/locks" FAKE_AWS_STATE="$shared/state" \
      FAKE_LOGIN_SLEEP=2 FAKE_BROWSER_MODE=approved \
      "$SUBJECT" --config "$dir_a/local.json" --timeout 8 > "$dir_a/out" 2> "$dir_a/err"
  ) &
  p1=$!
  (
    CASE_PROFILE=profile-b \
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      PATH="$dir_b/fakebin:$PATH" AWS_CONFIG_FILE="$dir_b/aws-config" AWS_PROFILE=profile-b \
      FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_BROWSER_ADAPTER="$dir_b/fakebin/browser-adapter" \
      FM_AWS_SSO_LOCK_DIR="$shared/locks" FAKE_AWS_STATE="$shared/state" \
      FAKE_LOGIN_SLEEP=2 FAKE_BROWSER_MODE=approved \
      "$SUBJECT" --config "$dir_b/local.json" --timeout 8 > "$dir_b/out" 2> "$dir_b/err"
  ) &
  p2=$!
  wait "$p1" || fail "distinct session A failed"
  wait "$p2" || fail "distinct session B failed"
  elapsed=$(( $(date +%s) - start ))
  [ -f "$shared/state/overlap-observed" ] || fail "distinct SSO sessions did not run concurrently"
  [ "$elapsed" -lt 4 ] || fail "distinct SSO sessions serialized unexpectedly (${elapsed}s)"
  assert_clean_output "$dir_a"
  assert_clean_output "$dir_b"
  pass "AWS SSO: same session serializes while distinct Identity Center sessions remain concurrent"
}

test_direnv_repo_local_and_standard_profiles() {
  local dir rc
  dir=$(make_case direnv repo-admin repo-session https://repo-example.awsapps.com/start)
  cat > "$dir/fakebin/direnv" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = exec ]
printf '%s\n' "$2" > "$FAKE_DIRENV_LOG"
shift 2
export AWS_CONFIG_FILE="$FAKE_DIRENV_AWS_CONFIG"
export AWS_PROFILE=repo-admin
exec "$@"
EOF
  chmod +x "$dir/fakebin/direnv"
  rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_CONFIG_FILE -u AWS_PROFILE \
    PATH="$dir/fakebin:$PATH" FM_AWS_SSO_AWS_BIN=aws \
    FM_AWS_SSO_BROWSER_ADAPTER="$dir/fakebin/browser-adapter" FM_AWS_SSO_LOCK_DIR="$dir/locks" \
    FAKE_AWS_STATE="$dir/state" FAKE_BROWSER_REQUEST_LOG="$dir/browser-requests" \
    FAKE_DIRENV_LOG="$dir/direnv.log" FAKE_DIRENV_AWS_CONFIG="../aws-config" \
    "$SUBJECT" --config "$dir/local.json" --direnv-root "$dir/project" --timeout 10 \
      > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 0 "$rc" "repo-local direnv AWS configuration should refresh"
  [ "$(cat "$dir/direnv.log")" = "$(cd "$dir/project" && pwd -P)" ] || fail "direnv did not receive the intended project root"
  assert_clean_output "$dir"

  dir=$(make_case standard)
  rc=$(run_refresh "$dir" env FAKE_INITIAL_VALID=1)
  expect_code 0 "$rc" "ordinary standard AWS profile should verify"
  assert_absent "$dir/browser-requests" "standard still-valid profile unexpectedly invoked a browser"
  assert_clean_output "$dir"

  dir=$(make_case default-profile default-admin default-session https://default-example.awsapps.com/start)
  rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE \
    PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_DEFAULT_PROFILE=default-admin \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_BROWSER_ADAPTER="$dir/fakebin/browser-adapter" \
    FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" FAKE_INITIAL_VALID=1 \
    "$SUBJECT" --config "$dir/local.json" --timeout 10 > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 0 "$rc" "AWS_DEFAULT_PROFILE should preserve the caller's intended ordinary profile"
  assert_clean_output "$dir"
  pass "AWS SSO: repository-local direnv configuration and ordinary profiles preserve intended environments"
}

test_tool_config_outcome_and_static_credential_refusal() {
  local dir rc
  dir=$(make_case config-failure)
  rc=0
  PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_PROFILE=example-admin \
    AWS_ACCESS_KEY_ID=FAKE_STATIC_KEY AWS_SECRET_ACCESS_KEY=FAKE_STATIC_SECRET \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_BROWSER_ADAPTER="$dir/fakebin/browser-adapter" \
    FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" \
    "$SUBJECT" --config "$dir/local.json" --timeout 10 > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 12 "$rc" "static credentials should be refused as a tool/configuration failure"
  assert_grep "alternate AWS credential" "$dir/err" "static environment credential refusal reason missing"
  assert_not_contains "$(cat "$dir/out" "$dir/err")" "FAKE_STATIC" "static credential value leaked"

  dir=$(make_case shared-credentials-failure)
  cat > "$dir/credentials" <<'EOF'
[example-admin]
aws_access_key_id = FAKE_FILE_KEY
aws_secret_access_key = FAKE_FILE_SECRET
EOF
  rc=$(run_refresh "$dir" env AWS_SHARED_CREDENTIALS_FILE="$dir/credentials")
  expect_code 12 "$rc" "profile-scoped shared credentials should be refused"
  assert_grep "static shared credentials" "$dir/err" "shared credentials refusal reason missing"
  assert_not_contains "$(cat "$dir/out" "$dir/err")" "FAKE_FILE" "shared credential value leaked"
  pass "AWS SSO: static credentials are refused with the deterministic tool/configuration outcome"
}

test_expired_session_refreshes_and_verifies_saved_selection
test_still_valid_credentials_skip_login_and_browser
test_human_action_boundaries
test_browser_harness_is_preferred_and_embedded_adapter_compiles
test_missing_browser_attachment_refuses_focus_takeover
test_timeout_is_bounded_and_cleans_children
test_same_session_serializes_and_distinct_sessions_overlap
test_direnv_repo_local_and_standard_profiles
test_tool_config_outcome_and_static_credential_refusal

echo "# all fm-aws-sso-refresh tests passed"
