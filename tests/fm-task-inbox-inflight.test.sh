#!/usr/bin/env bash
# tests/fm-task-inbox-inflight.test.sh - the steering-inbox re-ring ladder knows
# when a handling turn is in flight (fork issue #48).
#
# bin/fm-task-inbox-lib.sh owns the schedule and bin/fm-watch.sh records each
# busy sighting. Every case drives the production library and the watcher's own
# inbox_steer_check with explicit epochs and a stubbed pane, so ordering is set
# by the fixture and no case sleeps or races a deadline:
#   1. ring -> in flight (busy, no ack) -> idle again: no second ring until a
#      full grace after the last sighting.
#   2. ring -> handling died (no further sighting past grace): re-rings at the
#      re-armed deadline, and escalates once the ring budget is spent.
#   3. a true transition (a new oldest message) rings at once despite a fresh
#      sighting left by the previous message.
#   4. a busy worker before any ring leaves nothing behind, and a ladder with
#      no outstanding ring costs no pane capture.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-inbox-inflight)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# New aged record plus a ladder that rang <ago> seconds ago <count> times.
make_ladder() {  # <name> <ring-count> <ring-ago-secs> -> echoes "<state> <rec>"
  local dir="$TMP_ROOT/$1" state rec
  state="$dir/state"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue") || fail "write failed"
  touch -t 202001010000 "$rec"
  printf '%s\t%s\t%s\n' "${rec##*/}" "$2" "$(( $(date +%s) - $3 ))" > "$state/t1.inbox/.ring-state"
  printf '%s %s\n' "$state" "$rec"
}

due() {  # <state>
  FM_TASK_INBOX_GRACE_SECS=90 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$1" fm_task_inbox_due_action "$1" t1
}

set_inflight() {  # <state> <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$1/t1.inbox/.inflight"
}

test_inflight_sighting_rearms_the_ring() {
  local state rec
  read -r state rec < <(make_ladder rearm 1 200)
  [ "$(due "$state")" = "ring $rec" ] || fail "setup: a ring 200s ago must be due, got: $(due "$state")"
  set_inflight "$state" 30
  [ "$(due "$state")" = quiet ] \
    || fail "a handling turn seen 30s ago must hold the next ring, got: $(due "$state")"
  set_inflight "$state" 100
  [ "$(due "$state")" = "ring $rec" ] \
    || fail "handling last seen past grace must ring again, got: $(due "$state")"
  pass "inbox: a busy sighting re-arms the ring from the sighting, not from the ring"
}

test_lost_handling_still_rings_and_escalates() {
  local state rec
  read -r state rec < <(make_ladder lost 1 500)
  set_inflight "$state" 200
  [ "$(due "$state")" = "ring $rec" ] || fail "lost handling must re-ring at the re-armed deadline, got: $(due "$state")"
  read -r state rec < <(make_ladder lost-escalate 3 500)
  set_inflight "$state" 30
  [ "$(due "$state")" = quiet ] \
    || fail "an escalation must wait while handling was just seen, got: $(due "$state")"
  set_inflight "$state" 200
  case "$(due "$state")" in
    "escalate $rec 3") : ;;
    *) fail "an exhausted ladder with no recent sighting must escalate, got: $(due "$state")" ;;
  esac
  pass "inbox: handling that died without an ack re-rings, then escalates, at the re-armed deadline"
}

test_new_message_rings_at_once() {
  local state rec rec2
  read -r state rec < <(make_ladder transition 1 500)
  set_inflight "$state" 5
  mv "$rec" "$state/t1.inbox/handled/"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second steer") || fail "second write failed"
  [ "$(due "$state")" = "ring $rec2" ] \
    || fail "a new oldest message must ring at once despite a fresh sighting, got: $(due "$state")"
  [ ! -e "$state/t1.inbox/.inflight" ] || fail "a new oldest message must drop the previous message's sighting"
  mv "$rec2" "$state/t1.inbox/handled/"
  [ "$(due "$state")" = quiet ] || fail "an empty inbox must be quiet"
  [ ! -e "$state/t1.inbox/.ring-state" ] && [ ! -e "$state/t1.inbox/.inflight" ] \
    || fail "an empty inbox must reset the ladder and the sighting"
  pass "inbox: a true transition rings at once and an acknowledgement clears the sighting"
}

test_sighting_needs_an_outstanding_ring() {
  local dir state rec
  dir="$TMP_ROOT/no-ring"
  state="$dir/state"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first steer") || fail "write failed"
  touch -t 202001010000 "$rec"
  inbox_lib "$state" fm_task_inbox_note_inflight "$state" t1
  [ ! -e "$state/t1.inbox/.inflight" ] || fail "a busy worker before any ring must leave no sighting"
  inbox_lib "$state" fm_task_inbox_inflight_probe_due "$state" t1 \
    && fail "a ladder with no ring must not ask for a pane capture"
  printf '%s\t1\t%s\n' "${rec##*/}" "$(( $(date +%s) - 10 ))" > "$state/t1.inbox/.ring-state"
  inbox_lib "$state" fm_task_inbox_inflight_probe_due "$state" t1 \
    || fail "an outstanding ring must ask for a pane capture"
  printf '%s\n' "${rec##*/}" > "$state/t1.inbox/.escalated"
  inbox_lib "$state" fm_task_inbox_inflight_probe_due "$state" t1 \
    && fail "an escalated ladder must stop asking for pane captures"
  pass "inbox: sightings and pane captures happen only while a ring is outstanding"
}

# The watcher's own inbox_steer_check against a stubbed pane and doorbell.
watcher_check() {  # <state> <busy 0|1> -> prints "ring" when the doorbell rang
  local state=$1 busy=$2
  FM_STATE_OVERRIDE="$state" FM_TASK_INBOX_GRACE_SECS=90 FM_TASK_INBOX_RING_MAX=99 \
    FAKE_BUSY="$busy" bash -c '
      . "$1"
      window_backend() { printf tmux; }
      window_label() { printf fm-t1; }
      fm_backend_capture() { printf "pane\n"; }
      fm_backend_agent_state() { printf running; }
      window_is_busy() { [ "$FAKE_BUSY" = 1 ]; }
      fm_task_inbox_ring() { printf ring; return 0; }
      triage_log() { :; }
      inbox_steer_check sess:fm-t1 t1
    ' _ "$ROOT/bin/fm-watch.sh"
}

test_watcher_records_the_sighting_and_waits() {
  local state rec
  read -r state rec < <(make_ladder watcher 1 200)
  [ "$(watcher_check "$state" 1)" = "" ] || fail "a busy pane must not be rung"
  [ -s "$state/t1.inbox/.inflight" ] || fail "the watcher must record the busy sighting"
  [ "$(watcher_check "$state" 0)" = "" ] \
    || fail "the first idle poll after a handling turn must not re-ring"
  set_inflight "$state" 200
  [ "$(watcher_check "$state" 0)" = ring ] \
    || fail "with no sighting inside grace the idle pane must be re-rung"
  pass "watcher: a busy pane is recorded as handling in flight and the next ring waits a full grace"
}

test_watcher_sees_busy_during_quiet_window() {
  local state rec
  read -r state rec < <(make_ladder watcher-quiet 1 10)
  [ "$(due "$state")" = quiet ] || fail "setup: a ring 10s ago must be within grace"
  watcher_check "$state" 1 >/dev/null
  [ -s "$state/t1.inbox/.inflight" ] \
    || fail "a busy poll inside the grace window must still record the sighting"
  pass "watcher: busy sightings are recorded inside the grace window too"
}

test_inflight_sighting_rearms_the_ring
test_lost_handling_still_rings_and_escalates
test_new_message_rings_at_once
test_sighting_needs_an_outstanding_ring
test_watcher_records_the_sighting_and_waits
test_watcher_sees_busy_during_quiet_window
