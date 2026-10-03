#!/usr/bin/env bash
# tests/fm-task-inbox-ladder.test.sh - the steering-inbox re-ring ladder rings on
# state transitions, from one durable record per message (fork issue #48).
#
# bin/fm-task-inbox-ladder.sh owns the record, bin/fm-task-inbox-lib.sh owns the
# decision (fm_task_inbox_due_action), bin/fm-watch.sh records busy sightings.
# Every case drives those production functions against a fixture inbox. Ordering
# is fixed by the fixture - records carry explicit epochs far from the grace
# boundary and the pane is a stub that answers busy or idle on demand. The
# crash case alone uses a short real deadline to preserve the process boundary.
#
# The issue's three named sequences:
#   1. ring -> in flight (busy, no ack, no state change) -> no second ring
#   2. ring -> state change (a different oldest message) -> immediate ring
#   3. ring -> ack lost (handling died) -> re-ring at the re-armed deadline
# And the edge cases that broke the marker-file attempt (PR 70 review rounds):
#   - a fresh new oldest message waits for fm-send's first doorbell, then
#     re-rings on the ladder's own age gate
#   - a new message after an escalation (even a dead-pane one that never rang)
#     inherits nothing from the escalated message
#   - an unwritable record surfaces one stale wake and never rings or queues on
#     every poll
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-inbox-ladder)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
GRACE=90
MAX=3

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

new_state() {  # <name> -> echoes the state dir
  mkdir -p "$TMP_ROOT/$1/state"
  printf '%s' "$TMP_ROOT/$1/state"
}

write_msg() {  # <state> <text> [aged] -> echoes the record path
  local rec
  rec=$(inbox_lib "$1" fm_task_inbox_write "$1" t1 "$2") || fail "write failed"
  [ "${3:-}" != aged ] || touch -t 202001010000 "$rec"
  printf '%s' "$rec"
}

# Put the ladder record for <rec> in an explicit state; epochs are seconds ago.
set_record() {  # <state> <rec> <ringing|escalated> <count> <ring-ago> <seen-ago|never>
  local now seen=0
  now=$(date +%s)
  [ "$6" = never ] || seen=$((now - $6))
  printf '%s\t%s\t%s\t%s\t%s\n' "${2##*/}" "$3" "$4" "$((now - $5))" "$seen" \
    > "$1/t1.inbox/.ring-state"
}

record_state() {  # <state> -> the record's "<msg> <state> <count>"
  cut -f1-3 "$1/t1.inbox/.ring-state" | tr '\t' ' '
}

record_seen_at() {  # <state>
  cut -f5 "$1/t1.inbox/.ring-state"
}

due() {  # <state>
  FM_TASK_INBOX_GRACE_SECS=$GRACE FM_TASK_INBOX_RING_MAX=$MAX \
    inbox_lib "$1" fm_task_inbox_due_action "$1" t1
}

# The watcher's own inbox_steer_check against a stubbed pane and doorbell.
# Prints "ring" when the doorbell rang and "wake" when the cycle surfaced a wake
# (wake exits the cycle exactly as the real one does).
watcher_check() {  # <state> <busy 0|1> [agent-state] [handler-pid] [grace] [capture-count]
  local state=$1 busy=$2 agent=${3:-running} handler=${4:-} grace=${5:-$GRACE} count_file=${6:-}
  # shellcheck disable=SC2016 # the stub script is expanded by the inner shell
  env -u FM_TASK_ID FM_STATE_OVERRIDE="$state" FM_TASK_INBOX_GRACE_SECS="$grace" \
    FM_TASK_INBOX_RING_MAX=$MAX FAKE_BUSY="$busy" FAKE_AGENT="$agent" \
    FAKE_HANDLER_PID="$handler" FAKE_CAPTURE_COUNT_FILE="$count_file" bash -c '
      . "$1"
      window_backend() { printf tmux; }
      window_label() { printf fm-t1; }
      fm_backend_capture() {
        if [ -n "$FAKE_CAPTURE_COUNT_FILE" ]; then
          capture_count=$(cat "$FAKE_CAPTURE_COUNT_FILE" 2>/dev/null || printf 0)
          printf "%s\n" "$((capture_count + 1))" > "$FAKE_CAPTURE_COUNT_FILE"
        fi
        printf "pane\n"
      }
      fm_backend_agent_state() { printf "%s" "$FAKE_AGENT"; }
      window_is_busy() {
        [ "$FAKE_BUSY" = 1 ] || {
          [ -n "$FAKE_HANDLER_PID" ] && kill -0 "$FAKE_HANDLER_PID" 2>/dev/null
        }
      }
      fm_task_inbox_ring() { printf ring; return 0; }
      wake() { printf wake; exit 0; }
      triage_log() { :; }
      inbox_steer_check sess:fm-t1 t1
    ' _ "$ROOT/bin/fm-watch.sh" 2>/dev/null
}

wake_rows() {  # <state>
  local n
  n=$(grep -c 'steering-inbox ladder bookkeeping unwritable\|unread firstmate instruction' \
    "$1/.wake-queue" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

# Sequence 1: a handling turn in flight is not rung again.
test_in_flight_handling_is_not_rung_again() {
  local state rec before
  state=$(new_state seq1)
  rec=$(write_msg "$state" "please continue" aged)
  [ "$(watcher_check "$state" 0)" = ring ] || fail "an aged delivered message must ring"
  [ "$(record_state "$state")" = "${rec##*/} ringing 1" ] \
    || fail "the first ring must record ringing/1, got: $(record_state "$state")"
  # The ring was spent a long time ago, but the worker is busy handling.
  set_record "$state" "$rec" ringing 1 200 never
  [ "$(due "$state")" = "ring $rec" ] || fail "setup: a ring 200s ago with no sighting must be due"
  [ "$(watcher_check "$state" 1)" = "" ] || fail "a busy pane must not be rung"
  [ "$(record_seen_at "$state")" -gt 0 ] || fail "the watcher must record the busy sighting in the one record"
  [ "$(watcher_check "$state" 0)" = "" ] \
    || fail "the first idle poll after a handling turn must not re-ring"
  [ "$(due "$state")" = quiet ] || fail "handling seen just now must hold the next ring, got: $(due "$state")"
  before=$(record_state "$state")
  [ "$(watcher_check "$state" 0)" = "" ] || fail "a second idle poll still inside grace must not ring"
  [ "$(record_state "$state")" = "$before" ] || fail "a quiet poll must not change the record"
  pass "ladder: ring -> in flight (no ack, no state change) -> no second ring"
}

# Sequence 2: a state change rings at once.
test_state_change_rings_at_once() {
  local state rec rec2
  state=$(new_state seq2)
  rec=$(write_msg "$state" "first steer" aged)
  set_record "$state" "$rec" ringing 1 10 5
  [ "$(due "$state")" = quiet ] || fail "setup: a fresh sighting must hold the ladder"
  mv "$rec" "$state/t1.inbox/handled/"
  rec2=$(write_msg "$state" "second steer" aged)
  [ "$(due "$state")" = "ring $rec2" ] \
    || fail "a new oldest message must ring at once despite the previous sighting, got: $(due "$state")"
  [ "$(watcher_check "$state" 0)" = ring ] || fail "the watcher must ring the new oldest message"
  [ "$(record_state "$state")" = "${rec2##*/} ringing 1" ] \
    || fail "the ring must record the new message from a fresh count, got: $(record_state "$state")"
  pass "ladder: ring -> state change -> immediate ring from a fresh ladder"
}

# Sequence 3: lost handling re-rings at the re-armed deadline, then escalates.
test_lost_handling_rerings_at_the_rearmed_deadline() {
  local state rec
  state=$(new_state seq3)
  rec=$(write_msg "$state" "please continue" aged)
  set_record "$state" "$rec" ringing 1 500 40
  [ "$(due "$state")" = quiet ] || fail "handling seen 40s ago must hold the ring, got: $(due "$state")"
  set_record "$state" "$rec" ringing 1 500 200
  [ "$(due "$state")" = "ring $rec" ] \
    || fail "handling that died (last seen 200s ago) must re-ring at the deadline, got: $(due "$state")"
  [ "$(watcher_check "$state" 0)" = ring ] || fail "the watcher must re-ring lost handling"
  [ "$(record_state "$state")" = "${rec##*/} ringing 2" ] || fail "the re-ring must spend an attempt"
  [ "$(record_seen_at "$state")" = 0 ] || fail "a new ring must restart the sighting"
  set_record "$state" "$rec" ringing "$MAX" 500 40
  [ "$(due "$state")" = quiet ] || fail "an escalation must wait while handling was just seen"
  set_record "$state" "$rec" ringing "$MAX" 500 200
  [ "$(due "$state")" = "escalate $rec $MAX" ] \
    || fail "an exhausted ladder with stale sightings must escalate, got: $(due "$state")"
  set_record "$state" "$rec" ringing "$MAX" 5 never
  [ "$(due "$state")" = "escalate $rec $MAX" ] \
    || fail "an exhausted ladder with no sighting escalates at once, got: $(due "$state")"
  pass "ladder: ring -> ack lost -> re-ring at the re-armed deadline, then escalation"
}

# The ladder's age gate applies to re-rings; fm-send owns the first doorbell
# for a freshly written oldest record.
test_fresh_new_oldest_waits_for_first_doorbell() {
  local state rec rec2
  state=$(new_state fresh-oldest)
  rec=$(write_msg "$state" "first" aged)
  set_record "$state" "$rec" ringing 2 20 10
  mv "$rec" "$state/t1.inbox/handled/"
  rec2=$(write_msg "$state" "second")
  [ "$(due "$state")" = quiet ] \
    || fail "the ladder must wait for fm-send's first doorbell, got: $(due "$state")"
  touch -t 202001010000 "$rec2"
  [ "$(due "$state")" = "ring $rec2" ] \
    || fail "a fresh message must become a re-ring only after its own grace, got: $(due "$state")"
  pass "ladder: a fresh oldest record waits for fm-send's first doorbell"
}

# A real handling process is observed busy after the first ring, then dies
# without moving the record. The watcher must preserve the row and re-ring only
# after the sighting's grace deadline.
test_crashed_handling_process_rerings_after_rearmed_deadline() {
  local state rec handler seen ring_at out i=0 now
  state=$(new_state crashed-handler)
  rec=$(write_msg "$state" "please continue" aged)
  [ "$(watcher_check "$state" 0)" = ring ] || fail "the first ring must land"
  ring_at=$(cut -f4 "$state/t1.inbox/.ring-state")
  ( while :; do sleep 1; done ) &
  handler=$!
  [ "$(watcher_check "$state" 0 running "$handler" 1)" = "" ] \
    || fail "a live handling process must not be rung again"
  seen=$(record_seen_at "$state")
  [ "$seen" -ge "$ring_at" ] || fail "the busy sighting was not recorded after the ring"
  kill -KILL "$handler" 2>/dev/null || fail "the handling process could not be killed"
  wait "$handler" 2>/dev/null || true
  [ "$(watcher_check "$state" 0 running "$handler" 2)" = "" ] \
    || fail "a just-crashed handling process must wait for the re-armed deadline"
  [ -f "$rec" ] || fail "a crashed handling process must not consume the message"
  out=
  while [ "$i" -lt 40 ]; do
    out=$(watcher_check "$state" 0 running "$handler" 2)
    [ "$out" = ring ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$out" = ring ] || fail "the watcher did not re-ring after the re-armed deadline"
  now=$(date +%s)
  [ "$((now - seen))" -ge 2 ] || fail "the re-ring preceded the busy sighting's deadline"
  [ "$(record_state "$state")" = "${rec##*/} ringing 2" ] \
    || fail "the crash recovery ring must spend the next attempt"
  [ -f "$rec" ] || fail "the crash recovery ring must leave the row unhandled"
  pass "watcher: a killed handling process re-rings at the re-armed deadline"
}

# wake-review-6: a dead-pane escalation never rang, so no ring record existed
# for the old marker scheme to reset; the new message must start clean.
test_new_message_after_an_escalation_inherits_nothing() {
  local state rec rec2 rec3
  state=$(new_state after-escalation)
  rec=$(write_msg "$state" "first" aged)
  [ "$(watcher_check "$state" 0 dead)" = wake ] || fail "a dead pane must surface its stale wake"
  [ "$(record_state "$state")" = "${rec##*/} escalated 0" ] \
    || fail "a dead-pane escalation records escalated/0, got: $(record_state "$state")"
  [ "$(due "$state")" = quiet ] || fail "an escalated message stays quiet for recovery"
  mv "$rec" "$state/t1.inbox/handled/"
  rec2=$(write_msg "$state" "second" aged)
  [ "$(due "$state")" = "ring $rec2" ] \
    || fail "an aged new message after an escalation rings at once, got: $(due "$state")"
  rec3=$(write_msg "$state" "third")
  mv "$rec2" "$state/t1.inbox/handled/"
  [ "$(due "$state")" = quiet ] || fail "a young new message waits its own grace, not more"
  touch -t 202001010000 "$rec3"
  [ "$(due "$state")" = "ring $rec3" ] \
    || fail "the young message rings at its own deadline, got: $(due "$state")"
  pass "ladder: a new message after an escalation is delayed by nothing and inherits nothing"
}

test_stale_record_for_another_message_is_ignored() {
  local state rec
  state=$(new_state stale-record)
  rec=$(write_msg "$state" "only" aged)
  printf '%s\tescalated\t3\t1\t1\n' "000.msg" > "$state/t1.inbox/.ring-state"
  [ "$(due "$state")" = "ring $rec" ] || fail "a record naming another message must read as delivered"
  printf 'garbage\n' > "$state/t1.inbox/.ring-state"
  [ "$(due "$state")" = "ring $rec" ] || fail "an unparseable record must read as delivered"
  printf '%s\tringing\t1\t100\n' "${rec##*/}" > "$state/t1.inbox/.ring-state"
  [ "$(due "$state")" = "ring $rec" ] || fail "a truncated record must read as delivered"
  pass "ladder: a record that does not describe the oldest message is ignored by construction"
}

test_later_messages_do_not_reset_the_oldest() {
  local state rec
  state=$(new_state later-msg)
  rec=$(write_msg "$state" "first" aged)
  set_record "$state" "$rec" ringing 1 10 never
  write_msg "$state" "second" aged >/dev/null
  [ "$(due "$state")" = quiet ] || fail "a later message must not restart the oldest's ladder"
  [ "$(record_state "$state")" = "${rec##*/} ringing 1" ] || fail "the oldest's record must survive"
  pass "ladder: a later message leaves the oldest message's ladder alone"
}

test_busy_before_the_first_ring_writes_nothing() {
  local state
  state=$(new_state busy-early)
  write_msg "$state" "first" aged >/dev/null
  [ "$(watcher_check "$state" 1)" = "" ] || fail "a busy pane must not be rung"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "a busy sighting before any ring must leave no record"
  inbox_lib "$state" fm_task_inbox_inflight_probe_due "$state" t1 \
    && fail "a delivered message must not ask for a pane capture"
  pass "ladder: a busy worker before the first ring changes nothing"
}

test_repeated_busy_polls_are_gated_after_a_sighting() {
  local state rec count_file before after
  state=$(new_state busy-gated)
  rec=$(write_msg "$state" "keep working" aged)
  set_record "$state" "$rec" ringing 1 0 never
  count_file="$state/capture-count"
  printf '0\n' > "$count_file"
  [ "$(watcher_check "$state" 1 running "" "$GRACE" "$count_file")" = "" ] \
    || fail "the first busy sighting must stay quiet"
  [ "$(cat "$count_file")" = 1 ] || fail "the first busy sighting must capture the pane"
  before=$(cat "$state/t1.inbox/.ring-state")
  [ "$(watcher_check "$state" 1 running "" "$GRACE" "$count_file")" = "" ] \
    || fail "a repeated busy poll must stay quiet"
  after=$(cat "$state/t1.inbox/.ring-state")
  [ "$(cat "$count_file")" = 1 ] || fail "a recent sighting recaptured the pane"
  [ "$after" = "$before" ] || fail "a recent sighting rewrote the ladder record"
  pass "watcher: repeated busy polls skip capture and ladder rewrites inside half grace"
}

test_suppression_never_acks_or_consumes() {
  local state rec
  state=$(new_state no-ack)
  rec=$(write_msg "$state" "keep me" aged)
  set_record "$state" "$rec" ringing 1 200 never
  watcher_check "$state" 1 >/dev/null
  watcher_check "$state" 0 >/dev/null
  [ -f "$rec" ] || fail "suppression consumed the row"
  [ -z "$(ls "$state/t1.inbox/handled/")" ] || fail "suppression acknowledged a row"
  [ "$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)" = "$rec" ] \
    || fail "the unhandled row must stay the oldest"
  pass "ladder: suppression never acks and never consumes a row"
}

test_record_writes_are_atomic_and_clean() {
  local state rec leftovers f
  state=$(new_state atomic)
  rec=$(write_msg "$state" "x" aged)
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" || fail "record_ring failed"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" || fail "second record_ring failed"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" || fail "record_escalated failed"
  [ "$(record_state "$state")" = "${rec##*/} escalated 2" ] \
    || fail "ring, ring, escalate must record escalated/2, got: $(record_state "$state")"
  leftovers=0
  for f in "$state/t1.inbox"/.ring-state.*; do [ ! -e "$f" ] || leftovers=$((leftovers + 1)); done
  [ "$leftovers" = 0 ] || fail "atomic writes left $leftovers temp files"
  mv "$rec" "$state/t1.inbox/handled/"
  [ "$(due "$state")" = quiet ] || fail "a handled inbox must be quiet"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "an acknowledged message must drop its record"
  pass "ladder: one record, written atomically, dropped on acknowledgement"
}

test_unwritable_record_surfaces_once_without_ringing_each_poll() {
  local state rec out
  state=$(new_state unwritable-sighting)
  rec=$(write_msg "$state" "stuck" aged)
  set_record "$state" "$rec" ringing 1 200 never
  # Swap the record for a directory so every write fails while the message
  # stays unhandled. (A directory still reads as an invalid record.)
  rm -f "$state/t1.inbox/.ring-state"
  mkdir "$state/t1.inbox/.ring-state"
  out=$(watcher_check "$state" 0)
  [ "$out" = ringwake ] || fail "an unwritable record rings once then surfaces one wake, got: $out"
  [ "$(wake_rows "$state")" = 1 ] || fail "expected exactly one stale wake row, got $(wake_rows "$state")"
  [ -f "$rec" ] || fail "the unhandled record disappeared"
  pass "ladder: an unwritable record surfaces through the one stale-wake path"
}

# A busy sighting that cannot be written is reported through the same single
# wake path, never rings, and queues one row per cycle rather than one per poll.
test_unwritable_sighting_surfaces_once_and_never_rings() {
  local state rec out
  state=$(new_state unwritable-sighting-write)
  [ "$(id -u)" != 0 ] || { pass "ladder: unwritable sighting (skipped as root)"; return; }
  rec=$(write_msg "$state" "stuck" aged)
  set_record "$state" "$rec" ringing 1 200 never
  chmod 555 "$state/t1.inbox"
  out=$(watcher_check "$state" 1)
  chmod 755 "$state/t1.inbox"
  [ "$out" = wake ] || fail "an unwritable sighting must surface one wake and never ring, got: $out"
  [ "$(wake_rows "$state")" = 1 ] || fail "expected one stale wake row, got $(wake_rows "$state")"
  [ -f "$rec" ] && [ -z "$(ls "$state/t1.inbox/handled/")" ] || fail "the unhandled row must be untouched"
  pass "ladder: an unwritable busy sighting surfaces once through the same path and never rings"
}

test_unwritable_record_acknowledged_is_quiet() {
  local state rec
  state=$(new_state unwritable-acked)
  rec=$(write_msg "$state" "stuck" aged)
  mkdir "$state/t1.inbox/.ring-state"
  mv "$rec" "$state/t1.inbox/handled/"
  [ "$(watcher_check "$state" 0)" = "" ] || fail "an acknowledged message must stay quiet"
  [ "$(wake_rows "$state")" = 0 ] || fail "an acknowledged message queued a bookkeeping wake"
  pass "ladder: acknowledgement makes an unwritable record quiet"
}

test_in_flight_handling_is_not_rung_again
test_state_change_rings_at_once
test_lost_handling_rerings_at_the_rearmed_deadline
test_fresh_new_oldest_waits_for_first_doorbell
test_crashed_handling_process_rerings_after_rearmed_deadline
test_new_message_after_an_escalation_inherits_nothing
test_stale_record_for_another_message_is_ignored
test_later_messages_do_not_reset_the_oldest
test_busy_before_the_first_ring_writes_nothing
test_repeated_busy_polls_are_gated_after_a_sighting
test_suppression_never_acks_or_consumes
test_record_writes_are_atomic_and_clean
test_unwritable_record_surfaces_once_without_ringing_each_poll
test_unwritable_sighting_surfaces_once_and_never_rings
test_unwritable_record_acknowledged_is_quiet
