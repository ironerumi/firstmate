#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned keep-warm self-wake
# (bin/fm-claude-keepwarm-selfwake.sh) and its cadence cap
# (bin/fm-keepwarm-cadence-lib.sh).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it
# hermetically with a Claude-shaped Stop payload on stdin and a seconds-scale
# interval so the deadline is exercised for real: a wake at the deadline is an
# observed exit 2 with the marked banner, and a cancelled wake is an observed
# exit 0 before the deadline. The bare form is the tracked supervisor
# registration; `--task <id>` is the per-crew form bin/fm-spawn.sh injects
# (tests/fm-spawn-claude-attribution.test.sh covers that injection end to end).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-keepwarm-selfwake)
fm_git_identity fmtest fmtest@example.invalid

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

CLAUDE_PAYLOAD='{"session_id":"sess-keepwarm","stop_hook_active":false}'

# Run the hook in the background with a Claude-shaped Stop payload. Its
# combined output lands in $2.out and its exit code in $2.rc once it ends.
# Extra env is inherited from the caller; remaining arguments are the hook's.
start_hook() {  # <dir> <record-prefix> [hook-args...]
  local dir=$1 rec=$2
  shift 2
  (
    rc=0
    printf '%s\n' "$CLAUDE_PAYLOAD" \
      | FM_HOME="$dir" "$dir/bin/fm-claude-keepwarm-selfwake.sh" "$@" > "$rec.out" 2>&1 || rc=$?
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

wait_marker() {  # <marker-path>
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1))
    [ "$i" -le 20 ] || return 1
    sleep 0.1
  done
}

marker_line() {  # <marker-path> <n>
  sed -n "${2}p" "$1"
}

stop_marker_owner() {  # <marker-path>
  local pid
  pid=$(marker_line "$1" 2)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  true
}

BANNER_PREFIX=$'\xE2\x81\xA3FIRSTMATE_OP: v1 keep-warm: '

# --- an idle Claude supervisor takes the turn at the deadline ------------------

test_fires_at_deadline() {
  local dir rc out t0 t1
  dir=$(make_primary_dir "$TMP_ROOT/fires")
  t0=$(date +%s)
  FM_NM_KEEPWARM_SECS=2 start_hook "$dir" "$TMP_ROOT/fires-rec"
  rc=$(wait_rc "$TMP_ROOT/fires-rec" 15) || fail "hook did not finish within 15s"
  t1=$(date +%s)
  out=$(cat "$TMP_ROOT/fires-rec.out")
  expect_code 2 "$rc" "an idle Claude supervisor must be woken at the deadline"
  [ $((t1 - t0)) -ge 2 ] || fail "the wake fired before the 2s deadline (${t1}-${t0})"
  assert_contains "$out" "$BANNER_PREFIX" "the wake must carry the marked keep-warm operational input"
  assert_contains "$out" "Do not run the wake drain" "the wake must be benign toward wakes, decisions, and gates"
  assert_not_contains "$out" "captain," "the wake must not address the captain"
  pass "self-wake: an idle Claude supervisor gets one native wake at the deadline"
}

test_secondmate_home_fires() {
  local dir rc out
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/secondmate-rec"
  rc=$(wait_rc "$TMP_ROOT/secondmate-rec" 15) || fail "secondmate hook did not finish"
  out=$(cat "$TMP_ROOT/secondmate-rec.out")
  expect_code 2 "$rc" "a secondmate primary is a supervisor and gets the wake in its own home"
  assert_contains "$out" "$BANNER_PREFIX" "secondmate wake must be the marked banner"
  pass "self-wake: a secondmate's own Claude primary self-warms in its own home"
}

# --- an idle Claude crew takes the same turn through its --task form -----------

test_crew_task_form_fires_with_its_own_marker() {
  local dir rc out
  dir=$(make_primary_dir "$TMP_ROOT/crew-task")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/crew-task-rec" --task crew-42
  rc=$(wait_rc "$TMP_ROOT/crew-task-rec" 15) || fail "crew hook did not finish"
  out=$(cat "$TMP_ROOT/crew-task-rec.out")
  expect_code 2 "$rc" "an idle Claude crew must be woken at the deadline"
  assert_contains "$out" "$BANNER_PREFIX" "the crew wake must be the marked banner"
  assert_contains "$out" "respond to a validation gate" "the crew wake must stay read-only toward a parked gate"
  assert_present "$dir/state/.keepwarm-crew-42" "the crew form must key its marker to the task"
  assert_absent "$dir/state/.keepwarm-selfwake" "the crew form must not touch the supervisor marker"
  pass "self-wake: a crew's --task form fires from its own task-keyed marker"
}

test_crew_task_form_fires_outside_a_primary_home() {
  local base dir rc
  base=$(make_primary_dir "$TMP_ROOT/crew-base")
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/crew-wt")
  # The crew form is the one bin/fm-spawn.sh injects, and it must warm a crew
  # sitting in any project worktree, which is never a primary home.
  FM_NM_KEEPWARM_SECS=1 FM_STATE_OVERRIDE="$base/state" \
    start_hook "$dir" "$TMP_ROOT/crew-wt-rec" --task crew-wt
  rc=$(wait_rc "$TMP_ROOT/crew-wt-rec" 15) || fail "crew hook did not finish"
  expect_code 2 "$rc" "the crew form must fire from a non-primary worktree"
  assert_present "$base/state/.keepwarm-crew-wt" "the crew marker must land in the spawning home's state dir"
  pass "self-wake: the crew form fires from a project worktree into the spawning home"
}

test_crew_and_supervisor_do_not_cancel_each_other() {
  local dir rc_s rc_c
  dir=$(make_primary_dir "$TMP_ROOT/coexist")
  FM_NM_KEEPWARM_SECS=2 start_hook "$dir" "$TMP_ROOT/coexist-s"
  wait_marker "$dir/state/.keepwarm-selfwake" || fail "supervisor arm did not record"
  FM_NM_KEEPWARM_SECS=2 start_hook "$dir" "$TMP_ROOT/coexist-c" --task crew-1
  rc_s=$(wait_rc "$TMP_ROOT/coexist-s" 15) || fail "supervisor hook did not finish"
  rc_c=$(wait_rc "$TMP_ROOT/coexist-c" 15) || fail "crew hook did not finish"
  expect_code 2 "$rc_s" "a crew's Stop must not cancel the supervisor's pending wake"
  expect_code 2 "$rc_c" "the crew's own wake must fire alongside the supervisor's"
  pass "self-wake: sessions sharing one home keep independent wakes"
}

test_bad_task_id_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/bad-task")
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/bad-task-rec" --task '../x'
  rc=$(wait_rc "$TMP_ROOT/bad-task-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a task id that cannot name a marker must be a no-op"
  [ -s "$TMP_ROOT/bad-task-rec.out" ] && fail "a no-op must be silent: $(cat "$TMP_ROOT/bad-task-rec.out")"
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/bad-arg-rec" --bogus
  rc=$(wait_rc "$TMP_ROOT/bad-arg-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "an unknown argument must be a no-op"
  pass "self-wake: a malformed task id or unknown argument stands down"
}

# --- the deadline is bounded to the shared 50-minute cap ----------------------

test_deadline_bounded_to_cap() {
  local dir marker anchor deadline
  dir=$(make_primary_dir "$TMP_ROOT/cap")
  marker="$dir/state/.keepwarm-selfwake"
  FM_NM_KEEPWARM_SECS=7200 start_hook "$dir" "$TMP_ROOT/cap-rec"
  wait_marker "$marker" || fail "the hook did not record its arm"
  anchor=$(marker_line "$marker" 1)
  deadline=$(marker_line "$marker" 3)
  [ $((deadline - anchor)) -eq 3000 ] \
    || fail "a 7200s request must be clamped to the 3000s cap, got $((deadline - anchor))"
  [ -f "$TMP_ROOT/cap-rec.rc" ] && fail "the hook must still be sleeping toward the capped deadline"
  stop_marker_owner "$marker"
  pass "self-wake: the deadline never exceeds 50 minutes after the turn boundary"
}

test_default_interval_is_thirty_minutes() {
  local dir marker anchor deadline
  dir=$(make_primary_dir "$TMP_ROOT/default")
  marker="$dir/state/.keepwarm-selfwake"
  (unset FM_NM_KEEPWARM_SECS; start_hook "$dir" "$TMP_ROOT/default-rec")
  wait_marker "$marker" || fail "the hook did not record its arm"
  anchor=$(marker_line "$marker" 1)
  deadline=$(marker_line "$marker" 3)
  [ $((deadline - anchor)) -eq 1800 ] \
    || fail "the default deadline must be 1800s after the turn boundary, got $((deadline - anchor))"
  stop_marker_owner "$marker"
  pass "self-wake: the unconfigured deadline is last turn + 1800s"
}

# --- a real turn cancels the pending wake and re-arms ------------------------

test_real_turn_cancels_and_rearms() {
  local dir rc_a rc_b out_a out_b
  dir=$(make_primary_dir "$TMP_ROOT/cancel")
  FM_NM_KEEPWARM_SECS=40 start_hook "$dir" "$TMP_ROOT/cancel-a"
  wait_marker "$dir/state/.keepwarm-selfwake" || fail "first arm did not record"
  sleep 1
  # A real turn ended: the next Stop fires the hook again from the same session.
  FM_NM_KEEPWARM_SECS=40 start_hook "$dir" "$TMP_ROOT/cancel-b"
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

# --- no-op cases -----------------------------------------------------------------

test_disabled_home_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/disabled")
  FM_NM_KEEPWARM_SECS=0 start_hook "$dir" "$TMP_ROOT/disabled-rec"
  rc=$(wait_rc "$TMP_ROOT/disabled-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "FM_NM_KEEPWARM_SECS=0 must disable the self-wake"
  assert_absent "$dir/state/.keepwarm-selfwake" "a disabled home must not arm"
  FM_NM_KEEPWARM_SECS=0 start_hook "$dir" "$TMP_ROOT/disabled-crew-rec" --task crew-off
  rc=$(wait_rc "$TMP_ROOT/disabled-crew-rec" 10) || fail "crew hook did not finish"
  expect_code 0 "$rc" "FM_NM_KEEPWARM_SECS=0 must disable the crew form too"
  assert_absent "$dir/state/.keepwarm-crew-off" "a disabled home must not arm a crew"
  pass "self-wake: FM_NM_KEEPWARM_SECS=0 disables every session in the home"
}

test_bare_form_in_crewmate_worktree_is_inert() {
  local base dir rc
  base=$(make_primary_dir "$TMP_ROOT/bare-base")
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/bare-wt")
  # A firstmate-repo crew worktree loads the tracked settings too; its bare
  # entry must stand down so the crew carries only its injected --task wake.
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/bare-wt-rec"
  rc=$(wait_rc "$TMP_ROOT/bare-wt-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "the bare form is the supervisor registration and must not arm in a crew worktree"
  assert_absent "$dir/state/.keepwarm-selfwake" "the bare form must not arm outside a primary home"
  pass "self-wake: the tracked bare form stays inert in a crew worktree"
}

test_missing_state_dir_is_noop() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/nostate")
  rmdir "$dir/state"
  FM_NM_KEEPWARM_SECS=1 start_hook "$dir" "$TMP_ROOT/nostate-rec" --task crew-nostate
  rc=$(wait_rc "$TMP_ROOT/nostate-rec" 10) || fail "hook did not finish"
  expect_code 0 "$rc" "a home with no state dir has no session to keep warm"
  [ -s "$TMP_ROOT/nostate-rec.out" ] && fail "a no-op must be silent: $(cat "$TMP_ROOT/nostate-rec.out")"
  pass "self-wake: a missing state dir stands down"
}

test_cursor_payload_stands_down() {
  local dir rc
  dir=$(make_primary_dir "$TMP_ROOT/cursor")
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  rc=0
  printf '%s\n' '{"cursor_version":"2026.08.11","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_NM_KEEPWARM_SECS=1 "$dir/bin/fm-claude-keepwarm-selfwake.sh" \
    > "$TMP_ROOT/cursor.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "a Cursor-delivered payload must stand down"
  assert_absent "$dir/state/.keepwarm-selfwake" "a Cursor-delivered payload must not arm"
  rc=0
  printf '%s\n' '{"cursor_version":"2026.08.11","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_NM_KEEPWARM_SECS=1 "$dir/bin/fm-claude-keepwarm-selfwake.sh" --task crew-cursor \
    > "$TMP_ROOT/cursor-crew.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "a Cursor-delivered payload must stand down on the crew form too"
  assert_absent "$dir/state/.keepwarm-crew-cursor" "a Cursor-delivered payload must not arm a crew"
  pass "self-wake: a Cursor-delivered payload stands down on both forms"
}

test_missing_jq_stands_down() {
  local dir rc no_jq_path
  dir=$(make_primary_dir "$TMP_ROOT/no-jq")
  no_jq_path=$(fm_test_base_path_sans "${PATH:-}" jq)
  rc=0
  printf '%s\n' "$CLAUDE_PAYLOAD" \
    | PATH="$no_jq_path" FM_HOME="$dir" FM_NM_KEEPWARM_SECS=1 "$dir/bin/fm-claude-keepwarm-selfwake.sh" \
    > "$TMP_ROOT/no-jq.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "the self-wake must stand down when jq is unavailable"
  assert_absent "$dir/state/.keepwarm-selfwake" "missing jq must not allow a self-wake to arm"
  pass "self-wake: missing jq fails closed before arming"
}

# --- the cadence library --------------------------------------------------------

# Print the cadence one fresh shell resolves from <home>'s own config/ dir, with
# the environment variable cleared, so these cases never read the real repo
# config (or an ambient FM_NM_KEEPWARM_SECS) by accident.
config_interval() {  # <home-dir> [extra env assignments...]
  local home=$1
  shift
  env -u FM_NM_KEEPWARM_SECS FM_HOME="$home" "$@" \
    bash -c ". '$ROOT/bin/fm-keepwarm-cadence-lib.sh'; fm_keepwarm_interval_secs"
}

test_cadence_cap() {
  local v
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-keepwarm-cadence-lib.sh"
  v=$(FM_NM_KEEPWARM_SECS=7200 fm_keepwarm_interval_secs)
  [ "$v" = 3000 ] || fail "the interval must clamp to the 3000s cap, got $v"
  v=$(FM_NM_KEEPWARM_SECS=3000 fm_keepwarm_interval_secs)
  [ "$v" = 3000 ] || fail "3000s is the cap itself and must pass through, got $v"
  v=$(FM_NM_KEEPWARM_SECS=600 fm_keepwarm_interval_secs)
  [ "$v" = 600 ] || fail "a request under the cap must pass through, got $v"
  v=$(FM_NM_KEEPWARM_SECS=008 fm_keepwarm_interval_secs)
  [ "$v" = 8 ] || fail "a leading-zero request must be normalized to decimal, got $v"
  v=$(FM_NM_KEEPWARM_SECS=000 fm_keepwarm_interval_secs)
  [ "$v" = 0 ] || fail "an all-zero request must remain disabled, got $v"
  v=$(FM_NM_KEEPWARM_SECS=abc fm_keepwarm_interval_secs)
  [ "$v" = 1800 ] || fail "a non-numeric request must fall back to the default, got $v"
  v=$(config_interval "$TMP_ROOT/no-config-home")
  [ "$v" = 1800 ] || fail "the default must stay 1800, got $v"
  pass "cadence: one interval with a 3000s cap for every Claude session"
}

# The home-local file is the captain-facing knob: it sets the cadence for a home
# without exporting anything into a shell or launch environment, and the
# environment variable stays the per-process override above it.
test_cadence_config_file() {
  local dir v
  dir="$TMP_ROOT/cadence-config"
  mkdir -p "$dir/config"

  printf '3000\n' > "$dir/config/keepwarm-secs"
  v=$(FM_HOME="$dir" FM_NM_KEEPWARM_SECS=600 bash -c ". '$ROOT/bin/fm-keepwarm-cadence-lib.sh'; fm_keepwarm_interval_secs")
  [ "$v" = 600 ] || fail "FM_NM_KEEPWARM_SECS must win over config/keepwarm-secs, got $v"
  v=$(config_interval "$dir")
  [ "$v" = 3000 ] || fail "config/keepwarm-secs must supply the interval when the env var is unset, got $v"
  v=$(config_interval "$TMP_ROOT/other-home" FM_CONFIG_OVERRIDE="$dir/config")
  [ "$v" = 3000 ] || fail "FM_CONFIG_OVERRIDE must select which home's config/keepwarm-secs is read, got $v"

  printf '7200\n' > "$dir/config/keepwarm-secs"
  v=$(config_interval "$dir")
  [ "$v" = 3000 ] || fail "a config-sourced request above the cap must clamp to 3000, got $v"
  printf '0\n' > "$dir/config/keepwarm-secs"
  v=$(config_interval "$dir")
  [ "$v" = 0 ] || fail "a config-sourced 0 must disable keep-warm, got $v"
  printf '008\n' > "$dir/config/keepwarm-secs"
  v=$(config_interval "$dir")
  [ "$v" = 8 ] || fail "a config-sourced leading-zero value must be normalized, got $v"

  for bad in 'abc' '' '12 34' '-5' '3.5'; do
    printf '%s\n' "$bad" > "$dir/config/keepwarm-secs"
    v=$(config_interval "$dir")
    [ "$v" = 1800 ] || fail "an invalid config value ('$bad') must fall back to the default, got $v"
  done
  rm -f "$dir/config/keepwarm-secs"
  v=$(config_interval "$dir")
  [ "$v" = 1800 ] || fail "an absent config file must fall back to the default, got $v"
  pass "cadence: config/keepwarm-secs sets the interval under the env var, with the same cap, disable, and invalid-value rules"
}

# The knob must reach a secondmate home too, or a secondmate's own supervisor
# session and crews would silently drift back to the default cadence.
test_keepwarm_config_is_inherited() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  case " $FM_INHERITABLE_CONFIG " in
    *" keepwarm-secs "*) : ;;
    *) fail "config/keepwarm-secs must be in FM_INHERITABLE_CONFIG so secondmate homes keep the primary's cadence" ;;
  esac
  pass "cadence: config/keepwarm-secs is inherited into secondmate homes"
}

test_fires_at_deadline
test_secondmate_home_fires
test_crew_task_form_fires_with_its_own_marker
test_crew_task_form_fires_outside_a_primary_home
test_crew_and_supervisor_do_not_cancel_each_other
test_bad_task_id_is_noop
test_deadline_bounded_to_cap
test_default_interval_is_thirty_minutes
test_real_turn_cancels_and_rearms
test_disabled_home_is_noop
test_bare_form_in_crewmate_worktree_is_inert
test_missing_state_dir_is_noop
test_cursor_payload_stands_down
test_missing_jq_stands_down
test_cadence_cap
test_cadence_config_file
test_keepwarm_config_is_inherited

echo "# all fm-claude-keepwarm-selfwake tests passed"
