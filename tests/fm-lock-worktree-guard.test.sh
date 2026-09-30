#!/usr/bin/env bash
# Regression tests for the lock library under the worker worktree guard.
#
# A guarded worker pane puts bin/shims (rm, rmdir, mv) ahead of the real tools,
# and the guard refuses those tools against any path outside the task's own
# worktree (docs/worktree-guard.md). The lock library's own bookkeeping - owner
# dirs, lock links, tombstones - lives wherever the lock does, for example under
# ~/.local/state/firstmate/procevent-claims or a home's state/. Two failures
# followed from routing that bookkeeping through the guard (2026-09-30):
#   - every failed attempt created an owner dir and could not remove it, so a
#     watcher spinning on a held lock leaked about 207k empty dirs;
#   - a dead holder's lock could never be reaped or released, so it wedged every
#     other home's watcher behind the same lock.
# The cases run the real library through the real shims, with the lock outside the
# worker's worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-worktree-guard)
HOLDERS="$TMP_ROOT/holders"
: > "$HOLDERS"
stop_holders() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null
  done < "$HOLDERS"
  true
}
trap 'stop_holders; fm_test_cleanup' EXIT

WT="$TMP_ROOT/pool/own"
LOCKS="$TMP_ROOT/shared/locks"
STATE="$TMP_ROOT/state"
META="$STATE/t1.meta"
mkdir -p "$WT" "$LOCKS" "$STATE"
fm_write_meta "$META" \
  "window=firstmate:fm-t1" \
  "endpoint_task_id=t1" \
  "worktree=$WT" \
  "project=$TMP_ROOT/project" \
  "harness=claude" \
  "kind=ship" \
  "tasktmp=$TMP_ROOT/tasktmp"

# Run a snippet with the lock library loaded the way a worker pane meets it:
# shims first on PATH, the guard bound to this task's record, the temp namespace
# pinned elsewhere so the fixture's own location is not exempt, cwd inside the
# worker's worktree.
lock_guarded() { # <snippet> <lock>
  (
    cd "$WT" && \
    FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE" LIB="$ROOT/bin/fm-wake-lib.sh" \
      PATH="$ROOT/bin/shims:$PATH" \
      FM_WORKTREE_GUARD_META="$META" FM_WORKTREE_GUARD_TEMP_ROOTS="$TMP_ROOT/never-a-temp-root" \
      bash -c '. "$LIB"; '"$1" _ "$2"
  )
}

# Take the lock in a background process that keeps holding it. The process is
# the lock owner, so it is recorded as-is and killed by the exit trap.
start_holder() { # <lock>
  local i=0
  FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE" LIB="$ROOT/bin/fm-wake-lib.sh" \
    bash -c '. "$LIB"; fm_lock_try_acquire "$1" && exec sleep 300' _ "$1" >/dev/null 2>&1 &
  HOLDER_PID=$!
  printf '%s\n' "$HOLDER_PID" >> "$HOLDERS"
  while [ ! -e "$1" ] && [ ! -L "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ] || [ -L "$1" ] || fail "control: the holder never took the lock"
}

owner_dirs() { # <lock>
  find "$LOCKS" -maxdepth 1 -name "$(basename "$1").owner.*" | wc -l | tr -d ' '
}

test_guard_really_refuses_here() {
  mkdir "$LOCKS/probe"
  (cd "$WT" && PATH="$ROOT/bin/shims:$PATH" FM_WORKTREE_GUARD_META="$META" \
    FM_WORKTREE_GUARD_TEMP_ROOTS="$TMP_ROOT/never-a-temp-root" rmdir "$LOCKS/probe" >/dev/null 2>&1) \
    && fail "control: the fixture guard must refuse rmdir outside the worktree"
  [ -d "$LOCKS/probe" ] || fail "control: the refused rmdir removed the dir anyway"
  command rmdir "$LOCKS/probe"
  pass "fixture: the worker guard refuses rmdir outside the worktree"
}

test_held_lock_spin_leaks_no_owner_dirs() {
  local lock="$LOCKS/held.lock" i
  start_holder "$lock"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
    lock_guarded 'fm_lock_try_acquire "$1"' "$lock" && fail "a live holder's lock was acquired"
  done
  [ "$(owner_dirs "$lock")" = 1 ] \
    || fail "failed attempts on a held lock leaked owner dirs: $(owner_dirs "$lock") present, only the holder's expected"
  pass "spinning on a held lock under the guard leaves only the holder's owner dir"
}

test_guarded_holder_releases_its_own_lock() {
  local lock="$LOCKS/release.lock"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  lock_guarded 'fm_lock_try_acquire "$1" && fm_lock_release "$1"' "$lock" \
    || fail "a guarded holder could not acquire and release a lock outside its worktree"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "release left the lock behind"
  [ "$(owner_dirs "$lock")" = 0 ] || fail "release left its owner dir behind"
  pass "a guarded holder can release its own lock outside its worktree"
}

test_dead_holder_lock_is_reaped_under_the_guard() {
  local lock="$LOCKS/dead.lock"
  start_holder "$lock"
  kill -KILL "$HOLDER_PID" 2>/dev/null
  wait "$HOLDER_PID" 2>/dev/null
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  lock_guarded 'fm_lock_try_acquire "$1" && fm_lock_release "$1"' "$lock" \
    || fail "a guarded process could not reap a dead holder's lock"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "the reaped lock was left behind"
  [ ! -e "$lock.steal" ] && [ ! -L "$lock.steal" ] || fail "reaping left the steal mutex behind"
  [ "$(owner_dirs "$lock")" = 0 ] || fail "reaping left owner dirs behind: $(owner_dirs "$lock")"
  pass "a dead holder's lock is reaped and cleaned up even under the worker guard"
}

test_guard_really_refuses_here
test_held_lock_spin_leaks_no_owner_dirs
test_guarded_holder_releases_its_own_lock
test_dead_holder_lock_is_reaped_under_the_guard
