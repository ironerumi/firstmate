#!/usr/bin/env bash
# tests/fm-supervision-alert.test.sh - the two supervision failures that no wake
# can reach: an unrepairable watcher, and work parked on a person.
#
# Covers bin/fm-alert-lib.sh (channel resolution, per-channel isolation, the
# credential boundary, one-shot delivery), bin/fm-watch-arm.sh's bounded repair
# loop, and bin/fm-watch.sh's park scan including the exclusions that keep it
# from firing on ordinary working time, declared external waits, idle
# secondmates, and queue items with nothing waiting on a person.
#
# Every alert here goes through the FM_ALERT_EXEC recorder installed by
# tests/wake-helpers.sh, so no case can post a real notification or a real Slack
# message. The Slack transport is exercised against a fake curl, never a network.
#
# Cases that assert which channels fired pin config/supervision-alert to
# `osascript slack` rather than leaning on the absent-config default: `auto`
# resolves to the platform's OS channel, which is osascript on macOS and nothing
# at all elsewhere, so an unpinned expectation is a host assertion, not a
# behavior one. Channel resolution itself is covered by
# test_channels_and_isolation.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-alert)

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

alert_lines() {  # <log> [channel]
  local log=$1 channel=${2:-}
  [ -f "$log" ] || { printf '0'; return; }
  if [ -n "$channel" ]; then
    grep -c "^$channel	" "$log" | tr -d '[:space:]'
  else
    grep -c . "$log" | tr -d '[:space:]'
  fi
}

# --- 1. channel resolution and isolation -------------------------------------

test_channels_and_isolation() {
  local home log out
  home=$(new_home channels)
  log="$home/alerts.log"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-alert-lib.sh"; fm_alert_channels' _ "$ROOT")
  [ "$out" = "$(printf 'auto\nslack')" ] \
    || fail "an absent config must default to the OS channel plus slack, got: $out"

  printf '# a comment\n\nosascript\nslack\n' > "$home/config/supervision-alert"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-alert-lib.sh"; fm_alert_channels' _ "$ROOT")
  [ "$out" = "$(printf 'osascript\nslack')" ] \
    || fail "configured directives must be read verbatim, got: $out"

  # One failing channel must not suppress the other, and the call still reports
  # delivery because a channel did deliver.
  FM_ALERT_LOG="$log" FM_ALERT_FAIL=osascript \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-alert-lib.sh"; fm_alert_notify "t" "s"' _ "$ROOT" \
    || fail "a surviving channel must still count as delivered"
  [ "$(alert_lines "$log" osascript)" = 1 ] || fail "the failing channel must still be attempted"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a failing channel must not suppress the next one"
  pass "alert channels resolve from config and fail independently"

  printf 'off\n' > "$home/config/supervision-alert"
  : > "$log"
  FM_ALERT_LOG="$log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-alert-lib.sh"; fm_alert_notify "t" "s"' _ "$ROOT" \
    || fail "an explicitly disabled alert is not a failure"
  [ "$(alert_lines "$log")" = 0 ] || fail "off must deliver nothing"
  pass "off disables every channel without reporting a failure"
}

# --- 2. the credential boundary ----------------------------------------------

test_slack_credential_boundary() {
  local home envrc out curl_dir argv_log stdin_log
  home=$(new_home slack-token)
  envrc="$home/fake.envrc"
  printf 'export PATH=/usr/bin\nexport SLACK_BOT_TOKEN="xoxb-test-not-a-real-token"\n' > "$envrc"
  printf 'channel=C0BERD2U7JP\ntoken_file=%s\n' "$envrc" > "$home/config/alert-slack"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c 'unset SLACK_BOT_TOKEN; . "$1/bin/fm-alert-lib.sh"; fm_alert_slack_token' _ "$ROOT")
  [ "$out" = "xoxb-test-not-a-real-token" ] \
    || fail "the token must be parsed from the configured source without direnv, got: $out"

  # The transport must never put the token in any process's arguments. A fake
  # curl records exactly what it was given.
  curl_dir="$home/fakebin"
  mkdir -p "$curl_dir"
  argv_log="$home/curl.argv"
  stdin_log="$home/curl.stdin"
  cat > "$curl_dir/curl" <<CURL
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$argv_log"
cat > "$stdin_log"
exit 0
CURL
  chmod +x "$curl_dir/curl"

  PATH="$curl_dir:$PATH" FM_ALERT_EXEC='' \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c 'unset SLACK_BOT_TOKEN; . "$1/bin/fm-alert-lib.sh"; fm_alert_via_slack "title" "summary"' _ "$ROOT" \
    || fail "the slack transport must report success when curl succeeds"
  grep -q 'xoxb-test-not-a-real-token' "$argv_log" \
    && fail "the token must never appear in curl's arguments"
  grep -q 'Authorization: Bearer xoxb-test-not-a-real-token' "$stdin_log" \
    || fail "the token must reach curl through its stdin config"
  grep -q 'C0BERD2U7JP' "$argv_log" || fail "the configured channel must be posted to"

  # Nothing firstmate writes may carry the value.
  ! grep -rq 'xoxb-test-not-a-real-token' "$home/state" 2>/dev/null \
    || fail "no firstmate state file may contain the token"
  pass "the slack token is read, used on stdin, and never exposed"

  # An unreadable source degrades to a logged skip, never a crash or a leak.
  printf 'channel=C0BERD2U7JP\ntoken_file=%s/missing\n' "$home" > "$home/config/alert-slack"
  PATH="$curl_dir:$PATH" FM_ALERT_EXEC='' \
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c 'unset SLACK_BOT_TOKEN; . "$1/bin/fm-alert-lib.sh"; fm_alert_via_slack "t" "s"' _ "$ROOT" \
    && fail "a missing token source must not report a delivered alert"
  grep -q 'slack token source is not readable' "$home/state/.alert.log" \
    || fail "the skip must be recorded in the alert log"
  pass "an unavailable slack credential degrades to a logged skip"
}

# --- 3. bounded watcher repair ------------------------------------------------
#
# The arm layer resolves its watcher from its own directory, so a controllable
# watcher means a temp copy of the three files the arm actually loads.

arm_lab() {  # <name> <fail-count> -> lab dir
  local name=$1 fail_count=$2 lab
  lab="$TMP_ROOT/$name"
  mkdir -p "$lab/bin" "$lab/state" "$lab/config"
  printf 'osascript\nslack\n' > "$lab/config/supervision-alert"
  cp -f "$ROOT/bin/fm-watch-arm.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-alert-lib.sh" "$lab/bin/"
  printf '0\n' > "$lab/launches"
  cat > "$lab/bin/fm-watch.sh" <<WATCH
#!/usr/bin/env bash
# Fake watcher: dies unexplained for the first $fail_count launches, then
# reports one actionable wake.
n=\$(cat "$lab/launches")
n=\$((n + 1))
printf '%s\n' "\$n" > "$lab/launches"
[ "\$n" -le "$fail_count" ] && exit 0
echo "signal: $lab/state/demo.status"
exit 0
WATCH
  chmod +x "$lab/bin/fm-watch.sh"
  printf '%s\n' "$lab"
}

run_arm() {  # <lab> <retries> <stdout-file> <stderr-file> [alert-log]
  local lab=$1 retries=$2 out=$3 err=$4 log=${5:-/dev/null}
  FM_HOME="$lab" FM_STATE_OVERRIDE="$lab/state" FM_CONFIG_OVERRIDE="$lab/config" \
  FM_ALERT_LOG="$log" FM_WATCH_REPAIR_RETRIES="$retries" FM_WATCH_REPAIR_DELAY=0 \
  FM_ARM_CONFIRM_TIMEOUT=1 "$lab/bin/fm-watch-arm.sh" > "$out" 2> "$err"
}

test_repair_succeeds() {
  local lab out err log code
  lab=$(arm_lab repair-success 2)
  out="$lab/out"; err="$lab/err"; log="$lab/alerts.log"
  run_arm "$lab" 3 "$out" "$err" "$log"; code=$?
  expect_code 0 "$code" "a repaired cycle must succeed"
  assert_contains "$(cat "$out")" "signal:" "the repaired cycle's wake must be propagated"
  assert_not_contains "$(cat "$out")" "FAILED" "a successful repair must not report a failure"
  [ "$(cat "$lab/launches")" = 3 ] || fail "repair must re-arm, got $(cat "$lab/launches") launches"
  assert_contains "$(cat "$err")" "repairing dead cycle (attempt 1/3)" "repair progress belongs on stderr"
  [ "$(alert_lines "$log")" = 0 ] || fail "a successful repair must not alert"
  pass "an unexpected watcher death self-repairs without a blind-turn failure"
}

test_repair_exhaustion_alerts() {
  local lab out err log code
  lab=$(arm_lab repair-exhaustion 99)
  out="$lab/out"; err="$lab/err"; log="$lab/alerts.log"
  run_arm "$lab" 2 "$out" "$err" "$log"; code=$?
  expect_code 1 "$code" "an unrepairable watcher must still fail loudly"
  assert_contains "$(cat "$out")" "watcher: FAILED - cycle ended without an actionable reason" \
    "the typed failure line must survive repair"
  [ "$(cat "$lab/launches")" = 3 ] || fail "repair must be bounded, got $(cat "$lab/launches") launches"
  [ "$(alert_lines "$log" osascript)" = 1 ] || fail "exhaustion must raise exactly one macOS alert"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "exhaustion must raise exactly one slack alert"
  assert_contains "$(cat "$log")" "supervision is down" "the alert must name the outcome"
  pass "retry exhaustion stops retrying and alerts once through both channels"

  # The same outage must not re-alert on every re-arm.
  run_arm "$lab" 2 "$out" "$err" "$log"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a continuing outage must not alert again"
  pass "a continuing watcher outage alerts once, not once per re-arm"

  # A recovered cycle re-arms the alert, so the next outage is heard.
  printf '0\n' > "$lab/launches"
  cat > "$lab/bin/fm-watch.sh" <<WATCH
#!/usr/bin/env bash
echo "signal: $lab/state/demo.status"
exit 0
WATCH
  chmod +x "$lab/bin/fm-watch.sh"
  run_arm "$lab" 2 "$out" "$err" "$log" || fail "the recovered cycle must succeed"
  [ -e "$lab/state/.alert-watch-repair" ] && fail "a recovered cycle must re-arm the alert"
  pass "a recovered watcher re-arms the outage alert"
}

# --- 4. park alerting ---------------------------------------------------------

park_home() {  # <name>
  local home
  home=$(new_home "$1")
  mkdir -p "$home/config"
  printf 'osascript\nslack\n' > "$home/config/supervision-alert"
  printf '%s\n' "$home"
}

park_task() {  # <home> <id> <yolo> <kind> <status-lines...>
  local home=$1 id=$2 yolo=$3 kind=$4
  shift 4
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt" \
    "project=$home/projects/sample" \
    "harness=echo" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=$yolo"
  printf '%s\n' "$@" > "$home/state/$id.status"
}

park_age() {  # <home> <id> <seconds>
  local home=$1 id=$2 secs=$3 stamp
  stamp=$(date -r $(( $(date +%s) - secs )) '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || stamp=$(date -d "@$(( $(date +%s) - secs ))" '+%Y%m%d%H%M.%S')
  touch -t "$stamp" "$home/state/$id.status"
}

park_scan() {  # <home> <alert-log>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
  FM_ALERT_LOG="$2" FM_PARK_ALERT_SECS=1800 \
    bash -c '. "$1/bin/fm-watch.sh"; park_alert_scan' _ "$ROOT"
}

test_park_alerts_once() {
  local home log
  home=$(park_home park-merge)
  log="$home/alerts.log"
  park_task "$home" ship-a off ship 'working: implementing' 'done: PR https://x/1 checks green'

  park_age "$home" ship-a 600
  park_scan "$home" "$log"
  [ "$(alert_lines "$log")" = 0 ] || fail "a wait inside the threshold must not alert"
  pass "work waiting less than the threshold is not a park"

  park_age "$home" ship-a 2400
  park_scan "$home" "$log"
  [ "$(alert_lines "$log" osascript)" = 1 ] || fail "a parked merge decision must alert on macOS"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a parked merge decision must alert on slack"
  assert_contains "$(cat "$log")" "waiting for a merge decision" "the alert must name the gate"
  assert_contains "$(cat "$log")" "ship-a" "the alert must name the work"

  park_scan "$home" "$log"
  park_scan "$home" "$log"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a continuing park must alert exactly once"
  pass "a merge decision parked past the threshold alerts exactly once"

  # Landing the work re-arms the detector for the next park.
  printf 'done: merged\n' >> "$home/state/ship-a.status"
  park_scan "$home" "$log"
  [ -e "$home/state/.park-alerted-ship-a" ] && fail "a cleared gate must re-arm park alerting"
  pass "clearing the gate re-arms park alerting"
}

test_park_open_decision() {
  local home log
  home=$(park_home park-decision)
  log="$home/alerts.log"
  park_task "$home" ship-d off ship 'working: implementing' 'needs-decision [key=api]: which shape?'
  park_age "$home" ship-d 2400
  park_scan "$home" "$log"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "an open decision parked past the threshold must alert"
  assert_contains "$(cat "$log")" "waiting on a decision" "the alert must name the decision gate"
  pass "a worker waiting on a decision past the threshold alerts once"

  printf 'resolved [key=api]: chose the narrow shape\nworking: applying it\n' \
    >> "$home/state/ship-d.status"
  park_age "$home" ship-d 2400
  park_scan "$home" "$log"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a resolved decision must not alert again"
  pass "a resolved decision stops counting as a park"
}

test_park_batch_collapses() {
  local home log id
  home=$(park_home park-batch)
  log="$home/alerts.log"
  park_task "$home" ship-1 off ship 'done: PR https://x/1 checks green'
  park_task "$home" ship-2 off ship 'done: PR https://x/2 checks green'
  park_task "$home" ship-3 off ship 'needs-decision [key=api]: which shape?'
  for id in ship-1 ship-2 ship-3; do
    park_age "$home" "$id" 2400
  done

  park_scan "$home" "$log"
  [ "$(alert_lines "$log" osascript)" = 1 ] || fail "a parked batch must raise one macOS alert"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a parked batch must raise one slack alert"
  for id in ship-1 ship-2 ship-3; do
    assert_contains "$(cat "$log")" "$id has been waiting" "the collapsed alert must name $id"
  done
  assert_contains "$(cat "$log")" "waiting for a merge decision" "the collapsed alert must name each gate"
  assert_contains "$(cat "$log")" "waiting on a decision" "the collapsed alert must name each gate"
  pass "a scan collapses every parked task into one alert per channel"

  # A task that parks later still alerts, and the already-reported ones stay quiet.
  : > "$log"
  park_task "$home" ship-4 off ship 'done: PR https://x/4 checks green'
  park_age "$home" ship-4 2400
  park_scan "$home" "$log"
  [ "$(alert_lines "$log" slack)" = 1 ] || fail "a newly parked task must still alert"
  assert_contains "$(cat "$log")" "ship-4 has been waiting" "the later alert must name the new park"
  assert_not_contains "$(cat "$log")" "ship-1" "an already-reported park must not repeat"
  pass "per-task dedup survives collapsing, so a later park alerts on its own"
}

test_park_exclusions() {
  local home log
  home=$(park_home park-exclusions)
  log="$home/alerts.log"

  # Ordinary working and validation time.
  park_task "$home" ship-w off ship 'working: no-mistakes running'
  # A declared external wait that clears on its own.
  park_task "$home" ship-p off ship 'paused: waiting on an upstream release'
  # An idle secondmate, which is idle by contract.
  park_task "$home" mate-1 off secondmate 'done: PR https://x/2 checks green'
  # Work firstmate may merge itself under standing authority.
  park_task "$home" ship-y on ship 'done: PR https://x/3 checks green'
  # A worker blocked on firstmate, which already surfaces as a wake.
  park_task "$home" ship-b off ship 'blocked: needs a credential'
  for id in ship-w ship-p mate-1 ship-y ship-b; do
    park_age "$home" "$id" 7200
  done
  park_scan "$home" "$log"
  [ "$(alert_lines "$log")" = 0 ] || fail "no ineligible wait may alert: $(cat "$log")"
  pass "working time, declared waits, idle secondmates, standing authority, and blockers never alert"

  # A queue item with no task of its own has nothing waiting on a person.
  rm -f "$home"/state/*.meta
  printf 'done: PR https://x/4 checks green\n' > "$home/state/orphan.status"
  park_age "$home" orphan 7200
  park_scan "$home" "$log"
  [ "$(alert_lines "$log")" = 0 ] || fail "a status with no task record must not alert"
  pass "an action-free queue item never alerts"
}

test_channels_and_isolation
test_slack_credential_boundary
test_repair_succeeds
test_repair_exhaustion_alerts
test_park_alerts_once
test_park_open_decision
test_park_batch_collapses
test_park_exclusions

pass "fm-supervision-alert.test.sh"
