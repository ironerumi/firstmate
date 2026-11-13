#!/usr/bin/env bash
# Fork runner guard inheritance, hint output, and local-only refusal contracts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"
assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"
TMP_ROOT=$(fm_test_tmproot fm-fork-runner-local)
fm_git_identity fmtest fmtest@example.invalid

# Only the single approved-head fixture is needed, not the upstream race shims.
make_case() {
  local name=$1
  CASE="$TMP_ROOT/$name"
  PROJ="$CASE/project"
  WT="$CASE/worker"
  HOME_DIR="$CASE/home"
  META="$HOME_DIR/state/local-task.meta"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
  printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/bin/fm-guard.sh"
  chmod +x "$HOME_DIR/bin/fm-guard.sh"
  fm_git_worktree "$PROJ" "$WT" fm/local-task
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'approved X\n' > "$WT/approved.txt"
  git -C "$WT" add approved.txt
  git -C "$WT" commit -q -m X
  X=$(git -C "$WT" rev-parse HEAD)
  printf 'kind=ship\nmode=local-only\nbranch=fm/local-task\nproject=%s\nworktree=%s\nspawn_gen=fixture-1\n' \
    "$PROJ" "$WT" > "$META"
}

record_done() {
  FM_HOME="$HOME_DIR" fm_dod_accept_ship_done ship local-only "$WT" "$PROJ" \
    'done [at=1790000000]: ready in branch fm/local-task' \
    "$HOME_DIR/state" local-task "$META"
}

land() {
  FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash "$ROOT/bin/fm-merge-local.sh" local-task
}


test_fork_weight_hints_stay_quiet_when_the_reader_stops_early() {
  local tmp err
  tmp=$(fm_test_tmproot fm-test-run-fork-hints)
  err="$tmp/hints.err"
  ( trap '' PIPE
    # shellcheck source=bin/fm-test-run-fork.sh
    . "$ROOT/bin/fm-test-run-fork.sh"
    fm_fork_serial_weight_hints
  ) 2>"$err" | { exec <&-; sleep 0.3; }
  [ ! -s "$err" ] || fail "the fork's weight hints wrote to stderr when their reader stopped early: $(cat "$err")"
  pass "fm_fork_serial_weight_hints stays silent when its reader stops early"
}

test_changed_workflow_helper_selects_both_consumers() {
  local tmp repo listed expected
  tmp=$(fm_test_tmproot fm-fork-workflow-discovery)
  repo="$tmp/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$ROOT/bin/fm-test-run-fork.sh" "$repo/bin/"
  cp "$ROOT/tests/lib.sh" "$ROOT/tests/fork-ci-context-helpers.sh" \
    "$ROOT/tests/fm-ci-workflow.test.sh" "$ROOT/tests/fm-fork-ci-workflow.test.sh" "$repo/tests/"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" commit -qm 'workflow discovery fixture'
  printf '\n# changed helper\n' >>"$repo/tests/fork-ci-context-helpers.sh"
  listed=$(cd "$repo" && bash bin/fm-test-run.sh --list --changed --base HEAD) \
    || fail 'changed workflow helper must have a runnable selection'
  expected=$(printf '%s\n' tests/fm-ci-workflow.test.sh tests/fm-fork-ci-workflow.test.sh)
  [ "$listed" = "$expected" ] \
    || fail "changed workflow helper must select both workflow consumers, got: $listed"
  pass 'changed workflow helper selects the upstream and fork workflow suites'
}

test_preserves_guard_shims_on_path() {
  local tmp fixture out fake_shims
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shims.XXXXXX")
  fake_shims="$tmp/fake-home/bin/shims"
  mkdir -p "$fake_shims"
  ln -s "$ROOT/bin/fm-nm-guard-shim.sh" "$fake_shims/git"
  fixture="$tmp/probe.test.sh"
  out="$tmp/out.txt"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
resolved=$(command -v git)
[ "$resolved" = "$EXPECTED_GIT" ] || {
  echo "runner resolved git outside the inherited guard shims: $resolved" >&2
  exit 1
}
echo "ok - probe"
SH
  chmod +x "$fixture"
  EXPECTED_GIT="$fake_shims/git" PATH="$fake_shims:$PATH" "$RUNNER" "$fixture" >"$out" 2>&1 \
    || { rm -rf "$tmp"; fail "runner should preserve guard shims for test children: $(cat "$out")"; }
  grep -q '^ok - probe$' "$out" || { rm -rf "$tmp"; fail "probe fixture did not run: $(cat "$out")"; }
  rm -rf "$tmp"
  pass "runner preserves inherited guard shims for test children"
}

test_non_local_only_mode_refuses() {
  local out rc=0
  make_case wrong-mode
  record_done || fail 'wrong-mode fixture done was not accepted'
  sed -i.bak 's/^mode=local-only$/mode=no-mistakes/' "$META" && rm -f "$META.bak"
  out=$(land 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-local-only task landed: $out"
  case "$out" in *'not local-only'*) ;; *) fail "the refusal did not name the mode guard: $out" ;; esac
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ] || fail 'the refusal moved main'
  pass 'a task that is not mode=local-only is refused'
}


test_fork_weight_hints_stay_quiet_when_the_reader_stops_early
test_preserves_guard_shims_on_path
test_changed_workflow_helper_selects_both_consumers
test_non_local_only_mode_refuses
