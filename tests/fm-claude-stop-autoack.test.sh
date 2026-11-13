#!/usr/bin/env bash
# Fork Stop-hook acknowledgement seam regressions.
# Only actionable arms, their immediate successor, and a host boundary are
# needed here; unrelated upstream simulator modes stay in their own suite.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoack)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-omp-process-lib.sh" "$dir/bin/fm-omp-process-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-lease-lib.sh" "$dir/bin/fm-lease-lib.sh"
  cp "$ROOT/bin/fm-afk-contract.sh" "$dir/bin/fm-afk-contract.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh" "$dir/bin/fm-afk-contract.sh"
}


make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/config/supervision-host-off"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}


run_autoarm() {
  local dir=$1 payload=${2:-'{"session_id":"sess-autoarm","stop_hook_active":false}'} rc=0
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}


write_arm_fixture() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'arm=%s predecessor=%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID" >> "$FM_HOME/state/successor-ran"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

write_host_fixture() {
  local dir=$1
  cat > "$dir/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'supervision-host: cycle boundary - fixture\n'
exit 0
SH
  chmod +x "$dir/bin/fm-supervision-host.sh"
}

# --- fork seam: ring-time acknowledgement (bin/fm-wake-autoack.sh) -----------------
# The hook only owns the seam; the script's own suite owns what is acknowledged.
# Here a stub script answers from state/autoack-plan, one exit status per line
# (0 acknowledged, 1 nothing done, 3 hand back with state/autoack-carry), and
# records each call in state/autoack-ran, so every ordering is set by the plan.
write_autoack_stub() {  # <dir> <plan lines...>
  local dir=$1
  shift
  printf '%s\n' "$@" > "$dir/state/autoack-plan"
  printf 'carried presentation line\n' > "$dir/state/autoack-carry"
  cat > "$dir/bin/fm-wake-autoack.sh" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >> "$FM_HOME/state/autoack-ran"
rc=$(sed -n '1p' "$FM_HOME/state/autoack-plan")
sed -i.bak '1d' "$FM_HOME/state/autoack-plan" && rm -f "$FM_HOME/state/autoack-plan.bak"
[ "${rc:-1}" != 3 ] || cat "$FM_HOME/state/autoack-carry"
exit "${rc:-1}"
SH
  chmod +x "$dir/bin/fm-wake-autoack.sh"
}

count_lines() {  # <file>
  awk 'END { print NR }' "$1" 2>/dev/null || printf 0
}

test_autoack_acknowledged_wake_rearms_instead_of_ringing() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-rearm")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_autoack_stub "$dir" 0 1
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "the wake that still needs a turn must ring after an acknowledged one"
  [ "$(count_lines "$dir/state/arm-ran")" = 2 ] || fail "an acknowledged wake must run the arm again, got: $(cat "$dir/state/arm-ran")"
  [ "$(count_lines "$dir/state/autoack-ran")" = 2 ] || fail "each actionable close must ask the seam once"
  assert_contains "$out" "1 earlier wake(s) were acknowledged without a model turn" "the banner must say what was acknowledged"
  [ "$(count_lines "$dir/state/successor-ran")" = 1 ] \
    || fail "only the ringing close may start a handling successor, got: $(cat "$dir/state/successor-ran" 2>/dev/null)"
  pass "auto-arm: an acknowledged wake re-arms in the same hook and the next real wake rings with a note"
}

test_autoack_hand_back_carries_the_presentation() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-carry")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_autoack_stub "$dir" 3
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a hand-back must ring"
  assert_contains "$out" "carried presentation line" "the consumed presentation must reach the model verbatim"
  assert_contains "$out" "bin/fm-wake-drain.sh" "the banner must keep the drain-first protocol"
  [ "$(count_lines "$dir/state/arm-ran")" = 1 ] || fail "a hand-back must not re-arm"
  pass "auto-arm: a presentation the seam consumed but could not acknowledge is carried into the banner"
}

test_autoack_hand_back_preserves_large_presentation() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-large-carry")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_autoack_stub "$dir" 3
  {
    printf 'large carry start\n'
    awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }'
    printf '\nlarge carry end\n'
  } > "$dir/state/autoack-carry"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a large hand-back must ring"
  assert_contains "$out" "large carry end" "the complete large presentation must reach the model"
  pass "auto-arm: a large hand-back presentation is preserved"
}

test_autoack_nothing_done_rings_as_before() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-none")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_autoack_stub "$dir" 1
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable wake the seam leaves alone must ring"
  case "$out" in
    *"earlier wake(s)"*|*"carried presentation"*) fail "an untouched wake must not claim an acknowledgement or a carry: $out" ;;
  esac
  assert_contains "$out" "stale: fixture-win actionable" "the ring must keep the arm's reason line"
  pass "auto-arm: a wake the seam leaves alone rings exactly as before"
}

test_autoack_absent_script_rings_as_before() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-absent")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a home without the seam script must ring as before"
  [ "$(count_lines "$dir/state/arm-ran")" = 1 ] || fail "no seam, no re-arm"
  pass "auto-arm: a missing seam script changes nothing"
}

test_autoack_consecutive_acknowledgements_are_bounded() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-bounded")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_autoack_stub "$dir" 0 0 0 0 0
  out=$(FM_WAKE_AUTOACK_MAX=2 run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "after the bound the wake must ring"
  [ "$(count_lines "$dir/state/autoack-ran")" = 2 ] || fail "the seam must not be asked past its bound, got: $(cat "$dir/state/autoack-ran")"
  assert_contains "$out" "auto-ack cap reached after 2 acknowledged wake(s) this cycle; repeating wake sources:" "the banner must identify the cap and acknowledged count"
  assert_contains "$out" "stale: fixture-win actionable" "the cap banner must retain the repeating wake source"
  pass "auto-arm: the acknowledgement cap backstops loops and names repeating wakes"
}

test_autoack_host_line_is_never_acknowledged() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-host")
  mkdir -p "$dir/config"
  rm -f "$dir/config/supervision-host-off"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" boundary
  write_autoack_stub "$dir" 0 0
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a host line must ring"
  assert_contains "$out" "supervision-host: cycle boundary - fixture" "the host line must reach the model"
  [ ! -e "$dir/state/autoack-ran" ] || fail "a supervision-host line must never be offered to the seam"
  pass "auto-arm: a supervision-host line is never offered for acknowledgement"
}

test_autoack_superseded_owner_never_acknowledges() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/autoack-superseded")
  : > "$dir/state/task.meta"
  # The arm supersedes this generation before it closes with an actionable wake.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'epoch=999 owner_pid=1 outcome=arming updated_at=%s\nfixture-superseder-identity\n' "$(date +%s)" > "$FM_HOME/state/.claude-autoarm-epoch"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  write_autoack_stub "$dir" 0
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a superseded owner must go silent"
  [ -z "$out" ] || fail "a superseded owner printed output: $out"
  [ ! -e "$dir/state/autoack-ran" ] || fail "a superseded owner must never drain or acknowledge"
  pass "auto-arm: a superseded owner never reaches the acknowledgement seam"
}

test_autoack_acknowledged_wake_rearms_instead_of_ringing
test_autoack_hand_back_carries_the_presentation
test_autoack_hand_back_preserves_large_presentation
test_autoack_nothing_done_rings_as_before
test_autoack_absent_script_rings_as_before
test_autoack_consecutive_acknowledgements_are_bounded
test_autoack_host_line_is_never_acknowledged
test_autoack_superseded_owner_never_acknowledges
