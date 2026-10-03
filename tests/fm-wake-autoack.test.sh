#!/usr/bin/env bash
# tests/fm-wake-autoack.test.sh - ring-time re-classification and deterministic
# acknowledgement (bin/fm-wake-autoack.sh, fork issues #45 and #46).
#
# The real drain and wake library run over a fixture state dir; only the crew
# verdict is stubbed (FM_CREW_STATE_BIN, the seam crew_is_provably_working
# documents). Every ordering is set by the fixture: a row that "arrives
# meanwhile" and a failing acknowledgement are produced by a wrapper drain
# (FM_WAKE_AUTOACK_DRAIN), never by timing. The suite pins both directions:
#   - a wake whose crew is provably working again is acknowledged with no turn,
#     with the drain's own generation-bound acknowledgement;
#   - every wake that still needs action leaves the queue and the drain
#     untouched, so it rings exactly as before.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

AUTOACK="$ROOT/bin/fm-wake-autoack.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-autoack-tests)

# A home that does not run the supervision host keeps BRANCH OUTCOMES out of the
# drain (bin/fm-supervision-engine-lib.sh owns the gate), as the drain suites do.
mkdir -p "$TMP_ROOT/config" "$TMP_ROOT/config-off"
: > "$TMP_ROOT/config/supervision-host-off"
: > "$TMP_ROOT/config-off/supervision-host-off"

# fm-crew-state stand-in: <id> reads $CREW_DIR/<id> ("working" or anything else).
cat > "$TMP_ROOT/crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$(cat "$CREW_DIR/$1" 2>/dev/null)" in
  working) printf 'state: working · source: pane\n' ;;
  *) printf 'state: idle · source: pane\n' ;;
esac
SH
chmod +x "$TMP_ROOT/crew-state.sh"

new_case() {  # <name> -> echoes the state dir
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/crew"
  printf '%s\n' "$dir/state"
}

crew() {  # <state> <id> <working|idle>
  printf '%s\n' "$3" > "${1%/state}/crew/$2"
}

run_autoack() {  # <state> [config-dir] -> rc; stdout in <state>/../autoack.out
  local state=$1 config=${2:-$TMP_ROOT/config} rc=0
  LAST_RUN="${state%/state}/autoack"
  CREW_DIR="${state%/state}/crew" FM_CREW_STATE_BIN="$TMP_ROOT/crew-state.sh" \
    FM_SUPERVISION_MODEL=autoarm FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    "$AUTOACK" > "${state%/state}/autoack.out" 2> "${state%/state}/autoack.err" || rc=$?
  return "$rc"
}

queued() {  # <state> -> number of queued rows
  awk 'END { print NR }' "$1/.wake-queue" 2>/dev/null || printf 0
}

assert_rc() {  # <expected> <actual> <message>
  [ "$1" = "$2" ] || fail "$3 (exit $2, wanted $1): $(cat "$LAST_RUN.out" 2>/dev/null) $(cat "$LAST_RUN.err" 2>/dev/null)"
}

test_working_turn_end_is_acknowledged_without_a_turn() {
  local state rc=0
  state=$(new_case working-turnend)
  crew "$state" t1 working
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  run_autoack "$state" || rc=$?
  assert_rc 0 "$rc" "a turn-end for a provably working crew must be acknowledged"
  [ "$(queued "$state")" = 0 ] || fail "the acknowledgement must consume the row: $(cat "$state/.wake-queue")"
  [ ! -s "${state%/state}/autoack.out" ] || fail "an acknowledged wake must print nothing for the model"
  pass "autoack: a turn-end for a crew that is working again is acknowledged without a model turn"
}

test_acknowledgement_uses_the_drain_generation() {
  local state rc=0 marker
  state=$(new_case generation)
  crew "$state" t1 working
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  run_autoack "$state" || rc=$?
  assert_rc 0 "$rc" "setup acknowledgement"
  marker=$(cat "$state/.watcher-down" 2>/dev/null || true)
  case "$marker" in
    acked:*) : ;;
    *) fail "the acknowledgement must advance the recovery generation to acked, got: $marker" ;;
  esac
  pass "autoack: the ack is the drain's own generation-bound acknowledgement"
}

test_idle_crew_still_rings() {
  local state rc=0 before
  state=$(new_case idle)
  crew "$state" t1 idle
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  before=$(cat "$state/.wake-queue")
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "a turn-end for a crew that is not provably working must still ring"
  [ "$(cat "$state/.wake-queue")" = "$before" ] || fail "an actionable wake must stay queued untouched"
  [ ! -e "$state/.main-eligible-rows" ] || fail "no drain may run for an actionable wake"
  pass "autoack: a turn-end for an idle crew is left for the model"
}

test_status_signal_always_rings() {
  local state rc=0
  state=$(new_case status)
  crew "$state" t1 working
  append_wake "$state" signal t1.status "signal: $state/t1.status"
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "a status signal must ring even while the crew is working"
  append_wake "$state" signal t1.turn-ended "needs-decision:$state/t1.turn-ended"
  rc=0
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "a needs-decision payload must ring"
  [ "$(queued "$state")" = 2 ] || fail "neither row may be consumed"
  pass "autoack: status and needs-decision wakes always ring"
}

test_mixed_queue_acknowledges_nothing() {
  local state rc=0
  state=$(new_case mixed)
  crew "$state" t1 working
  crew "$state" t2 idle
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  append_wake "$state" signal t2.turn-ended "signal: $state/t2.turn-ended"
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "one actionable row must keep the whole queue ringing"
  [ "$(queued "$state")" = 2 ] || fail "no row of a mixed queue may be consumed"
  pass "autoack: one actionable row keeps the entire queue for the model"
}

test_stale_forms() {
  local state rc=0
  state=$(new_case stale)
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=ship"
  # A real hook runs between arm cycles, when the watcher beacon is fresh.
  touch "$state/.last-watcher-beat"
  crew "$state" t1 working
  append_wake "$state" stale sess:fm-t1 "stale: sess:fm-t1 (idle 900s, possible wedge, escalation 2)"
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "an enriched stale form must ring even when the crew looks busy"
  rm -f "$state/.wake-queue"
  append_wake "$state" stale sess:fm-t1 "stale: sess:fm-t1"
  rc=0
  run_autoack "$state" || rc=$?
  assert_rc 0 "$rc" "a first-sight stale for a crew that is working again must be acknowledged"
  [ "$(queued "$state")" = 0 ] || fail "the stale row must be consumed"
  pass "autoack: only the plain first-sight stale form is re-classified"
}

test_check_and_heartbeat_always_ring() {
  local state rc=0
  state=$(new_case check-heartbeat)
  append_wake "$state" check pr-merge "check: pr merged"
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "a check wake must ring"
  rm -f "$state/.wake-queue"
  append_wake "$state" heartbeat heartbeat heartbeat
  rc=0
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "a heartbeat wake must ring"
  pass "autoack: check and heartbeat wakes always ring"
}

test_without_flag_and_empty_queue() {
  local state rc=0
  state=$(new_case no-flag)
  crew "$state" t1 working
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  run_autoack "$state" "$TMP_ROOT/config-off" || rc=$?
  assert_rc 0 "$rc" "auto-ack must remain enabled without a configuration flag"
  [ "$(queued "$state")" = 0 ] || fail "a qualifying row must be acknowledged without the flag"
  rm -f "$state/.wake-queue"
  rc=0
  run_autoack "$state" || rc=$?
  assert_rc 1 "$rc" "an empty queue has nothing to acknowledge"
  pass "autoack: no configuration flag is required and an empty queue is a no-op"
}

test_unread_presentation_is_handed_back() {
  local state rc=0 out
  state=$(new_case presentation)
  crew "$state" t9 working
  printf 'note: bootstrap cursor line\n' > "$state/t9.status"
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" "$DRAIN" >/dev/null 2>&1 \
    || fail "setup: priming the presentation cursor failed"
  printf 'note: captain said use REST not RPC\n' >> "$state/t9.status"
  append_wake "$state" signal t9.turn-ended "signal: $state/t9.turn-ended"
  run_autoack "$state" || rc=$?
  assert_rc 3 "$rc" "an unread status line in the presentation must not be swallowed"
  out=$(cat "${state%/state}/autoack.out")
  case "$out" in
    *"captain said use REST not RPC"*) : ;;
    *) fail "the consumed presentation must be handed back verbatim, got: $out" ;;
  esac
  [ "$(queued "$state")" = 1 ] || fail "an unsafe acknowledgement must leave the row queued"
  pass "autoack: a presentation with anything but the rows is handed back, never acknowledged"
}

# A wrapper drain that appends one more wake before the real presentation, and
# one that cannot acknowledge.
write_wrapper() {  # <path> <mode: append|failack> <state>
  cat > "$1" <<SH
#!/usr/bin/env bash
case "$2" in
  append)
    if [ "\${1:-}" != --ack-through ]; then
      FM_STATE_OVERRIDE="$3" bash -c '. "$ROOT/bin/fm-wake-lib.sh"; fm_wake_append signal t3.status "signal: x/t3.status"'
    fi ;;
  failack)
    [ "\${1:-}" != --ack-through ] || exit 1 ;;
esac
exec "$DRAIN" "\$@"
SH
  chmod +x "$1"
}

test_row_arriving_meanwhile_is_not_acknowledged() {
  local state rc=0 wrapper
  state=$(new_case meanwhile)
  crew "$state" t1 working
  wrapper="${state%/state}/drain-append.sh"
  write_wrapper "$wrapper" append "$state"
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  FM_WAKE_AUTOACK_DRAIN="$wrapper" run_autoack "$state" || rc=$?
  assert_rc 3 "$rc" "a row that arrived after classification was never re-asked"
  [ "$(queued "$state")" = 2 ] || fail "both rows must stay queued, got: $(cat "$state/.wake-queue")"
  pass "autoack: a wake that arrives between classification and drain still rings"
}

test_failed_acknowledgement_leaves_the_rows() {
  local state rc=0 wrapper
  state=$(new_case failack)
  crew "$state" t1 working
  wrapper="${state%/state}/drain-failack.sh"
  write_wrapper "$wrapper" failack "$state"
  append_wake "$state" signal t1.turn-ended "signal: $state/t1.turn-ended"
  FM_WAKE_AUTOACK_DRAIN="$wrapper" run_autoack "$state" || rc=$?
  assert_rc 3 "$rc" "a hook acknowledgement that fails must hand back to the model"
  [ "$(queued "$state")" = 1 ] || fail "a failed acknowledgement must leave the row queued"
  pass "autoack: a failed acknowledgement re-rings as today"
}

test_working_turn_end_is_acknowledged_without_a_turn
test_acknowledgement_uses_the_drain_generation
test_idle_crew_still_rings
test_status_signal_always_rings
test_mixed_queue_acknowledges_nothing
test_stale_forms
test_check_and_heartbeat_always_ring
test_without_flag_and_empty_queue
test_unread_presentation_is_handed_back
test_row_arriving_meanwhile_is_not_acknowledged
test_failed_acknowledgement_leaves_the_rows
