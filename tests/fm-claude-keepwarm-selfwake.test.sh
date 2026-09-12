#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned supervisor keep-warm self-wake
# (bin/fm-claude-keepwarm-selfwake.sh) and the cadence cap it shares with the
# crew keep-warm (bin/fm-keepwarm-cadence-lib.sh).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it
# hermetically as a child of a fake harness (a bash symlink named "claude", or
# "codex" for the non-Claude case) whose pid is written into the fixture home's
# state/.lock, with a seconds-scale interval so the deadline is exercised for
# real: a wake at the deadline is an observed exit 2 with the marked banner,
# and a cancelled wake is an observed exit 0 before the deadline.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-keepwarm-selfwake)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
ln -s /bin/bash "$FAKEBIN/codex"
FAKE_CLAUDE="$FAKEBIN/claude"
FAKE_CODEX="$FAKEBIN/codex"

# Every sleeper started here is stopped at exit so a long-deadline case cannot
# outlive the test.
SLEEPERS="$TMP_ROOT/sleepers"
: > "$SLEEPERS"
stop_sleepers() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done < "$SLEEPERS"
  true
}
trap 'stop_sleepers; fm_test_cleanup' EXIT

install_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-keepwarm-selfwake.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-keepwarm-cadence-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-claude-keepwarm-selfwake.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-keepwarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/keepwarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook in the background as a child of a fake harness ($2) that writes
# its own pid into the fixture's session lock (lock mode `own`) or leaves the
# lock alone (`keep`). The hook's combined output lands in $3.out and its exit
# code in $3.rc once it ends. Extra env is inherited from the caller.
start_hook() {  # <dir> <harness-bin> <record-prefix> [lock-mode]
  local dir=$1 harness=$2 rec=$3 lock_mode=${4:-own}
  (
    rc=0
    printf '%s\n' '{"session_id":"sess-keepwarm","stop_hook_active":false}' \
      | FM_HOME="$dir" FM_LOCK_MODE="$lock_mode" "$harness" -c '
          case "$FM_LOCK_MODE" in
            own) printf "%s\n" "$$" > "$FM_HOME/state/.lock" ;;
            keep) : ;;
          esac
          "$FM_HOME/bin/fm-claude-keepwarm-selfwake.sh"
        ' > "$rec.out" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$rec.rc"
  ) &
  printf '%s\n' "$!" >> "$SLEEPERS"
}

wait_rc() {  # <record-prefix> <max-seconds>
  local rec=$1 max=$2 i=0
  while [ ! -f "$rec.rc" ]; do
    i=$((i + 1))
    [ "$i" -le $((max * 10)) ] || return 1
    sleep 0.1
  done
  cat "$rec.rc"
}

wait_marker() {  # <dir>
  local i=0
  while [ ! -s "$1/state/.keepwarm-selfwake" ]; do
    i=$((i + 1))
    [ "$i" -le 20 ] || return 1
    sleep 0.1
  done
}

marker_line() {  # <dir> <n>
  sed -n "${2}p" "$1/state/.keepwarm-selfwake"
}

stop_marker_owner() {  # <dir>
  local pid
  pid=$(marker_line "$1" 2)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  true
}

BANNER_PREFIX=$'\xE2\x81\xA3FIRSTMATE_OP: v1 keep-warm: '

# --- a live idle Claude supervisor takes the turn at the deadline -------------

test_fires_at_deadline() {
  local dir rc out t0 t1
  dir=$(make_primary_dir "$TMP_ROOT/fires")
  t0=$(date +%s)
  FM_NM_KEEPWARM_SECS=2 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/fires-rec"
  rc=$(wait_rc "$TMP_ROOT/fires-rec" 15) || fail "hook did not finish within 15s"
  t1=$(date +%s)
  out=$(cat "$TMP_ROOT/fires-rec.out")
  expect_code 2 "$rc" "an idle Claude supervisor must be woken at the deadline"
  [ $((t1 - t0)) -ge 2 ] || fail "the wake fired before the 2s deadline (${t1}-${t0})"
  assert_contains "$out" "$BANNER_PREFIX" "the wake must carry the marked keep-warm operational input"
  assert_contains "$out" "Do not run the wake drain" "the wake must be benign toward wakes, decisions, and gates"
  assert_not_contains "$out" "captain," "the wake must not address the captain"
  pass "self-wake: a live idle Claude supervisor gets one native wake at the deadline"
}

test_secondmate_home_fires() {
  local dir rc out
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/secondmate-rec"
  rc=$(wait_rc "$TMP_ROOT/secondmate-rec" 15) || fail "secondmate hook did not finish"
  out=$(cat "$TMP_ROOT/secondmate-rec.out")
  expect_code 2 "$rc" "a secondmate primary is a supervisor and gets the wake in its own home"
  assert_contains "$out" "$BANNER_PREFIX" "secondmate wake must be the marked banner"
  pass "self-wake: a secondmate's own Claude primary self-warms in its own home"
}

# --- the deadline is bounded to the shared 50-minute cap ----------------------

test_deadline_bounded_to_cap() {
  local dir anchor deadline
  dir=$(make_primary_dir "$TMP_ROOT/cap")
  FM_NM_KEEPWARM_SECS=7200 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/cap-rec"
  wait_marker "$dir" || fail "the hook did not record its arm"
  anchor=$(marker_line "$dir" 1)
  deadline=$(marker_line "$dir" 3)
  [ $((deadline - anchor)) -eq 3000 ] \
    || fail "a 7200s request must be clamped to the 3000s cap, got $((deadline - anchor))"
  [ -f "$TMP_ROOT/cap-rec.rc" ] && fail "the hook must still be sleeping toward the capped deadline"
  stop_marker_owner "$dir"
  pass "self-wake: the deadline never exceeds 50 minutes after the turn boundary"
}

test_default_interval_is_thirty_minutes() {
  local dir anchor deadline
  dir=$(make_primary_dir "$TMP_ROOT/default")
  (unset FM_NM_KEEPWARM_SECS; start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/default-rec")
  wait_marker "$dir" || fail "the hook did not record its arm"
  anchor=$(marker_line "$dir" 1)
  deadline=$(marker_line "$dir" 3)
  [ $((deadline - anchor)) -eq 1800 ] \
    || fail "the default deadline must be 1800s after the turn boundary, got $((deadline - anchor))"
  stop_marker_owner "$dir"
  pass "self-wake: the unconfigured deadline is last turn + 1800s"
}

# --- a real turn cancels the pending wake and re-arms ------------------------

test_real_turn_cancels_and_rearms() {
  local dir rc_a rc_b out_a out_b
  dir=$(make_primary_dir "$TMP_ROOT/cancel")
  FM_NM_KEEPWARM_SECS=40 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/cancel-a"
  wait_marker "$dir" || fail "first arm did not record"
  sleep 1
  # A real turn ended: the next Stop fires the hook again from the same session.
  FM_NM_KEEPWARM_SECS=40 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/cancel-b"
  rc_a=$(wait_rc "$TMP_ROOT/cancel-a" 35) || fail "the superseded sleeper must stand down within the fixed poll interval"
  out_a=$(cat "$TMP_ROOT/cancel-a.out")
  expect_code 0 "$rc_a" "the superseded wake must be cancelled silently"
  [ -z "$out_a" ] || fail "a cancelled wake must print nothing: $out_a"
  rc_b=$(wait_rc "$TMP_ROOT/cancel-b" 50) || fail "the re-armed wake did not fire"
  out_b=$(cat "$TMP_ROOT/cancel-b.out")
  expect_code 2 "$rc_b" "the re-armed wake fires at its own deadline"
  assert_contains "$out_b" "$BANNER_PREFIX" "the re-armed wake must be the marked banner"
  pass "self-wake: a real turn cancels the pending wake and arms a fresh one"
}

# --- no live Claude supervisor: no-op ------------------------------------------

test_no_live_supervisor_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/nolock")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/nolock-rec" keep
  rc=$(wait_rc "$TMP_ROOT/nolock-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a home with no session lock has no live supervisor"
  assert_absent "$dir/state/.keepwarm-selfwake" "no arm may be recorded without a live supervisor"
  [ -s "$TMP_ROOT/nolock-rec.out" ] && fail "a no-op must be silent: $(cat "$TMP_ROOT/nolock-rec.out")"

  dir=$(make_primary_dir "$TMP_ROOT/deadlock")
  printf '%s\n' 2147483000 > "$dir/state/.lock"
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/deadlock-rec" keep
  rc=$(wait_rc "$TMP_ROOT/deadlock-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a lock held by another (dead) pid is not this session's supervision"
  assert_absent "$dir/state/.keepwarm-selfwake" "a foreign lock must not arm"
  pass "self-wake: no live Claude supervisor session means no-op"
}

test_lock_handover_cancels_pending_wake() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/handover")
  FM_NM_KEEPWARM_SECS=4 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/handover-rec"
  wait_marker "$dir" || fail "arm did not record"
  # The session lock passes to another live process: the armed session is no
  # longer the supervisor, so its pending wake must not fire.
  printf '%s\n' "$$" > "$dir/state/.lock"
  rc=$(wait_rc "$TMP_ROOT/handover-rec" 15) || fail "hook did not finish"
  expect_code 0 "$rc" "a session that lost the lock must not wake"
  [ -s "$TMP_ROOT/handover-rec.out" ] && fail "a stood-down wake must be silent"
  pass "self-wake: losing the session lock cancels the pending wake"
}

# --- Claude-only gate ------------------------------------------------------------

test_non_claude_supervisor_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/codex")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$FAKE_CODEX" "$TMP_ROOT/codex-rec"
  rc=$(wait_rc "$TMP_ROOT/codex-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a non-Claude primary must be a no-op even when it owns the lock"
  assert_absent "$dir/state/.keepwarm-selfwake" "a non-Claude primary must not arm"
  pass "self-wake: a non-Claude supervisor is a no-op regardless of config"
}

test_config_cannot_widen_the_claude_gate() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/codex-cfg")
  FM_NM_KEEPWARM_HARNESSES='codex claude' FM_NM_KEEPWARM_SECS=1 \
    start_hook "$dir" "$FAKE_CODEX" "$TMP_ROOT/codex-cfg-rec"
  rc=$(wait_rc "$TMP_ROOT/codex-cfg-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "the crew harness opt-in list must not widen the supervisor path"
  assert_absent "$dir/state/.keepwarm-selfwake" "config must not arm a non-Claude supervisor"
  pass "self-wake: FM_NM_KEEPWARM_HARNESSES does not widen the hard Claude-only gate"
}

test_disabled_home_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/disabled")
  FM_NM_KEEPWARM_SECS=0 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/disabled-rec"
  rc=$(wait_rc "$TMP_ROOT/disabled-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "FM_NM_KEEPWARM_SECS=0 must disable the self-wake"
  assert_absent "$dir/state/.keepwarm-selfwake" "a disabled home must not arm"
  pass "self-wake: FM_NM_KEEPWARM_SECS=0 disables the supervisor path"
}

test_crewmate_worktree_is_inert() {
  local base dir rc
  base=$(make_primary_dir "$TMP_ROOT/crew-base")
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/crew-wt")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$FAKE_CLAUDE" "$TMP_ROOT/crew-rec"
  rc=$(wait_rc "$TMP_ROOT/crew-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a crew worktree is not a supervisor home"
  assert_absent "$dir/state/.keepwarm-selfwake" "a crew worktree must not arm"
  pass "self-wake: a crewmate worktree stays inert (crew keep-warm is the watcher-side library)"
}

test_cursor_payload_stands_down() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/cursor")
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  rc=0
  printf '%s\n' '{"cursor_version":"2026.08.11","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_NM_KEEPWARM_SECS=1 "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-keepwarm-selfwake.sh"
      ' > "$TMP_ROOT/cursor.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "a Cursor-delivered payload must stand down"
  assert_absent "$dir/state/.keepwarm-selfwake" "a Cursor-delivered payload must not arm"
  pass "self-wake: a Cursor-delivered payload stands down"
}

test_missing_jq_stands_down() {
  local dir rc no_jq_path
  dir=$(make_primary_dir "$TMP_ROOT/no-jq")
  no_jq_path=$(fm_test_base_path_sans "${PATH:-}" jq)
  rc=0
  printf '%s\n' '{"session_id":"sess-keepwarm","stop_hook_active":false}' \
    | PATH="$no_jq_path" FM_HOME="$dir" FM_NM_KEEPWARM_SECS=1 "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-keepwarm-selfwake.sh"
      ' > "$TMP_ROOT/no-jq.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "the self-wake must stand down when jq is unavailable"
  assert_absent "$dir/state/.keepwarm-selfwake" "missing jq must not allow a self-wake to arm"
  pass "self-wake: missing jq fails closed before arming"
}

# --- the crew keep-warm shares the same cap ----------------------------------------

test_crew_keepwarm_shares_cap() {
  local v
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-nm-keepwarm-lib.sh"
  v=$(FM_NM_KEEPWARM_SECS=7200 fm_nm_keepwarm_interval_secs)
  [ "$v" = 3000 ] || fail "the crew interval must clamp to the shared 3000s cap, got $v"
  v=$(FM_NM_KEEPWARM_SECS=3000 fm_nm_keepwarm_interval_secs)
  [ "$v" = 3000 ] || fail "3000s is the cap itself and must pass through, got $v"
  v=$(FM_NM_KEEPWARM_SECS=600 fm_nm_keepwarm_interval_secs)
  [ "$v" = 600 ] || fail "a request under the cap must pass through, got $v"
  v=$(FM_NM_KEEPWARM_SECS=008 fm_nm_keepwarm_interval_secs)
  [ "$v" = 8 ] || fail "a leading-zero request must be normalized to decimal, got $v"
  v=$(FM_NM_KEEPWARM_SECS=000 fm_nm_keepwarm_interval_secs)
  [ "$v" = 0 ] || fail "an all-zero request must remain disabled, got $v"
  v=$(FM_NM_KEEPWARM_SECS=0 fm_nm_keepwarm_interval_secs)
  [ "$v" = 0 ] || fail "0 must still disable, got $v"
  v=$(env -u FM_NM_KEEPWARM_SECS bash -c ". '$ROOT/bin/fm-keepwarm-cadence-lib.sh'; fm_keepwarm_interval_secs")
  [ "$v" = 1800 ] || fail "the shared default must stay 1800, got $v"
  pass "crew keep-warm and supervisor self-wake share one 3000s cadence cap"
}

test_fires_at_deadline
test_secondmate_home_fires
test_deadline_bounded_to_cap
test_default_interval_is_thirty_minutes
test_real_turn_cancels_and_rearms
test_no_live_supervisor_is_noop
test_lock_handover_cancels_pending_wake
test_non_claude_supervisor_is_noop
test_config_cannot_widen_the_claude_gate
test_disabled_home_is_noop
test_crewmate_worktree_is_inert
test_cursor_payload_stands_down
test_missing_jq_stands_down
test_crew_keepwarm_shares_cap
