#!/usr/bin/env bash
# Composition tests for the real fleet worker environment.
#
# bin/fm-spawn.sh puts three independent mechanisms in a worker's pane: the guard
# shims on PATH, FM_WORKTREE_GUARD_META, and a spawn-installed core.hooksPath. Each
# has its own suite, and each suite passes alone. On 2026-09-28 the three met for
# the first time in a real pane and every guarded worker commit was refused
# (the commit-msg hook `mv`s a temp file into the linked worktree's admin
# directory, which the guard read as an escape); two workers then routed around
# the refusal with --no-verify and nothing told firstmate for 31.5 hours. The
# 2026-09-30 lock-cleanup failure was the same class: library `rm`/`mv` running
# under the shims.
#
# The environment here is built from bin/fm-worker-env-lib.sh, the same code
# fm-spawn.sh sends, in a LINKED worktree with the guard's temp-namespace
# exemption disabled, because a fixture under /tmp passes without ever reaching
# the check that failed. Every verb a worker uses must succeed, a deliberate
# escape must still be refused, and a skipped hook must be refused and reported.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-worker-env-lib.sh
. "$ROOT/bin/fm-worker-env-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-env-composition)
fm_git_identity fmtest fmtest@example.invalid
REAL_GIT=$(fm_real_tool git)

ID=t1
PRIMARY="$TMP_ROOT/primary"
WT="$TMP_ROOT/pool/own"
STATE="$TMP_ROOT/state"
TASKTMP="$TMP_ROOT/tasktmp"
HOOKS="$STATE/$ID.git-hooks"
STATUS="$STATE/$ID.status"
NEVER_TEMP="$TMP_ROOT/never-a-temp-root"

# The strip installer leaves the hooks directory read-only on purpose.
trap 'chmod -R u+w "$HOOKS" 2>/dev/null; fm_test_cleanup' EXIT

mkdir -p "$STATE" "$TASKTMP" "$TMP_ROOT/pool"
"$REAL_GIT" init -q -b main "$PRIMARY"
printf 'base\n' > "$PRIMARY/a.txt"
"$REAL_GIT" -C "$PRIMARY" add a.txt
"$REAL_GIT" -C "$PRIMARY" commit -q -m init
"$REAL_GIT" -C "$PRIMARY" worktree add -q -b work "$WT"
BASE=$("$REAL_GIT" -C "$PRIMARY" rev-parse HEAD)
fm_write_meta "$STATE/$ID.meta" \
  "window=firstmate:fm-$ID" \
  "endpoint_task_id=$ID" \
  "worktree=$WT" \
  "project=$PRIMARY" \
  "harness=claude" \
  "kind=ship" \
  "tasktmp=$TASKTMP"
"$ROOT/bin/fm-git-strip-ai-trailers.sh" install "$HOOKS" "$WT" \
  || fail "fixture: the spawn hook installer failed"

# Run a command the way a worker's tool call meets it. The two export lines are
# the ones fm-spawn.sh sends. Two deliberate fixture choices, both stated:
# FM_WORKTREE_GUARD_TEMP_ROOTS points the exemption at a directory that holds
# nothing, so no path is exempt merely for living under a temp directory, and
# TMPDIR is the task's own temp directory (the guard's tasktmp allowance) so the
# hook's scratch file is allowed on the source side and only the destination
# check, the linked worktree's admin directory, is under test.
worker() { # <cwd> <command...>
  local cwd=$1
  shift
  (
    cd "$cwd" || exit 99
    eval "$(fm_worker_guard_export_line "$STATE" "$ID" "$ROOT/bin")"
    eval "$(fm_worker_hooks_export_line "$HOOKS")"
    export FM_WORKTREE_GUARD_TEMP_ROOTS="$NEVER_TEMP" TMPDIR="$TASKTMP" GIT_EDITOR=true
    # Fake tools go behind the shims, never ahead of them.
    [ -z "${WORKER_FAKEBIN:-}" ] || PATH="${PATH%%:*}:$WORKER_FAKEBIN:${PATH#*:}"
    unset FM_WORKTREE_GUARD_ALLOW FM_NM_GUARD_ALLOW FM_TASK_ID
    "$@"
  )
}

wgit() { worker "$WT" git "$@"; }

# Run a worker command that must succeed, showing its output when it does not.
must() { # <label> <command...>
  local label=$1 out status=0
  shift
  out=$("$@" 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "$label: exit $status: $out"
  return 0
}

must_refuse() { # <label> <expected-code> <command...>
  local label=$1 code=$2 out status=0
  shift 2
  out=$("$@" 2>&1) || status=$?
  [ "$status" -eq 3 ] || fail "$label: expected the guard refusal (exit 3), got $status: $out"
  case "$out" in
    *"REFUSED BY FIRSTMATE [$code]"*) ;;
    *) fail "$label: refused, but not as [$code]: $out" ;;
  esac
}

must_not_refuse() { # <label> <command...>
  local label=$1 out status=0
  shift
  out=$("$@" 2>&1) || status=$?
  [ "$status" -ne 3 ] || fail "$label: unexpectedly hit a guard refusal: $out"
  case "$out" in
    *"REFUSED BY FIRSTMATE"*) fail "$label: unexpectedly rendered a refusal: $out" ;;
  esac
}

blocked_lines() { # <key>
  grep -c "^blocked .*\[key=$1\]" "$STATUS" 2>/dev/null || true
}

test_fixture_is_the_real_worker_environment() {
  local shim hooks
  shim=$(worker "$WT" type -P git)
  [ "$shim" = "$ROOT/bin/shims/git" ] || fail "git in the worker env is not the guard shim: $shim"
  hooks=$(wgit config core.hooksPath)
  [ "$hooks" = "$HOOKS" ] || fail "core.hooksPath in the worker env is not the spawn hooks dir: $hooks"
  [ -f "$WT/.git" ] || fail "the worktree is not a linked worktree"
  pass "fixture: shims first on PATH, spawn core.hooksPath installed, linked worktree"
}

test_guard_is_live_and_temp_exemption_is_off() {
  printf 'x\n' > "$PRIMARY/outside.txt"
  must_refuse "control: rm outside the worktree" worktree-escape-delete worker "$WT" rm "$PRIMARY/outside.txt"
  [ -e "$PRIMARY/outside.txt" ] || fail "control: the refused rm removed the file anyway"
  printf 'y\n' > "$TMP_ROOT/scratch.txt"
  must_refuse "control: a temp-namespace path is not exempt here" worktree-escape-delete worker "$WT" rm "$TMP_ROOT/scratch.txt"
  [ "$(blocked_lines guard-worktree-escape-delete)" = 1 ] \
    || fail "the refusals were not reported exactly once on the status record: $(cat "$STATUS")"
  pass "control: an escaping rm is refused, even under the temp namespace, and reported once"
}

test_concurrent_refusal_reporting() {
  local i rc pending deadline done_file
  local -a pids done_files
  : > "$STATUS"
  i=0
  while [ "$i" -lt 8 ]; do
    printf 'outside\n' > "$PRIMARY/concurrent-$i.txt"
    done_file="$TMP_ROOT/refusal-$i.done"
    done_files[$i]=$done_file
    (
      worker "$WT" rm -f "$PRIMARY/concurrent-$i.txt" >"$TMP_ROOT/refusal-$i.out" 2>&1
      rc=$?
      printf '%s\n' "$rc" > "$done_file"
      exit "$rc"
    ) &
    pids[$i]=$!
    i=$((i + 1))
  done

  deadline=$((SECONDS + 5))
  while :; do
    pending=0
    i=0
    while [ "$i" -lt 8 ]; do
      [ -f "${done_files[$i]}" ] || pending=1
      i=$((i + 1))
    done
    [ "$pending" -eq 0 ] && break
    [ "$SECONDS" -lt "$deadline" ] || {
      i=0
      while [ "$i" -lt 8 ]; do kill "${pids[$i]}" 2>/dev/null || true; i=$((i + 1)); done
      while [ "$i" -gt 0 ]; do i=$((i - 1)); wait "${pids[$i]}" 2>/dev/null || true; done
      fail "concurrent refusals did not exit within the bound"
    }
    sleep 0.05
  done

  i=0
  while [ "$i" -lt 8 ]; do
    IFS= read -r rc < "${done_files[$i]}" || rc=
    [ "$rc" = 3 ] || fail "concurrent refusal $i exited $rc instead of 3"
    wait "${pids[$i]}" 2>/dev/null || true
    i=$((i + 1))
  done
  [ "$(blocked_lines guard-worktree-escape-delete)" = 1 ] \
    || fail "concurrent refusals must leave exactly one open report: $(cat "$STATUS")"
  pass "concurrent real-shim refusals exit promptly and report once"
}

test_commit_verbs_succeed_under_the_guard() {
  local body pick_sha
  printf 'one\n' > "$WT/one.txt"
  must "git add" wgit add one.txt
  must "commit -m" wgit commit -q -m $'one\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
  body=$(wgit log -1 --format=%B)
  case "$body" in
    *Co-Authored-By*) fail "the spawn hook did not run: the AI trailer reached the commit object" ;;
  esac
  pass "commit -m runs the spawn hook under the guard"

  printf 'two\n' >> "$WT/one.txt"
  must "git add" wgit add one.txt
  must "commit --amend" wgit commit -q --amend --no-edit
  pass "commit --amend under the guard"

  printf 'message from stdin\n' | worker "$WT" git commit -q --allow-empty -F - \
    || fail "commit -F - under the guard failed"
  pass "commit -F - under the guard"

  must "branch side" wgit checkout -q -b side
  printf 's\n' > "$WT/side.txt"
  must "git add" wgit add side.txt
  must "side commit" wgit commit -q -m side
  must "checkout work" wgit checkout -q work
  printf 'w\n' > "$WT/work.txt"
  must "git add" wgit add work.txt
  must "work commit" wgit commit -q -m work
  must "merge --no-ff" wgit merge -q --no-ff side -m merge-side
  [ "$(wgit rev-list --parents -1 HEAD | wc -w | tr -d ' ')" = 3 ] || fail "merge --no-ff did not create a merge commit"
  pass "merge --no-ff under the guard"

  must "branch pick" wgit checkout -q -b pick "$BASE"
  printf 'p\n' > "$WT/pick.txt"
  must "git add" wgit add pick.txt
  must "pick commit" wgit commit -q -m pick
  pick_sha=$(wgit rev-parse HEAD)
  must "checkout work" wgit checkout -q work
  must "cherry-pick" wgit cherry-pick "$pick_sha"
  pass "cherry-pick under the guard"

  # A conflicting pick stops with state files in the worktree's admin directory,
  # and --continue then runs the hook and rewrites them.
  must "branch conf" wgit checkout -q -b conf "$BASE"
  printf 'conflicting\n' > "$WT/a.txt"
  must "git add" wgit add a.txt
  must "conf commit" wgit commit -q -m conf
  pick_sha=$(wgit rev-parse HEAD)
  must "checkout work" wgit checkout -q work
  printf 'work side\n' > "$WT/a.txt"
  must "git add" wgit add a.txt
  must "work a.txt commit" wgit commit -q -m work-a
  wgit cherry-pick "$pick_sha" >/dev/null 2>&1 && fail "control: the conflicting cherry-pick did not stop"
  [ -f "$PRIMARY/.git/worktrees/own/CHERRY_PICK_HEAD" ] || fail "control: no cherry-pick in progress"
  printf 'resolved\n' > "$WT/a.txt"
  must "git add" wgit add a.txt
  must "cherry-pick --continue" wgit cherry-pick --continue
  pass "cherry-pick conflict then --continue under the guard"

  must "branch rb" wgit checkout -q -b rb "$BASE"
  printf 'r\n' > "$WT/rb.txt"
  must "git add" wgit add rb.txt
  must "rb commit" wgit commit -q -m rb
  must "rebase" wgit rebase -q work
  pass "rebase under the guard"

  must "branch rbc" wgit checkout -q -b rbc "$BASE"
  printf 'rebase conflicting\n' > "$WT/a.txt"
  must "git add" wgit add a.txt
  must "rbc commit" wgit commit -q -m rbc
  wgit rebase work >/dev/null 2>&1 && fail "control: the conflicting rebase did not stop"
  printf 'rebase resolved\n' > "$WT/a.txt"
  must "git add" wgit add a.txt
  must "rebase --continue" wgit rebase --continue
  pass "rebase conflict then --continue under the guard"

  must "checkout work" wgit checkout -q work
  must "revert" wgit revert --no-edit HEAD
  pass "revert under the guard"
}

test_skipping_hooks_is_refused_and_reported() {
  local verb pick_sha
  for verb in commit merge cherry-pick rebase revert am push; do
    must_refuse "$verb --no-verify" git-skip-hooks wgit "$verb" --no-verify
  done
  must_refuse "commit -n" git-skip-hooks wgit commit -n -m nope
  must_refuse "commit -an" git-skip-hooks wgit commit -an -m nope
  must_refuse "commit -nm" git-skip-hooks wgit commit -nm nope
  must_refuse "-C <dir> commit --no-verify" git-skip-hooks wgit -C "$WT" commit --no-verify -m nope
  [ "$(blocked_lines guard-git-skip-hooks)" = 1 ] \
    || fail "repeated refusals must leave exactly one open report, got: $(grep guard-git-skip-hooks "$STATUS")"
  pass "--no-verify and commit -n are refused on every hook-running verb, and reported once"

  must_not_refuse "push --dry-run" wgit push -n origin HEAD
  must_not_refuse "plain push" wgit push origin HEAD
  pass "push modes are not mistaken for hook skipping"

  # Where -n is not a hook skip, it must keep working.
  must "merge -n" wgit merge -n side
  must "branch np" wgit checkout -q -b np "$BASE"
  printf 'n\n' > "$WT/np.txt"
  must "git add" wgit add np.txt
  must "np commit" wgit commit -q -m np
  pick_sha=$(wgit rev-parse HEAD)
  must "checkout work" wgit checkout -q work
  must "cherry-pick -n" wgit cherry-pick -n "$pick_sha"
  must "reset" wgit reset -q --hard
  must "commit -m -n message" wgit commit -q --allow-empty -m '-n is only text here'
  pass "-n stays allowed where it is not --no-verify (merge, cherry-pick, a message)"

  # A resolved report re-opens on the next refusal.
  printf 'resolved [at=1] [key=guard-git-skip-hooks]: firstmate answered\n' >> "$STATUS"
  must_refuse "commit --no-verify after resolution" git-skip-hooks wgit commit --no-verify -m nope
  [ "$(blocked_lines guard-git-skip-hooks)" = 2 ] || fail "a refusal after resolution was not reported again"
  pass "a resolved refusal report re-opens on the next refusal"

  # The deliberate escape is unchanged.
  worker "$WT" env FM_WORKTREE_GUARD_ALLOW=1 git commit -q --allow-empty --no-verify -m escaped \
    || fail "FM_WORKTREE_GUARD_ALLOW=1 must still authorize the exact command"
  pass "FM_WORKTREE_GUARD_ALLOW=1 still authorizes an exact command"
}

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
PROCEVENT="$ROOT/bin/fm-procevent.sh"

# Lock bookkeeping (owner dirs, lock links, tombstones, claim files) lives in a
# state directory that is never inside the worker's worktree, so every `rm`/`mv`
# in the lock library meets the guard. A new one fails here instead of wedging a
# fleet home (the 2026-09-30 lock-cleanup class).
test_lock_reap_under_the_guard() {
  local dir state lock holder i=0
  dir=$(make_case guarded-lock)
  state="$dir/state"
  lock="$dir/locks/dead.lock"
  mkdir -p "$dir/locks"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_lock_try_acquire "$2" && exec sleep 300' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$lock" >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ] && [ ! -L "$lock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$lock" ] || [ -L "$lock" ] || fail "control: the holder never took the lock"
  kill -KILL "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  worker "$WT" env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_lock_try_acquire "$2" && fm_lock_release "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" \
    || fail "a guarded process could not reap a dead holder's lock and release its own"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "the reaped lock was left behind"
  [ -z "$(find "$dir/locks" -mindepth 1 2>/dev/null)" ] \
    || fail "reaping left bookkeeping behind: $(ls -a "$dir/locks")"
  pass "a dead holder's lock is reaped and cleaned up under the real worker environment"
}

test_watcher_arm_and_reconcile_under_the_guard() {
  local dir home state out status=0
  dir=$(make_case guarded-watcher)
  home="$dir/home"
  state="$dir/state"
  mkdir -p "$home/data"
  # A worker pane carries FM_TASK_ID (fm-spawn.sh) and must never arm a watcher.
  out=$(worker "$WT" env FM_TASK_ID="$ID" FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a worker pane armed a watcher: $out"
  case "$out" in
    *"REFUSED BY FIRSTMATE"*) fail "the guard, not the worker check, stopped the arm: $out" ;;
    *"refusing to arm from a worker pane"*) ;;
    *) fail "the arm did not stand down for the worker pane: $out" ;;
  esac
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] || fail "a refused arm left a watcher lock"
  pass "watcher arm from a guarded worker pane stands down cleanly"

  status=0
  out=$(worker "$WT" env FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$PROCEVENT" reconcile 2>&1) || status=$?
  case "$out" in
    *"REFUSED BY FIRSTMATE"*) fail "the guard refused procevent reconcile: $out" ;;
  esac
  [ "$status" -eq 0 ] || fail "procevent reconcile failed under the guard (exit $status): $out"
  pass "procevent reconcile runs under the guard with nothing refused"
}

# A suite run from a worker pane must never report its deliberate refusals on
# that pane's real task record. The canary stands in for the pane's status file
# and record; a suite that refuses things on purpose runs with both bound to it.
test_suites_do_not_report_to_the_callers_task_record() {
  local canary="$TMP_ROOT/canary"
  mkdir -p "$canary"
  fm_write_meta "$canary/real.meta" "worktree=$canary/nowhere" "kind=ship"
  : > "$canary/real.status"
  env FM_NM_GUARD_STATUS="$canary/real.status" FM_WORKTREE_GUARD_META="$canary/real.meta" \
    bash "$ROOT/tests/fm-lock-worktree-guard.test.sh" >/dev/null 2>&1 \
    || fail "control: the refusing suite failed under a bound pane environment"
  [ ! -s "$canary/real.status" ] \
    || fail "a suite reported its deliberate refusals on the caller's task record: $(cat "$canary/real.status")"
  pass "a suite run from a bound pane leaves that pane's task record untouched"
}

test_fixture_is_the_real_worker_environment
test_concurrent_refusal_reporting
test_guard_is_live_and_temp_exemption_is_off
test_commit_verbs_succeed_under_the_guard
test_skipping_hooks_is_refused_and_reported
test_lock_reap_under_the_guard
test_watcher_arm_and_reconcile_under_the_guard
test_suites_do_not_report_to_the_callers_task_record
