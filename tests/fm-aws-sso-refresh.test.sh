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
use_device_code=0
for arg in "$@"; do
  if [ "$previous" = --profile ]; then profile=$arg; fi
  if [ "$arg" = --use-device-code ]; then use_device_code=1; fi
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
  printf '%s\n' "$*" >> "$FAKE_AWS_STATE/login-argv"
  # Every fixture profile uses a named sso_session, so real awscli routes login
  # through the PKCE authorization-code flow unless --use-device-code is passed:
  # one /authorize URL, no user code, then a block on the local redirect.
  if [ "$use_device_code" = 0 ] || [ "${FAKE_IGNORE_DEVICE_CODE:-0}" = 1 ]; then
    printf 'Browser will not be automatically opened.\nPlease visit the following URL:\n\n'
    printf '%s\n' "${FAKE_AUTHORIZE_URL:-https://oidc.us-east-1.amazonaws.com/authorize?response_type=code&client_id=fake&redirect_uri=http%3A%2F%2F127.0.0.1%3A50123%2Foauth%2Fcallback&state=fake-state&code_challenge=fake-challenge&code_challenge_method=S256}"
    sleep "${FAKE_PKCE_BLOCK:-30}"
    exit 1
  fi
  # Real awscli PrintOnlyHandler shape: an optional notice, the BARE
  # verificationUri first, then the code-carrying verificationUriComplete.
  if [ -n "${FAKE_NOTICE_URL:-}" ]; then
    printf 'Note: a newer AWS CLI release is described at %s\n' "$FAKE_NOTICE_URL"
  fi
  printf 'Browser will not be automatically opened.\nPlease visit the following URL:\n\n'
  printf '%s\n' "${FAKE_BARE_URL:-https://device.sso.us-east-1.amazonaws.com/}"
  printf '\nThen enter the code:\n\nABCD-EFGH\n'
  if [ "${FAKE_OMIT_COMPLETE_URL:-0}" != 1 ]; then
    printf '\nAlternatively, you may visit the following URL which will autofill the code upon loading:\n'
    complete=${FAKE_DEVICE_URL:-https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH}
    if [ "${FAKE_SPLIT_URL:-0}" = 1 ]; then
      # Flush a chunk that ends mid-URL, after a complete hostname and query key.
      printf '%s' "${complete%%=*}="
      sleep 0.4
      printf '%s\n' "${complete#*=}"
    else
      printf '%s\n' "$complete"
    fi
  fi
  printf 'token=SECRET-TOKEN-VALUE\n'
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
# The bare verificationUri prints first; only the code-carrying complete URL is usable.
assert request["verificationUrl"] == "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH", request
PY
  assert_clean_output "$dir"
  pass "AWS SSO: expired operator path self-refreshes, requests saved-account approval, and verifies identity"
}

# The AWS CLI prints the bare verificationUri first, may emit unrelated URLs
# before it, and can flush a chunk that ends mid-URL. None of that may reach the
# browser adapter or abort an otherwise healthy login.
test_device_url_selection_survives_real_cli_output_shape() {
  local dir rc request

  dir=$(make_case notice-url)
  rc=$(run_refresh "$dir" env FAKE_NOTICE_URL=https://docs.aws.amazon.com/cli/latest/userguide/ \
    FAKE_BROWSER_MODE=approved)
  expect_code 0 "$rc" "an incidental non-device URL before the device URL should not abort the login"
  request=$(cat "$dir/browser-requests")
  python3 - "$request" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
assert request["verificationUrl"] == "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH", request
PY
  assert_clean_output "$dir"

  dir=$(make_case split-url)
  rc=$(run_refresh "$dir" env FAKE_SPLIT_URL=1 FAKE_BROWSER_MODE=approved)
  expect_code 0 "$rc" "a device URL split across PTY chunks should still refresh"
  request=$(cat "$dir/browser-requests")
  python3 - "$request" <<'PY'
import json, sys
request = json.loads(sys.argv[1])
assert request["verificationUrl"] == "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH", request
PY
  assert_clean_output "$dir"

  dir=$(make_case bare-url-only-failed-login)
  rc=$(run_refresh "$dir" env FAKE_OMIT_COMPLETE_URL=1 FAKE_LOGIN_RC=1 FAKE_BROWSER_MODE=approved)
  expect_code 10 "$rc" "a bare verificationUri with no user_code should stop instead of driving the browser"
  assert_absent "$dir/browser-requests" "the code-entry-only bare verificationUri was handed to the browser adapter"
  assert_grep "device request state is ambiguous" "$dir/err" "bare-only device URL returned the wrong public reason"
  assert_clean_output "$dir"
  pass "AWS SSO: only the code-carrying device URL from complete output reaches the browser"
}

# --use-device-code is mandatory: a named sso_session profile would otherwise
# take the PKCE authorization-code flow, whose single /authorize URL carries no
# device request this command is allowed to approve.
test_device_code_flow_is_forced_and_pkce_is_never_driven() {
  local dir rc
  dir=$(make_case device-code-forced)
  rc=$(run_refresh "$dir" env FAKE_BROWSER_MODE=approved)
  expect_code 0 "$rc" "the named-session refresh should run the device-code flow"
  assert_grep "--use-device-code" "$dir/state/login-argv" "aws sso login did not force the device-code flow"
  assert_present "$dir/browser-requests" "the forced device-code flow never reached the browser adapter"
  assert_clean_output "$dir"

  dir=$(make_case pkce-not-driven)
  CASE_TIMEOUT=6
  rc=$(run_refresh "$dir" env FAKE_IGNORE_DEVICE_CODE=1 FAKE_BROWSER_MODE=approved)
  unset CASE_TIMEOUT
  expect_code 10 "$rc" "an authorization-code URL should stop for a human rather than stalling or being driven"
  assert_absent "$dir/browser-requests" "the PKCE /authorize URL was handed to the browser adapter"
  assert_grep "authorization-code flow" "$dir/err" "PKCE flow returned the wrong public reason"
  assert_clean_output "$dir"
  pass "AWS SSO: the device-code flow is forced and a PKCE authorize URL is never driven"
}

# A login that exits 0 is settled by the account/role identity check, not by
# whatever device URL happened to be left in its output.
test_successful_login_is_settled_by_identity_not_leftover_output() {
  local dir rc
  dir=$(make_case identity-first)
  rc=$(run_refresh "$dir" env FAKE_OMIT_COMPLETE_URL=1 FAKE_BROWSER_MODE=approved)
  expect_code 0 "$rc" "a login that exited 0 should be verified by identity instead of reported as human action"
  assert_grep "AWS SSO refreshed and identity verified: account=111122223333" "$dir/out" \
    "identity-first success did not report the non-secret verified identity"
  assert_absent "$dir/browser-requests" "an unusable bare device URL was still handed to the browser adapter"
  assert_clean_output "$dir"

  dir=$(make_case identity-first-mismatch)
  rc=$(run_refresh "$dir" env FAKE_OMIT_COMPLETE_URL=1 FAKE_ACCOUNT=999988887777 FAKE_BROWSER_MODE=approved)
  expect_code 12 "$rc" "identity-first completion must still enforce the expected account"
  assert_grep "account does not match" "$dir/err" "account mismatch after a successful login was not enforced"
  assert_clean_output "$dir"
  pass "AWS SSO: a successful login exit is decided by verified identity, still account/role gated"
}

# argparse's own error text echoes argv, which would print the private selector.
test_invalid_invocation_never_echoes_argv() {
  local dir rc output
  dir=$(make_case invalid-argv)
  rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_PROFILE=example-admin \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" \
    "$SUBJECT" --config "$dir/local.json" --account-selectr saved-account-private \
      > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 12 "$rc" "a mistyped flag should be the deterministic tool/configuration outcome"
  output=$(cat "$dir/out" "$dir/err")
  assert_contains "$output" "invalid invocation" "invalid invocation reason missing"
  assert_not_contains "$output" "saved-account-private" "private saved-account selector leaked through argv echo"
  assert_not_contains "$output" "account-selectr" "argparse echoed the offending argument"
  assert_not_contains "$output" "usage:" "argparse emitted its own usage text"
  pass "AWS SSO: invalid invocation reports an authored constant without echoing argv"
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
  rc=$(run_refresh "$dir" env FAKE_BARE_URL=https://evil.example/device FAKE_DEVICE_URL=https://evil.example/device)
  expect_code 10 "$rc" "wrong device origin should require human review"
  assert_absent "$dir/browser-requests" "wrong-origin URL was handed to the browser adapter"
  assert_grep "unexpected origin" "$dir/err" "wrong origin reason was not deterministic"
  assert_clean_output "$dir"

  dir=$(make_case wrong-complete-origin)
  rc=$(run_refresh "$dir" env FAKE_DEVICE_URL=https://evil.example/device)
  expect_code 10 "$rc" "a wrong origin announced as the autofill URL should require human review"
  assert_absent "$dir/browser-requests" "wrong-origin autofill URL was handed to the browser adapter"
  assert_grep "unexpected origin" "$dir/err" "wrong autofill origin reason was not deterministic"
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

# The embedded driver body (BROWSER_HARNESS_PROGRAM) is the part that actually
# touches a browser, so it is executed here against a deterministic in-process
# CDP double instead of only being compiled. The double records every CDP method
# the driver issues, so origin checks, saved-account selection, the
# confirm-then-allow order, ambiguity refusals, background-tab ownership, and the
# absence of any pointer/keyboard input are observed from the real code path.
# No Chrome is started or attached and no browser-harness daemon is contacted.
write_fake_cdp_helpers() {
  cat > "$1" <<'PY'
# Test double for browser_harness.helpers: serves a scripted page sequence to
# the embedded adapter and records what it asked the browser to do.
import json
import os
import re

_state = os.environ["FAKE_CDP_STATE"]
with open(os.environ["FAKE_CDP_SCENARIO"], encoding="utf-8") as _handle:
    _scenario = json.load(_handle)
_pages = _scenario["pages"]
_current = [0]

# The verification URL must reach the adapter through the private mode-0600
# file, never argv or the environment; capture both for the caller to assert.
_request_path = os.environ.get("FM_AWS_SSO_REQUEST_FILE", "")
if _request_path and os.path.exists(_request_path):
    with open(_request_path, encoding="utf-8") as _handle:
        _payload = _handle.read()
    with open(os.path.join(_state, "adapter-request.json"), "w", encoding="utf-8") as _handle:
        _handle.write(_payload)
    with open(os.path.join(_state, "adapter-request.mode"), "w", encoding="utf-8") as _handle:
        _handle.write("%o\n" % (os.stat(_request_path).st_mode & 0o777))


def _record(name, payload):
    with open(os.path.join(_state, name), "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def _evaluate(expression):
    page = _pages[_current[0]]
    match = re.search(r"controls\[(\d+)\]", expression)
    if match and "e.click()" in expression:
        index = int(match.group(1))
        controls = page.get("controls", [])
        if index >= len(controls):
            return False
        _record("clicks.jsonl", {"page": _current[0], "control": controls[index].get("text", "")})
        target = page.get("clicks", {}).get(str(index))
        if target is not None:
            _current[0] = target
        return True
    return json.dumps({
        "url": page["url"],
        "ready": page.get("ready", "complete"),
        "text": page.get("text", ""),
        "controls": [dict(control, i=index) for index, control in enumerate(page.get("controls", []))],
    })


def cdp(method, session_id=None, **params):
    _record("cdp-calls.jsonl", {"method": method, "session": session_id, "params": params})
    if method == "Browser.getVersion":
        return _scenario.get("version", {
            "product": "Chrome/141.0.7390.65",
            "userAgent": "Mozilla/5.0 (Macintosh) Chrome/141.0.7390.65 Safari/537.36",
            "jsVersion": "14.1",
        })
    if method == "SystemInfo.getProcessInfo":
        return {"processInfo": [{"id": int(os.environ["FAKE_CDP_BROWSER_PID"]), "type": "browser"}]}
    if method == "Target.createTarget":
        return {"targetId": "fm-owned-target"}
    if method == "Target.attachToTarget":
        return {"sessionId": "fm-owned-session"}
    if method == "Runtime.evaluate":
        return {"result": {"value": _evaluate(params.get("expression", ""))}}
    return {}
PY
}

setup_embedded_driver_case() {
  local name=$1 dir tool
  dir=$(make_case "$name")
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
  chmod +x "$dir/fakebin/browser-harness"
  # Physical-control tripwires: no pointer mover, global keystroke sender, or
  # app launcher may be reached from the driver.
  for tool in osascript cliclick open; do
    cat > "$dir/fakebin/$tool" <<EOF
#!/bin/sh
printf '%s\n' "$tool \$*" >> "$dir/state/physical-control-invoked"
exit 0
EOF
    chmod +x "$dir/fakebin/$tool"
  done
  mkdir -p "$dir/fakepkg/browser_harness"
  : > "$dir/fakepkg/browser_harness/__init__.py"
  cp "$TMP_ROOT/fake-cdp-helpers.py" "$dir/fakepkg/browser_harness/helpers.py"
  printf '%s\n' "$dir"
}

run_embedded_driver() {
  local dir=$1 rc=0
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    PATH="$dir/fakebin:$PATH" AWS_CONFIG_FILE="$dir/aws-config" AWS_PROFILE=example-admin \
    FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_LOCK_DIR="$dir/locks" FAKE_AWS_STATE="$dir/state" \
    PYTHONPATH="$dir/fakepkg" FAKE_CDP_STATE="$dir/state" FAKE_CDP_SCENARIO="$dir/scenario.json" \
    FAKE_CDP_BROWSER_PID="$FAKE_CHROME_PID" \
    "$SUBJECT" --config "$dir/local.json" --browser-driver browser-harness --timeout "${CASE_TIMEOUT:-15}" \
      > "$dir/out" 2> "$dir/err" || rc=$?
  printf '%s\n' "$rc"
}

# Safety invariants that hold for every embedded-driver scenario, whatever the
# page said: no pointer/keyboard injection, no focus or active-tab takeover, no
# physical control tool, and no leftover private request file.
assert_embedded_driver_safety() {
  local dir=$1
  assert_absent "$dir/state/physical-control-invoked" "the embedded driver reached for a physical control tool"
  if [ -f "$dir/state/cdp-calls.jsonl" ]; then
    assert_no_grep '"method": "Input.' "$dir/state/cdp-calls.jsonl" \
      "the embedded driver injected pointer or keyboard input"
    assert_no_grep '"method": "Target.activateTarget"' "$dir/state/cdp-calls.jsonl" \
      "the embedded driver took over the operator's active tab"
    assert_no_grep '"method": "Page.bringToFront"' "$dir/state/cdp-calls.jsonl" \
      "the embedded driver took over the operator's window focus"
  fi
  if compgen -G "$dir/locks/browser-request-*.json" > /dev/null; then
    fail "the private device-request file survived the embedded driver run"
  fi
  assert_clean_output "$dir"
}

test_embedded_browser_driver_runs_against_fake_cdp() {
  local dir rc chrome_dir clicks

  write_fake_cdp_helpers "$TMP_ROOT/fake-cdp-helpers.py"
  # A stand-in for the operator's already-running Chrome. It is never launched
  # by the command: the darwin process-identity check only inspects it by pid.
  chrome_dir="$TMP_ROOT/fake-chrome/Google Chrome.app/Contents/MacOS"
  mkdir -p "$chrome_dir"
  cat > "$chrome_dir/Google Chrome" <<'EOF'
#!/bin/sh
for _ in $(seq 1 60); do sleep 1; done
EOF
  chmod +x "$chrome_dir/Google Chrome"
  "$chrome_dir/Google Chrome" &
  FAKE_CHROME_PID=$!

  dir=$(setup_embedded_driver_case cdp-approved)
  cat > "$dir/scenario.json" <<'EOF'
{
  "pages": [
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
      "text": "Choose a saved account to continue. Code ABCD-EFGH",
      "controls": [
        {"tag": "a", "text": "Unrelated help link"},
        {"tag": "button", "text": "saved-account-example"}
      ],
      "clicks": {"1": 1}
    },
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/confirm?user_code=ABCD-EFGH",
      "text": "Authorize request. Request ID ABCD-EFGH",
      "controls": [{"tag": "button", "text": "Confirm and continue"}],
      "clicks": {"0": 2}
    },
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/approve",
      "text": "Grant access to the AWS CLI",
      "controls": [{"tag": "button", "text": "Allow"}],
      "clicks": {"0": 3}
    },
    {"url": "https://device.sso.us-east-1.amazonaws.com/approved", "text": "Request approved", "controls": []}
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 0 "$rc" "the embedded driver should approve the device request (stderr: $(cat "$dir/err"))"
  assert_grep "AWS SSO refreshed and identity verified: account=111122223333" "$dir/out" \
    "the fake-CDP happy path did not report the non-secret verified identity"
  clicks=$(python3 -c 'import json,sys;print(",".join(json.loads(l)["control"] for l in open(sys.argv[1])))' \
    "$dir/state/clicks.jsonl")
  [ "$clicks" = "saved-account-example,Confirm and continue,Allow" ] || \
    fail "the embedded driver did not select the saved account then confirm-and-continue then allow (got: $clicks)"
  assert_grep '"method": "Target.createTarget", "params": {"background": true, "url": "about:blank"}' \
    "$dir/state/cdp-calls.jsonl" "the embedded driver did not open an owned background tab"
  assert_grep '"method": "Target.closeTarget", "params": {"targetId": "fm-owned-target"}' \
    "$dir/state/cdp-calls.jsonl" "the embedded driver did not close only its own tab"
  [ "$(cat "$dir/state/adapter-request.mode")" = "600" ] || \
    fail "the device request reached the embedded driver through a non-private file"
  assert_grep "saved-account-example" "$dir/state/adapter-request.json" \
    "the private saved-account selector did not reach the driver through the private request file"
  assert_embedded_driver_safety "$dir"

  # Every refusal below must happen inside the driver, before or instead of the
  # next click, and surface as the deterministic human-action outcome.
  dir=$(setup_embedded_driver_case cdp-unexpected-origin)
  cat > "$dir/scenario.json" <<'EOF'
{
  "pages": [
    {
      "url": "https://login.example.net/oauth/consent",
      "text": "Continue to the requesting application",
      "controls": [{"tag": "button", "text": "Allow"}]
    }
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 10 "$rc" "an unexpected page origin should require human action"
  assert_grep "unexpected origin" "$dir/err" "the driver's origin refusal was not reported"
  assert_absent "$dir/state/clicks.jsonl" "the embedded driver clicked on an unexpected origin"
  assert_embedded_driver_safety "$dir"

  dir=$(setup_embedded_driver_case cdp-account-ambiguous)
  cat > "$dir/scenario.json" <<'EOF'
{
  "pages": [
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
      "text": "Choose a saved account to continue",
      "controls": [
        {"tag": "button", "text": "saved-account-example (production)"},
        {"tag": "button", "text": "saved-account-example (sandbox)"}
      ]
    }
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 10 "$rc" "two accounts matching the saved selector should require human action"
  assert_grep "saved-account selection is ambiguous" "$dir/err" "the driver's ambiguity refusal was not reported"
  assert_absent "$dir/state/clicks.jsonl" "the embedded driver guessed between ambiguous saved accounts"
  assert_embedded_driver_safety "$dir"

  dir=$(setup_embedded_driver_case cdp-request-ambiguous)
  cat > "$dir/scenario.json" <<'EOF'
{
  "pages": [
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
      "text": "Choose a saved account to continue",
      "controls": [{"tag": "button", "text": "saved-account-example"}],
      "clicks": {"0": 1}
    },
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/confirm?user_code=ABCD-EFGH",
      "text": "Authorize request",
      "controls": [
        {"tag": "button", "text": "Confirm and continue"},
        {"tag": "button", "text": "Allow"}
      ]
    }
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 10 "$rc" "an unverified device-request state should require human action"
  assert_grep "device request state is ambiguous" "$dir/err" "the driver's request-state refusal was not reported"
  assert_no_grep "Allow" "$dir/state/clicks.jsonl" "the embedded driver approved an ambiguous device request"
  assert_embedded_driver_safety "$dir"

  dir=$(setup_embedded_driver_case cdp-credential-form)
  cat > "$dir/scenario.json" <<'EOF'
{
  "pages": [
    {
      "url": "https://example.awsapps.com/start/signin",
      "text": "Enter your password to continue",
      "controls": [
        {"tag": "input", "type": "password", "text": "", "placeholder": "Password"},
        {"tag": "button", "text": "Sign in"}
      ]
    }
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 10 "$rc" "a credential form should require human action"
  assert_grep "requires credential entry" "$dir/err" "the driver's credential refusal was not reported"
  assert_absent "$dir/state/clicks.jsonl" "the embedded driver interacted with a credential form"
  assert_embedded_driver_safety "$dir"

  dir=$(setup_embedded_driver_case cdp-not-chrome)
  cat > "$dir/scenario.json" <<'EOF'
{
  "version": {"product": "Arc/1.60.0", "userAgent": "Mozilla/5.0 (Macintosh) Arc/1.60.0", "jsVersion": "14.1"},
  "pages": [
    {
      "url": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
      "text": "Authorize request",
      "controls": [{"tag": "button", "text": "Allow"}]
    }
  ]
}
EOF
  rc=$(run_embedded_driver "$dir")
  expect_code 10 "$rc" "a non-Chrome attachment should require human action"
  assert_grep "not verified as Google Chrome" "$dir/err" "the driver's browser-identity refusal was not reported"
  assert_no_grep '"method": "Target.createTarget"' "$dir/state/cdp-calls.jsonl" \
    "the embedded driver opened a tab in an unverified browser"
  assert_embedded_driver_safety "$dir"

  kill "$FAKE_CHROME_PID" 2>/dev/null || true
  pass "AWS SSO: the embedded browser driver executes, selects, confirms-then-allows, and refuses unsafe pages"
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
      FAKE_LOGIN_SLEEP=4 FAKE_BROWSER_MODE=approved \
      "$SUBJECT" --config "$dir_a/local.json" --timeout 14 > "$dir_a/out" 2> "$dir_a/err"
  ) &
  p1=$!
  (
    CASE_PROFILE=profile-b \
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      PATH="$dir_b/fakebin:$PATH" AWS_CONFIG_FILE="$dir_b/aws-config" AWS_PROFILE=profile-b \
      FM_AWS_SSO_AWS_BIN=aws FM_AWS_SSO_BROWSER_ADAPTER="$dir_b/fakebin/browser-adapter" \
      FM_AWS_SSO_LOCK_DIR="$shared/locks" FAKE_AWS_STATE="$shared/state" \
      FAKE_LOGIN_SLEEP=4 FAKE_BROWSER_MODE=approved \
      "$SUBJECT" --config "$dir_b/local.json" --timeout 14 > "$dir_b/out" 2> "$dir_b/err"
  ) &
  p2=$!
  wait "$p1" || fail "distinct session A failed"
  wait "$p2" || fail "distinct session B failed"
  elapsed=$(( $(date +%s) - start ))
  [ -f "$shared/state/overlap-observed" ] || fail "distinct SSO sessions did not run concurrently"
  # Serialized would cost both 4s logins (>=8s); concurrent costs one plus
  # startup. 7s separates them with room on each side for ordinary host load.
  [ "$elapsed" -lt 7 ] || fail "distinct SSO sessions serialized unexpectedly (${elapsed}s)"
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
test_device_url_selection_survives_real_cli_output_shape
test_device_code_flow_is_forced_and_pkce_is_never_driven
test_successful_login_is_settled_by_identity_not_leftover_output
test_invalid_invocation_never_echoes_argv
test_still_valid_credentials_skip_login_and_browser
test_human_action_boundaries
test_browser_harness_is_preferred_and_embedded_adapter_compiles
test_embedded_browser_driver_runs_against_fake_cdp
test_missing_browser_attachment_refuses_focus_takeover
test_timeout_is_bounded_and_cleans_children
test_same_session_serializes_and_distinct_sessions_overlap
test_direnv_repo_local_and_standard_profiles
test_tool_config_outcome_and_static_credential_refusal

echo "# all fm-aws-sso-refresh tests passed"
