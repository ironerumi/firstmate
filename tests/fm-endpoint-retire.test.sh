#!/usr/bin/env bash
# Tests for bin/fm-endpoint-retire-lib.sh, driven through bin/fm-pr-check.sh: once a
# finished ship's merge poll is armed, its worker endpoint is retired so only the
# poll waits, and nothing but the endpoint is touched.
# Backend CLIs and the control plane are canned fakes - never a real session or agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-retire-tests)
PR_URL=https://github.com/example/repo/pull/7
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# One ship task on herdr whose worker has reported done for $PR_URL, with a stateful
# fake herdr (the pane exists while $dir/pane-alive does) and a fake control plane
# that records what it saw. Extra meta lines may be passed to override the defaults.
make_case() {  # <name> [backend] [last-status-line]
  local name=$1 backend=${2:-herdr} status=${3:-"done [at=1]: PR $PR_URL checks green"} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/wt"
  : > "$dir/pane-alive"
  : > "$dir/herdr-log"
  : > "$dir/control-log"
  {
    echo "window=fmlab:%7"
    echo "endpoint_task_id=t1"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "spawn_gen=gen1"
    if [ "$backend" = herdr ]; then
      echo "backend=herdr"
      echo "herdr_session=fmlab"
      echo "herdr_workspace_id=ws1"
      echo "herdr_tab_id=tab1"
      echo "herdr_pane_id=%7"
    else
      echo "backend=$backend"
    fi
  } > "$dir/state/t1.meta"
  printf '%s\n' "$status" > "$dir/state/t1.status"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
case "${1:-} ${2:-}" in
  'session list')
    printf '{"sessions":[{"name":"fmlab","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'pane get')
    if [ -e "$D/pane-alive" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"tab1","workspace_id":"ws1"}}}\n' "${3:-}"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'pane close')
    # A close the harness swallowed leaves the pane standing.
    [ -e "$D/close-is-ignored" ] || rm -f "$D/pane-alive"
    exit 0 ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n'; exit 0 ;;
  'tab list') printf '{"result":{"tabs":[]}}\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/control" <<'SH'
#!/usr/bin/env bash
# The control plane stand-in: records the verb and whether the endpoint was still
# standing when the exit was asked for, then answers per the case.
[ "$(cat "$FM_FAKE_DIR/state/.control-t1.lock/pid" 2>/dev/null || true)" = "${FM_CONTROL_LOCK_OWNER:-}" ] \
  || { echo "wrong lifecycle lock owner" >&2; exit 1; }
printf '%s %s pane-alive=%s\n' "$2" "$1" "$([ -e "$FM_FAKE_DIR/pane-alive" ] && echo 1 || echo 0)" >> "$FM_FAKE_DIR/control-log"
if [ -e "$FM_FAKE_DIR/control-refuses" ]; then
  echo "error: the composer visibly holds pending text" >&2
  exit 1
fi
printf 'stopped'
SH
  cat > "$dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' $HEAD_SHA ;;
      *) printf '{"state":"OPEN","isDraft":false,"headRefOid":"%s"}\n' $HEAD_SHA ;;
    esac ;;
esac
exit 0
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *' #{pane_id} '*|*' #{pane_current_command} '*)
    [ -e "$FM_FAKE_DIR/pane-alive" ] || exit 1
    [ ! -e "$FM_FAKE_DIR/tmux-probe-fails" ] || exit 1
    printf '%s\n' '%7'
    ;;
  *' list-windows '*)
    [ ! -e "$FM_FAKE_DIR/tmux-probe-fails" ] || { echo 'tmux unavailable' >&2; exit 1; }
    printf '%s\n' '%7'
    ;;
  *' kill-window '*)
    [ ! -e "$FM_FAKE_DIR/tmux-probe-fails" ] || exit 1
    rm -f "$FM_FAKE_DIR/pane-alive"
    ;;
esac
SH
  chmod +x "$dir/fakebin/herdr" "$dir/fakebin/control" "$dir/fakebin/gh" "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

run_pr_check() {  # <case-dir> [extra env assignments...]
  local dir=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_FAKE_DIR="$dir" FM_ENDPOINT_RETIRE_CONTROL_BIN="$dir/fakebin/control" \
    PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" t1 "$PR_URL" > "$dir/out" 2> "$dir/err"
}

run_endpoint_retire() {  # <case-dir>
  local dir=$1
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_FAKE_DIR="$dir" FM_ENDPOINT_RETIRE_CONTROL_BIN="$dir/fakebin/control" \
    PATH="$dir/fakebin:$PATH" \
    bash -c '. "$0/bin/fm-wake-lib.sh"; . "$0/bin/fm-endpoint-retire-lib.sh"; fm_endpoint_retire "$FM_HOME" "$FM_STATE_OVERRIDE" t1' "$ROOT"
}

crew_state() {  # <case-dir>
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/home/data" FM_CONFIG_OVERRIDE="$1/home/config" \
    FM_FAKE_DIR="$1" PATH="$1/fakebin:$PATH" "$CREW_STATE" t1 2>/dev/null
}

meta_has() { grep -q "^$2=" "$1/state/t1.meta"; }

# 0 when nothing was done to the endpoint: no control-plane call, no pane close,
# the pane still standing, and no retired claim in the record.
untouched() {  # <case-dir> [allow-control-call]
  [ -n "${2:-}" ] || [ ! -s "$1/control-log" ] || return 1
  ! grep -q '^pane close' "$1/herdr-log" || return 1
  [ -e "$1/pane-alive" ] || return 1
  ! meta_has "$1" endpoint_retired
}

test_arming_retires_the_finished_workers_endpoint() {
  local dir
  dir=$(make_case retire-happy)
  run_pr_check "$dir" || fail "pr-check failed on a finished herdr ship: $(cat "$dir/err")"

  grep -q '^armed: state/t1.check.sh$' "$dir/out" || fail "the merge poll was not armed: $(cat "$dir/out")"
  grep -q '^endpoint: retired:' "$dir/out" || fail "the retirement was not reported: $(cat "$dir/out")"
  # Explicit ordering: the agent exits through the control plane while the endpoint
  # still stands, and only then is the pane closed.
  [ "$(cat "$dir/control-log")" = 'exit t1 pane-alive=1' ] \
    || fail "the worker was not exited through the control plane first: $(cat "$dir/control-log")"
  grep -q '^pane close %7' "$dir/herdr-log" || fail "the pane was never closed: $(cat "$dir/herdr-log")"
  [ ! -e "$dir/pane-alive" ] || fail "the endpoint still stands"
  meta_has "$dir" endpoint_retired || fail "no retired marker was recorded"
  meta_has "$dir" pr || fail "the armed PR record was lost"
  # Only the endpoint went: the poll, status log, and local copy are intact.
  [ -x "$dir/state/t1.check.sh" ] || [ -f "$dir/state/t1.check.sh" ] || fail "the armed poll is gone"
  [ -f "$dir/state/t1.status" ] && [ -d "$dir/wt" ] || fail "retirement touched more than the endpoint"
  pass "arming a finished ship's merge poll exits its worker, closes its endpoint, and records it"
}

test_tmux_retirement_closes_and_confirms_the_recorded_window() {
  local dir
  dir=$(make_case retire-tmux tmux)
  run_pr_check "$dir" || fail "pr-check failed on a finished tmux ship: $(cat "$dir/err")"
  grep -q '^endpoint: retired:' "$dir/out" || fail "the tmux endpoint was not retired: $(cat "$dir/out")"
  [ "$(cat "$dir/control-log")" = 'exit t1 pane-alive=1' ] \
    || fail "the tmux worker was not exited through the control plane first: $(cat "$dir/control-log")"
  [ ! -e "$dir/pane-alive" ] || fail "the tmux endpoint still stands"
  meta_has "$dir" endpoint_retired || fail "the tmux record lacks a retired marker"
  pass "tmux retirement exits, closes, and confirms the worker window"
}

test_tmux_close_probe_failure_leaves_the_endpoint_unretired() {
  local dir
  dir=$(make_case retire-tmux-probe-failure tmux)
  : > "$dir/tmux-probe-fails"
  run_pr_check "$dir" || fail "a tmux close-probe failure failed the arming: $(cat "$dir/err")"
  grep -q '^actionable: failed: endpoint fmlab:%7 is not confirmed gone' "$dir/err" \
    || fail "a tmux close-probe failure was not reported as actionable: $(cat "$dir/err")"
  grep -q '^armed: ' "$dir/out" || fail "a tmux close-probe failure prevented the armed report"
  [ -e "$dir/pane-alive" ] || fail "a tmux close-probe failure hid the live endpoint"
  ! meta_has "$dir" endpoint_retired || fail "a tmux close-probe failure wrote a retired marker"
  pass "a tmux close-probe failure leaves the endpoint unretired"
}

test_non_recovery_backend_is_left_under_existing_supervision() {
  local dir
  dir=$(make_case retire-non-recovery zellij)
  run_pr_check "$dir" || fail "a non-recovery backend prevented arming: $(cat "$dir/err")"
  grep -q '^endpoint: skipped: backend zellij is not recovery-grade' "$dir/out" \
    || fail "a non-recovery backend was not left under existing supervision: $(cat "$dir/out")"
  untouched "$dir" || fail "a non-recovery backend was touched"
  pass "non-recovery backends remain under their existing supervision contract"
}

test_relaunch_before_lifecycle_lock_is_not_retired() {
  local dir lock holder out tmp
  dir=$(make_case retire-race tmux)
  lock="$dir/state/.control-t1.lock"
  (
    mkdir "$lock"
    printf '%s\n' "$BASHPID" > "$lock/pid"
    sleep 0.3
    tmp="$dir/state/t1.meta.race"
    awk -F= '{
      if ($1 == "window") print "window=fmlab:%8"
      else if ($1 == "spawn_gen") print "spawn_gen=gen2"
      else print
    }' "$dir/state/t1.meta" > "$tmp" && mv -f "$tmp" "$dir/state/t1.meta"
    rm -rf "$lock"
  ) &
  holder=$!
  while [ ! -f "$lock/pid" ]; do sleep 0.01; done
  out=$(run_endpoint_retire "$dir") || fail "retirement failed while a relaunch won the lock: $out"
  wait "$holder"
  [ "$out" = "skipped: endpoint changed while waiting for its lifecycle lock" ] \
    || fail "a relaunch before retirement was not rejected: $out"
  [ ! -s "$dir/control-log" ] || fail "retirement controlled the replacement endpoint"
  [ -e "$dir/pane-alive" ] || fail "the replacement endpoint was hidden"
  ! meta_has "$dir" endpoint_retired || fail "a relaunch race wrote a retired marker"
  pass "a relaunch that wins before retirement is never retired"
}

test_retired_task_reads_as_waiting_on_merge() {
  local dir state
  dir=$(make_case retire-state)
  run_pr_check "$dir" || fail "pr-check failed: $(cat "$dir/err")"
  state=$(crew_state "$dir")
  case "$state" in
    'state: done'*'endpoint retired, waiting on merge'*) ;;
    *) fail "a retired task did not read as done and waiting on merge: $state" ;;
  esac
  pass "a retired endpoint reads as waiting on merge, not as a dead record"
}

test_declined_retirements_leave_the_endpoint_alone() {
  local dir
  # A worker whose latest status is not done may still be working.
  dir=$(make_case retire-working herdr 'working [at=1]: fixing a review comment')
  run_pr_check "$dir" || fail "pr-check failed on a working task: $(cat "$dir/err")"
  grep -q '^endpoint: skipped: the worker.s latest status is not done' "$dir/out" \
    || fail "a worker that is not done was not declined: $(cat "$dir/out")"
  untouched "$dir" \
    || fail "a not-done worker was touched"

  # A control plane that refuses the exit (pending composer text, unverified agent)
  # leaves the endpoint standing; arming still succeeded.
  dir=$(make_case retire-refused)
  : > "$dir/control-refuses"
  run_pr_check "$dir" || fail "a refused exit failed the arming: $(cat "$dir/err")"
  grep -q '^endpoint: skipped: the worker did not exit cleanly' "$dir/out" || fail "a refused exit was not reported: $(cat "$dir/out")"
  grep -q '^armed: ' "$dir/out" || fail "a refused exit prevented the armed report"
  untouched "$dir" allow-control \
    || fail "an endpoint whose worker would not exit was closed"
  pass "retirement leaves working workers alone and respects control-plane refusal"
}

test_unconfirmed_close_is_reported_and_unrecorded() {
  local dir
  dir=$(make_case retire-unconfirmed)
  : > "$dir/close-is-ignored"
  run_pr_check "$dir" || fail "an unconfirmed close failed the arming: $(cat "$dir/err")"
  grep -q '^actionable: failed: endpoint fmlab:%7 is not confirmed gone' "$dir/err" \
    || fail "an unconfirmed close was not reported as actionable: $(cat "$dir/err")"
  grep -q '^armed: ' "$dir/out" || fail "an unconfirmed close prevented the armed report"
  ! meta_has "$dir" endpoint_retired || fail "a record claims an endpoint gone that was not confirmed gone"
  pass "a close that cannot be confirmed leaves no retired claim and does not undo the arming"
}

test_merge_time_rerecord_retires_nothing() {
  local dir
  dir=$(make_case retire-merge-record)
  run_pr_check "$dir" FM_PR_CHECK_MERGE=1 || fail "the merge-time re-record failed: $(cat "$dir/err")"
  grep -q '^endpoint:' "$dir/out" && fail "the merge-time re-record reported a retirement"
  untouched "$dir" \
    || fail "the merge-time re-record touched the endpoint"
  pass "the merge-time re-record is not a ready report and retires nothing"
}

test_arming_retires_the_finished_workers_endpoint
test_tmux_retirement_closes_and_confirms_the_recorded_window
test_tmux_close_probe_failure_leaves_the_endpoint_unretired
test_non_recovery_backend_is_left_under_existing_supervision
test_relaunch_before_lifecycle_lock_is_not_retired
test_retired_task_reads_as_waiting_on_merge
test_declined_retirements_leave_the_endpoint_alone
test_unconfirmed_close_is_reported_and_unrecorded
test_merge_time_rerecord_retires_nothing
