#!/usr/bin/env bash
# Copied-link variants of upstream's bounded queue-lock and handoff cases.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-directory-lock-wake-queue)

test_bounded_lock_handoff_after_contention() {
  local dir state lock holder_pid waiter_pid i recorded_pid real_sleep sleep_log
  dir=$(make_case bounded-lock-handoff)
  state="$dir/state"
  lock="$state/.fixture.lock"
  sleep_log="$dir/waiter-sleeps"
  real_sleep=$(command -v sleep) || fail "sleep is unavailable for the handoff fixture"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HANDOFF_SLEEP_LOG"
exec "$FM_HANDOFF_REAL_SLEEP" "$@"
SH
  chmod +x "$dir/fakebin/sleep"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/holder.ready" "$dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "handoff fixture holder never acquired its lock"; }

  PATH="$dir/fakebin:$PATH" FM_HANDOFF_SLEEP_LOG="$sleep_log" FM_HANDOFF_REAL_SLEEP="$real_sleep" \
    FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait_bounded "$2" 5 || exit 11
    current=${BASHPID:-$$}
    printf "%s\n" "$current" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    [ "$(cat "$2/pid" 2>/dev/null || true)" = "$current" ] || exit 12
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/waiter.ready" "$dir/release-waiter" &
  waiter_pid=$!
  i=0
  while [ "$i" -lt 100 ] && ! grep -Fx '0.1' "$sleep_log" >/dev/null 2>&1; do
    sleep 0.05
    i=$((i + 1))
  done
  grep -Fx '0.1' "$sleep_log" >/dev/null 2>&1 \
    || { kill "$holder_pid" "$waiter_pid" 2>/dev/null || true; fail "bounded helper never entered its contended wait"; }
  [ ! -e "$dir/waiter.ready" ] \
    || { kill "$holder_pid" "$waiter_pid" 2>/dev/null || true; fail "bounded waiter bypassed a live holder"; }

  : > "$dir/release-holder"
  wait "$holder_pid" || { kill "$waiter_pid" 2>/dev/null || true; fail "fixture holder did not release cleanly"; }
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/waiter.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/waiter.ready" ] \
    || { kill "$waiter_pid" 2>/dev/null || true; fail "bounded waiter did not acquire after contention cleared"; }
  recorded_pid=$(cat "$dir/waiter.ready")
  [ "$recorded_pid" = "$waiter_pid" ] && [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$waiter_pid" ] \
    || { kill "$waiter_pid" 2>/dev/null || true; fail "bounded acquire did not hand lock ownership to its caller"; }
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then fm_lock_release "$2"; exit 1; fi
    [ "${FM_LOCK_HELD_PID:-}" = "$3" ]
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$waiter_pid" \
    || { kill "$waiter_pid" 2>/dev/null || true; fail "a contender took the lock from its live handed-off caller"; }

  : > "$dir/release-waiter"
  wait "$waiter_pid" || fail "caller could not release its handed-off lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "handed-off lock remained after caller release"
  pass "bounded acquire hands ownership to the waiting caller after contention"
}

# Rerun a lock test unchanged with a copying ln, which forces the directory
# lock record (bin/fm-wake-lib.sh header), and prove that record was used.
with_copied_link_locks() {  # <test>
  local bin="$TMP_ROOT/copied-link-locks-bin" log="$TMP_ROOT/copied-link-locks.log" real_ln
  real_ln=$(fm_real_tool ln)
  mkdir -p "$bin"
  cat > "$bin/ln" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -s ]; then
  printf 'copied\n' >> "$FM_TEST_COPIED_LINK_LOG"
  exec cp -R "$2" "$3"
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
  chmod +x "$bin/ln"
  rm -f "$log"
  ( PATH="$bin:$PATH" FM_TEST_REAL_LN="$real_ln" FM_TEST_COPIED_LINK_LOG="$log" \
      FM_TEST_CASE_SUFFIX=-copied-link "$1" ) || fail "$1 failed with copied-link directory locks"
  [ -s "$log" ] || fail "$1 did not exercise copied-link directory locks"
  pass "$1 also holds with copied-link directory locks"
}


# A live-but-stuck presentation lock must not strand the executable drain. The
# presentation remains retriable on the next pass, while the separate queue
# mutation lock keeps its blocking all-or-nothing acknowledgement contract.
test_live_presentation_holder_is_deadlined_without_weakening_ack() {
  local dir state status queue_out queue_err first_out first_err second_out second_err replay_out replay_err
  local queue_holder presentation_holder ack_holder i start elapsed rc advisory_count
  dir=$(make_case presentation-lock-deadline)
  state="$dir/state"
  status="$state/task.status"
  queue_out="$dir/queue.out"
  queue_err="$dir/queue.err"
  first_out="$dir/first.out"
  first_err="$dir/first.err"
  second_out="$dir/second.out"
  second_err="$dir/second.err"
  replay_out="$dir/replay.out"
  replay_err="$dir/replay.err"

  printf 'needs-decision [key=fixture]: presentation remains retriable\n' > "$status"
  append_wake "$state" signal task.status "signal: $status" \
    || fail "could not seed the presentation-deadline wake"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$dir/queue.ready" &
  queue_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/queue.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/queue.ready" ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue holder never acquired its lock"; }

  start=$(date +%s)
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$queue_out" 2> "$queue_err" \
    || { kill "$queue_holder" 2>/dev/null || true; fail "bounded queue presentation drain failed"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 4 ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue lock delayed the drain for ${elapsed}s"; }
  advisory_count=$(grep -Fc \
    "WAKE DRAIN SKIPPED: queue lock remains held by live pid $queue_holder" \
    "$queue_out" || true)
  [ "$advisory_count" -eq 1 ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue deadline did not emit exactly one holder advisory"; }
  [ ! -s "$queue_err" ] \
    || { kill "$queue_holder" 2>/dev/null || true; fail "queue deadline leaked helper-process diagnostics"; }
  if grep "$(printf '\tsignal\t')" "$queue_out" >/dev/null \
    || grep -F 'WAKE_ACK_REQUIRED:' "$queue_err" >/dev/null; then
    kill "$queue_holder" 2>/dev/null || true
    fail "contended queue lock allowed a partial drain"
  fi
  grep "$(printf '\tsignal\t')" "$state/.wake-queue" >/dev/null \
    || { kill "$queue_holder" 2>/dev/null || true; fail "contended queue lock changed the durable wake"; }

  kill "$queue_holder" 2>/dev/null || true
  wait "$queue_holder" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.status-presentation-lock" "$dir/presentation.ready" &
  presentation_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/presentation.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/presentation.ready" ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation holder never acquired its lock"; }

  start=$(date +%s)
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$first_out" 2> "$first_err" \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "bounded presentation drain failed"; }
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -le 4 ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation lock delayed the drain for ${elapsed}s"; }
  advisory_count=$(grep -Fc \
    "STATUS PRESENTATION SKIPPED: lock remains held by live pid $presentation_holder" \
    "$first_out" || true)
  [ "$advisory_count" -eq 1 ] \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "presentation deadline did not emit exactly one holder advisory"; }
  if grep -v '^WAKE_ACK_REQUIRED:' "$first_err" | grep . >/dev/null; then
    kill "$presentation_holder" 2>/dev/null || true
    fail "presentation deadline leaked helper-process diagnostics"
  fi
  grep "$(printf '\tsignal\t')" "$first_out" >/dev/null \
    || { kill "$presentation_holder" 2>/dev/null || true; fail "bounded presentation dropped the durable wake row"; }
  if grep -F 'task.status: needs-decision [key=fixture]' "$first_out" >/dev/null; then
    kill "$presentation_holder" 2>/dev/null || true
    fail "contended presentation emitted status content without its cursor lock"
  fi

  kill "$presentation_holder" 2>/dev/null || true
  wait "$presentation_holder" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 \
    "$DRAIN" > "$second_out" 2> "$second_err" || fail "presentation retry failed"
  grep -F 'task.status: needs-decision [key=fixture]: presentation remains retriable' "$second_out" >/dev/null \
    || fail "the next presentation pass did not surface the skipped status"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$dir/ack.ready" &
  ack_holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/ack.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/ack.ready" ] \
    || { kill "$ack_holder" 2>/dev/null || true; fail "acknowledgement holder never acquired the queue lock"; }

  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    shift
    fm_run_timed 1 "$@"
  ' _ "$ROOT/bin/fm-timeout-lib.sh" "$DRAIN" \
    --ack-through "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$second_err")" \
    --recovery-generation "$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$second_err")" \
    > "$dir/ack-held.out" 2> "$dir/ack-held.err" || rc=$?
  [ "$rc" -eq 124 ] \
    || { kill "$ack_holder" 2>/dev/null || true; fail "held acknowledgement lock did not retain blocking semantics (rc=$rc)"; }

  kill "$ack_holder" 2>/dev/null || true
  wait "$ack_holder" 2>/dev/null || true
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "drain after the interrupted acknowledgement failed"
  grep "$(printf '\tsignal\t')" "$replay_out" >/dev/null \
    || fail "the held acknowledgement lock allowed a partial consume"
  ack_drain_err "$state" "$replay_err" \
    || fail "the intact wake could not be acknowledged after contention cleared"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged presentation fixture remained queued"
  pass "presentation lock waits are bounded and retriable without weakening acknowledgement atomicity"
}

with_copied_link_locks test_bounded_lock_handoff_after_contention
with_copied_link_locks test_live_presentation_holder_is_deadlined_without_weakening_ack
