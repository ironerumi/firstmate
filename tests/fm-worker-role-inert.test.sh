#!/usr/bin/env bash
# Behavior tests for the worker-role stand-down of the primary-only harness
# surfaces (bin/fm-primary-scope-lib.sh owns the predicate).
#
# A ship or scout pane always carries the spawn-owned FM_TASK_ID marker
# (bin/fm-spawn.sh). Such a pane must never act as a home, even when its
# worktree still holds a retired secondmate home's `.fm-secondmate-home` marker
# and gitignored state/ (the 2026-09-30 slot-8 incident): the marker would
# otherwise force-include the slot as a guarded primary. Every case below builds
# that exact stale-home slot; the worker variant must stay inert and the same
# slot without the worker marker must still behave as a secondmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-role-inert)
fm_git_identity fmtest fmtest@example.invalid

trap fm_test_cleanup EXIT

# A retired secondmate home left in a pool slot: plain checkout, the marker,
# an in-flight task record, and the bin/ the hooks resolve themselves from.
make_stale_home_slot() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  printf 'retired-home\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  printf '%s\n' "$dir"
}

scope_matches() {  # <dir> [env assignments...]
  local dir=$1
  shift
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  env "$@" bash -c '. "$1/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$1" "$1/state"' _ "$dir"
}

test_scope_predicate_rejects_worker_with_stale_marker() {
  local dir
  dir=$(make_stale_home_slot "$TMP_ROOT/scope")
  scope_matches "$dir" FM_HOME="$dir" || fail "control: a marked home without the worker marker must stay primary"
  scope_matches "$dir" FM_HOME="$dir" FM_TASK_ID=some-task \
    && fail "a worker pane (FM_TASK_ID set) must never match primary scope, marker or not"
  pass "fm_primary_scope_matches: FM_TASK_ID overrides a stale .fm-secondmate-home marker"
}

test_session_start_run_stands_down_for_worker() {
  local dir out status=0
  dir=$(make_stale_home_slot "$TMP_ROOT/sessionstart")
  out=$(printf '{"source":"startup"}' | FM_HOME="$dir" FM_TASK_ID=some-task bash "$dir/bin/fm-sessionstart-run.sh" 2>&1) || status=$?
  expect_code 0 "$status" "session-start hook must exit 0 for a worker"
  [ -z "$out" ] || fail "session-start hook produced a digest for a worker: $out"
  [ ! -e "$dir/state/.lock" ] || fail "a worker session took the slot's home lock"
  pass "fm-sessionstart-run: silent and lockless for a worker in a stale home slot"
}

test_session_start_nudge_stands_down_for_worker() {
  local dir out status=0
  dir=$(make_stale_home_slot "$TMP_ROOT/nudge")
  out=$(FM_HOME="$dir" FM_TASK_ID=some-task bash "$dir/bin/fm-sessionstart-nudge.sh" 2>&1) || status=$?
  expect_code 0 "$status" "nudge must exit 0 for a worker"
  [ -z "$out" ] || fail "session-start nudge fired for a worker: $out"
  pass "fm-sessionstart-nudge: silent for a worker in a stale home slot"
}

test_turnend_guard_stands_down_for_worker() {
  local dir out status=0
  dir=$(make_stale_home_slot "$TMP_ROOT/turnend")
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1) || status=$?
  expect_code 2 "$status" "control: the marked home with work in flight must still block"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$dir" FM_TASK_ID=some-task bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "turn-end guard must not block a worker"
  [ -z "$out" ] || fail "turn-end guard spoke to a worker: $out"
  pass "fm-turnend-guard: blocks the marked home, silent for a worker in the same slot"
}

test_stop_autoarm_stands_down_for_worker() {
  local dir out status=0
  dir=$(make_stale_home_slot "$TMP_ROOT/autoarm")
  out=$(printf '{"session_id":"s"}' | FM_HOME="$dir" FM_TASK_ID=some-task bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1) || status=$?
  expect_code 0 "$status" "Stop auto-arm must exit 0 for a worker"
  [ -z "$out" ] || fail "Stop auto-arm produced output for a worker: $out"
  [ -z "$(find "$dir/state" -maxdepth 1 -name '.claude-autoarm*' -print -quit)" ] \
    || fail "Stop auto-arm wrote its ledger for a worker"
  [ ! -e "$dir/state/.watch.lock" ] || fail "Stop auto-arm started a watcher for a worker"
  pass "fm-claude-stop-autoarm: inert for a worker in a stale home slot"
}

# The Pi (and OMP, same template) turn-end extension owns session start, the
# turn-end guard, and the pretool seatbelts: it must register none of them.
test_pi_turnend_extension_registers_nothing_for_worker() {
  local repo ext out status
  repo="$TMP_ROOT/pi-turnend"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  out=$(PLUGIN="$ext" FM_HOME="$repo" FM_TASK_ID=some-task node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const calls = [];
const pi = new Proxy({}, { get: (_target, name) => () => { calls.push(String(name)); } });
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (calls.length !== 0) throw new Error(`worker pane registered Pi turn-end surfaces: ${calls.join(",")}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi turn-end extension must register nothing for a worker: $out"
  pass ".pi primary turn-end extension: registers nothing in a worker pane (FM_TASK_ID)"
}

test_home_entrypoints_refuse_a_worker() {
  local dir script out status
  dir=$(make_stale_home_slot "$TMP_ROOT/entrypoints")
  for script in fm-session-start fm-watch-arm fm-watch; do
    status=0
    out=$(FM_HOME="$dir" FM_TASK_ID=some-task bash "$dir/bin/$script.sh" 2>&1) || status=$?
    expect_code 3 "$status" "$script must refuse in a worker pane"
    assert_contains "$out" "worker pane" "$script refusal must name the worker pane"
  done
  [ ! -e "$dir/state/.lock" ] || fail "a refused session start still took the home lock"
  [ ! -e "$dir/state/.watch.lock" ] || fail "a refused watcher still took the watch lock"
  pass "fm-session-start, fm-watch-arm, fm-watch: refuse to run in a worker pane"
}

test_suite_refuses_a_marked_code_root() {
  local root name out status
  for name in marked-home marked-parent unmarked; do
    root="$TMP_ROOT/lib-$name"
    mkdir -p "$root/tests"
    cp "$ROOT/tests/lib.sh" "$ROOT/tests/git-config-helpers.sh" "$root/tests/"
    cp -R "$ROOT/bin" "$root/bin"
    case "$name" in
      marked-home) printf 'retired\n' > "$root/.fm-secondmate-home" ;;
      marked-parent) printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=/nonexistent-live-parent\n' > "$root/.fm-secondmate-parent" ;;
    esac
    status=0
    out=$(bash -c '. "$1/tests/lib.sh"; echo sourced' _ "$root" 2>&1) || status=$?
    if [ "$name" = unmarked ]; then
      expect_code 0 "$status" "an unmarked code root must load the suite library: $out"
      assert_contains "$out" sourced "the unmarked suite library did not finish loading"
    else
      [ "$status" -ne 0 ] || fail "a code root with $name must be refused: $out"
      assert_contains "$out" "refusing to run the suite" "the refusal did not say what it refused ($name)"
      assert_not_contains "$out" sourced "the marked suite library kept loading ($name)"
    fi
  done
  pass "tests/lib.sh refuses a code root that still carries a retired home's marker"
}

test_scope_predicate_rejects_worker_with_stale_marker
test_suite_refuses_a_marked_code_root
test_pi_turnend_extension_registers_nothing_for_worker
test_session_start_run_stands_down_for_worker
test_session_start_nudge_stands_down_for_worker
test_turnend_guard_stands_down_for_worker
test_stop_autoarm_stands_down_for_worker
test_home_entrypoints_refuse_a_worker
