#!/usr/bin/env bash
# Fork doorbell regressions relocated from the upstream inbox and composer suites.
# Exercise the real adapters, classifier and synchronous watcher check; fake
# only the terminal edges used by these cases, never a real backend lifecycle.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-doorbell-recovery)
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

# This watcher case only needs a durable aged record and its window metadata,
# not the upstream watcher's background-process and crew-state fixtures.
busy_case() {
  local dir rec
  dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  rec=$(inbox_lib "$dir/state" fm_task_inbox_write "$dir/state" t1 "please continue")
  touch -t 202001010000 "$rec"
  printf '%s' "$dir"
}

# Only the synchronous watcher path uses tmux here: capture its composer,
# observe any typing, and submit on Enter. Lost-Enter simulation belongs to
# the Herdr driver below; the upstream tmux simulator is not duplicated.
make_composer_stub() {  # <dir>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      [ -z "${FM_FAKE_LOG_TYPES:-}" ] || printf 'TYPE: %s\n' "$1" >> "$FM_SEND_LOG"
      printf '%s' "$1" >> "$FM_FAKE_COMPOSER"
    elif [ "${1:-}" = Enter ] && [ -s "$FM_FAKE_COMPOSER" ]; then
      printf 'SUBMIT: %s\n' "$(cat "$FM_FAKE_COMPOSER")" >> "$FM_SEND_LOG"
      : > "$FM_FAKE_COMPOSER"
    fi
    exit 0 ;;
  display-message)
    case "$*" in *cursor_y*) printf '2\n'; exit 0 ;; esac
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    rule=$(printf '─%.0s' $(seq 64))
    printf '● done\n%s\n' "$rule"
    if [ -s "$FM_FAKE_COMPOSER" ]; then
      fold -w 60 "$FM_FAKE_COMPOSER" | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }'
    else
      printf '❯ \n'
    fi
    printf '%s\n  ? for shortcuts\n' "$rule"
    exit 0 ;;
  list-windows) printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/fakebin/tmux"
}

# A Herdr pane whose Claude composer keeps its content in FM_FAKE_COMPOSER. The
# real herdr adapter, shared composer classifier, and ring run; only the herdr
# CLI edges are replaced. Its submit reproduces issue 104: it types the
# doorbell, reports delivery, and leaves the line unsubmitted in the composer.
# Enter submits (logged as SUBMIT) unless FM_FAKE_DROP_ENTERS still holds a
# count of Enters to swallow. The bounded recent-output capture never shows the
# composer, as on Herdr, so only a viewport composer read can see the doorbell.
make_herdr_composer_driver() {  # <dir> -> echoes driver path
  cat > "$1/herdr-driver.sh" <<'SH'
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr || exit 9
render() {
  local rule
  rule=$(printf '─%.0s' $(seq 64))
  printf '● done\n%s\n' "$rule"
  if [ -s "$FM_FAKE_COMPOSER" ]; then
    fold -w 60 "$FM_FAKE_COMPOSER" | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }'
  else
    printf '❯ \n'
  fi
  printf '%s\n  ? for shortcuts\n' "$rule"
}
fm_backend_herdr_parse_target() { FM_BACKEND_HERDR_SESSION=s; FM_BACKEND_HERDR_PANE=p; }
fm_backend_herdr_visible_capture_ansi() { [ "${FM_FAKE_READ_FAIL:-0}" = 1 ] && return 1; render; }
fm_backend_herdr_visible_capture() { [ "${FM_FAKE_READ_FAIL:-0}" = 1 ] && return 1; render; }
fm_backend_herdr_capture() { printf '● done\n'; }
fm_backend_herdr_composer_identity() { printf 'claude\tidle'; }
fm_backend_herdr_agent_state() { printf 'idle'; }
fm_backend_herdr_busy_state() { printf '%s' "${FM_FAKE_BUSY_STATE:-idle}"; }
fm_backend_herdr_send_key() {
  local drops
  [ "$2" = Enter ] || return 0
  printf 'ENTER\n' >> "$FM_SEND_LOG"
  drops=$(cat "$FM_FAKE_DROP_ENTERS" 2>/dev/null || echo 0)
  if [ "$drops" -gt 0 ]; then
    echo $((drops - 1)) > "$FM_FAKE_DROP_ENTERS"
  elif [ -s "$FM_FAKE_COMPOSER" ]; then
    printf 'SUBMIT: %s\n' "$(cat "$FM_FAKE_COMPOSER")" >> "$FM_SEND_LOG"
    : > "$FM_FAKE_COMPOSER"
  fi
}
fm_backend_herdr_send_text_submit() {
  printf 'TYPE: %s\n' "$2" >> "$FM_SEND_LOG"
  printf '%s' "$2" >> "$FM_FAKE_COMPOSER"
  printf 'empty'
}
fn=$1
shift
"$fn" "$@"
SH
  printf '%s\n' "$1/herdr-driver.sh"
}

# Issue 104: on Herdr the doorbell can be typed into a Claude composer and left
# unsubmitted while the submit reports delivery, and that pending line then
# blocked every later ring. The ring re-reads the composer after typing and
# presses Enter only with an idle proof, never retyping; other pending text is
# untouched.
test_herdr_ring_submits_a_typed_doorbell_left_pending() {
  local dir state rec doorbell log composer drops driver rc
  dir="$TMP_ROOT/herdr-ring-pending"
  state="$dir/state"
  mkdir -p "$state"
  driver=$(make_herdr_composer_driver "$dir")
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  log="$dir/send.log"; composer="$dir/composer"; drops="$dir/drops"
  herdr_fn() {
    ROOT="$ROOT" FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" FM_FAKE_COMPOSER="$composer" \
      FM_FAKE_DROP_ENTERS="$drops" FM_FAKE_BUSY_STATE="${FM_FAKE_BUSY_STATE:-idle}" \
      FM_FAKE_READ_FAIL="${FM_FAKE_READ_FAIL:-0}" bash "$driver" "$@"
  }

  : > "$log"; : > "$composer"; echo 0 > "$drops"
  rc=0; herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "a typed doorbell left pending should be submitted, got rc $rc:"$'\n'"$(cat "$log")"
  [ "$(cat "$log")" = "TYPE: $doorbell"$'\n'"ENTER"$'\n'"SUBMIT: $doorbell" ] \
    || fail "the pending doorbell should be submitted with one Enter and typed once:"$'\n'"$(cat "$log")"
  [ ! -s "$composer" ] || fail "the typed doorbell was left in the composer"

  : > "$log"; : > "$composer"; echo 1 > "$drops"
  rc=0; herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "a pending doorbell whose first Enter is lost should still submit, got rc $rc"
  [ "$(grep -c '^TYPE: ' "$log")" = 1 ] || fail "the doorbell was retyped:"$'\n'"$(cat "$log")"
  [ "$(grep -c '^SUBMIT: ' "$log")" = 1 ] || fail "the second Enter did not submit:"$'\n'"$(cat "$log")"
  [ ! -s "$composer" ] || fail "a lost Enter left the doorbell unsubmitted"

  : > "$log"; : > "$composer"; echo 9 > "$drops"
  rc=0; herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 2 ] || fail "a doorbell still pending after the Enter budget should report not delivered, got rc $rc"
  [ "$(grep -c '^ENTER$' "$log")" = 2 ] || fail "the Enter budget should be 2 presses:"$'\n'"$(cat "$log")"
  [ "$(grep -c '^TYPE: ' "$log")" = 1 ] || fail "the doorbell was retyped:"$'\n'"$(cat "$log")"

  : > "$log"; printf '%s' "$doorbell" > "$composer"; echo 0 > "$drops"
  rc=0; herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "a doorbell already pending should be submitted, got rc $rc"
  [ "$(cat "$log")" = "ENTER"$'\n'"SUBMIT: $doorbell" ] \
    || fail "an already pending doorbell should be submitted, not retyped:"$'\n'"$(cat "$log")"

  : > "$log"; printf '%s' "$doorbell" > "$composer"; echo 0 > "$drops"
  rc=0; FM_FAKE_BUSY_STATE=busy herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 1 ] || fail "a busy pane holding the doorbell should defer, got rc $rc"
  [ ! -s "$log" ] || fail "a busy pane received an extra Enter:"$'\n'"$(cat "$log")"
  [ "$(cat "$composer")" = "$doorbell" ] || fail "a busy pane lost its queued doorbell"

  : > "$log"; : > "$composer"; echo 0 > "$drops"
  rc=0; FM_FAKE_BUSY_STATE=busy herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "a busy submit result should be preserved, got rc $rc"
  [ "$(cat "$log")" = "TYPE: $doorbell" ] || fail "a busy submit result was retried:"$'\n'"$(cat "$log")"
  [ -s "$composer" ] || fail "a busy submit result lost the queued doorbell"

  : > "$log"; : > "$composer"; echo 0 > "$drops"
  rc=0; FM_FAKE_READ_FAIL=1 herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 2 ] || fail "an unreadable composer should report failure, got rc $rc"
  [ "$(cat "$log")" = "TYPE: $doorbell" ] || fail "an unreadable composer was treated as delivered:"$'\n'"$(cat "$log")"
  [ -s "$composer" ] || fail "an unreadable composer lost the typed doorbell"

  : > "$log"; printf 'a half-typed draft' > "$composer"
  rc=0; herdr_fn fm_task_inbox_ring herdr s:p "$rec" || rc=$?
  [ "$rc" = 1 ] || fail "other pending text should skip the ring, got rc $rc"
  [ ! -s "$log" ] || fail "other pending text was touched:"$'\n'"$(cat "$log")"

  pass "inbox: on herdr the ring submits an unsubmitted doorbell only with an idle proof"
}

# The stuck-busy helper presses Enter only on proof: the shared classifier reads
# the composer as pending AND its text is exactly this record's doorbell. A
# busy native state does not veto it, because a busy pane is the stuck-busy
# premise; foreign text or an unreadable composer never gets an Enter.
test_herdr_stuck_busy_submits_only_a_proven_doorbell() {
  local dir state rec doorbell log composer drops driver rc other
  dir="$TMP_ROOT/herdr-stuck-busy"
  state="$dir/state"
  mkdir -p "$state"
  driver=$(make_herdr_composer_driver "$dir")
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  log="$dir/send.log"; composer="$dir/composer"; drops="$dir/drops"
  stuck_fn() {
    ROOT="$ROOT" FM_STATE_OVERRIDE="$state" FM_SEND_LOG="$log" FM_FAKE_COMPOSER="$composer" \
      FM_FAKE_DROP_ENTERS="$drops" FM_FAKE_BUSY_STATE=busy \
      FM_FAKE_READ_FAIL="${FM_FAKE_READ_FAIL:-0}" \
      bash "$driver" fm_task_inbox_submit_stuck_doorbell herdr s:p "$rec"
  }

  : > "$log"; printf '%s' "$doorbell" > "$composer"; echo 0 > "$drops"
  rc=0; stuck_fn || rc=$?
  [ "$rc" = 0 ] || fail "our own pending doorbell on a busy pane should be submitted, got rc $rc"
  [ "$(cat "$log")" = "ENTER"$'\n'"SUBMIT: $doorbell" ] \
    || fail "our own pending doorbell should get exactly one Enter and no retype:"$'\n'"$(cat "$log")"

  : > "$log"; printf '%s' "$doorbell" > "$composer"; echo 9 > "$drops"
  rc=0; stuck_fn || rc=$?
  [ "$rc" = 1 ] || fail "a doorbell still pending after the Enter budget should escalate, got rc $rc"
  [ "$(grep -c '^ENTER$' "$log")" = 2 ] || fail "the stuck-busy Enter budget should be 2 presses:"$'\n'"$(cat "$log")"

  echo 0 > "$drops"
  for other in 'a half-typed draft' "$doorbell and a draft" ''; do
    : > "$log"; printf '%s' "$other" > "$composer"
    rc=0; stuck_fn || rc=$?
    [ "$rc" = 1 ] || fail "the stuck-busy helper should escalate for '$other', got rc $rc"
    [ ! -s "$log" ] || fail "the stuck-busy helper pressed Enter on '$other':"$'\n'"$(cat "$log")"
    [ "$(cat "$composer")" = "$other" ] || fail "the stuck-busy helper changed '$other'"
  done

  : > "$log"; printf '%s' "$doorbell" > "$composer"
  rc=0; FM_FAKE_READ_FAIL=1 stuck_fn || rc=$?
  [ "$rc" = 1 ] || fail "an unreadable composer should escalate, got rc $rc"
  [ ! -s "$log" ] || fail "an unreadable composer received an Enter:"$'\n'"$(cat "$log")"
  pass "inbox: stuck-busy presses Enter only for a composer proven to hold exactly our doorbell"
}

# Before escalating stuck-busy, the watcher submits our own doorbell when it is
# proven to be what sits in the composer, counting that as a delivery attempt;
# a busy pane holding foreign text still escalates without any key.
test_watcher_stuck_busy_submits_pending_doorbell() {
  local dir rec doorbell composer
  dir=$(busy_case busy-pending-doorbell)
  make_composer_stub "$dir"
  rec="$dir/state/t1.inbox/001.msg"
  doorbell=$(inbox_lib "$dir/state" fm_task_inbox_doorbell_line "$rec")
  composer="$dir/composer"
  printf '%s' "$doorbell" > "$composer"
  # The pane reads busy from a token in its ordinary output rather than a
  # spinner row, so the classifier still sees the composer: the case under test
  # is the watcher's wiring, not how a spinner affects the classifier.
  stuck_check() {
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_SEND_LOG="$dir/send.log" \
      FM_FAKE_COMPOSER="$composer" FM_FAKE_DROP_ENTERS="$dir/drops" FM_FAKE_LOG_TYPES=1 \
      FM_BUSY_REGEX='● done' FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 \
      bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$dir/check.out" 2>&1
  }
  stuck_check
  [ ! -s "$dir/send.log" ] || fail "the first busy deferral typed or pressed:"$'\n'"$(cat "$dir/send.log")"
  stuck_check
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a busy pane holding our own doorbell escalated instead of submitting it:"$'\n'"$(cat "$dir/state/.wake-queue")"
  [ "$(cat "$dir/send.log")" = "SUBMIT: $doorbell" ] \
    || fail "the stuck-busy check should submit the pending doorbell with Enter only:"$'\n'"$(cat "$dir/send.log")"
  [ ! -e "$dir/state/t1.inbox/.busy-state" ] || fail "a submitted doorbell did not reset the busy budget"
  [ -s "$dir/state/t1.inbox/.ring-state" ] || fail "a submitted doorbell was not recorded as a delivery attempt"
  [ -f "$rec" ] || fail "submitting the doorbell removed the durable record"

  : > "$dir/send.log"; printf 'a half-typed draft' > "$composer"
  stuck_check
  stuck_check
  grep -q 'stuck-busy after 2 consecutive' "$dir/state/.wake-queue" \
    || fail "a busy pane with foreign pending text did not escalate stuck-busy"
  [ ! -s "$dir/send.log" ] || fail "stuck-busy escalation pressed a key on foreign text:"$'\n'"$(cat "$dir/send.log")"
  [ "$(cat "$composer")" = 'a half-typed draft' ] || fail "stuck-busy escalation changed foreign text"
  pass "watcher: stuck-busy submits a proven pending doorbell before escalating and never touches foreign text"
}

# A real Herdr Claude viewport keeps the long doorbell in a bare composer
# wrapped across rows between the harness's separator rules. Exercise the
# backend adapter as well as the shared classifier, because this is the exact
# shape used by the stuck-doorbell recovery path.
test_herdr_claude_wrapped_doorbell_is_pending() {
  local line wrapped screen out
  # shellcheck disable=SC2016 # The doorbell line intentionally names $FM_TASK_INBOX literally.
  line=': Firstmate instruction waiting: list "$FM_TASK_INBOX"/*.msg in your '\''task.inbox'\'' steering inbox, read and act on each in numeric order, then mv each into its handled/.'
  wrapped=$(printf '%s' "$line" | fold -w 60 | awk 'NR == 1 { print "❯ " $0; next } { print "  " $0 }')
  screen=$'transcript line\n────────────────────────────────────────────────────────────────────────\n'"$wrapped"$'\n────────────────────────────────────────────────────────────────────────\n  ⏵⏵ bypass permissions on'
  out=$(FM_TEST_HERDR_SCREEN="$screen" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_source herdr || exit 9
    fm_backend_herdr_parse_target() {
      FM_BACKEND_HERDR_SESSION=fixture
      FM_BACKEND_HERDR_PANE=pane
    }
    fm_backend_herdr_visible_capture_ansi() { printf "%s" "$FM_TEST_HERDR_SCREEN"; }
    fm_backend_herdr_visible_capture() { printf "%s" "$FM_TEST_HERDR_SCREEN"; }
    fm_backend_herdr_composer_identity() { printf "claude\\tidle"; }
    fm_backend_herdr_composer_state fixture:pane
  ' _ "$ROOT")
  [ "$out" = pending ] || fail "a wrapped Claude Herdr doorbell should read pending, got '$out'"
  pass "herdr composer state: the wrapped Claude doorbell reads pending"
}

test_herdr_ring_submits_a_typed_doorbell_left_pending
test_herdr_stuck_busy_submits_only_a_proven_doorbell
test_watcher_stuck_busy_submits_pending_doorbell
test_herdr_claude_wrapped_doorbell_is_pending
