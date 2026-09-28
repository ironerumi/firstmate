#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded local-only landing path.
#
# Matrix:
#   (a) baseline: an approved local-only branch fast-forwards the project's
#       default branch (origin-default resolution)
#   (b) non-local-only tasks are refused
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# Build one case dir with a state dir and a quiet watcher beacon. Echoes it.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config"
  touch "$case_dir/state/.last-watcher-beat"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done'     > "$case_dir/home/data/backlog.md"
  printf '%s\n' "$case_dir"
}

# Init <dir> as a git repo normalized onto `main` with one baseline commit.
# config never reads as a dirty tree.
init_repo_on_main() {
  local dir=$1
  fm_git_init_commit "$dir"
  git -C "$dir" checkout -q -B main
  printf 'config/\n' > "$dir/.gitignore"
  git -C "$dir" add .gitignore
  git -C "$dir" commit -qm "ignore local config"
}

# Add a ready fm/task-x1 branch with one commit on top of <base>, then return
# the checkout to <base>.
add_task_branch() {
  local dir=$1 base=$2
  git -C "$dir" checkout -q -b fm/task-x1 "$base"
  git -C "$dir" commit -q --allow-empty -m "task work"
  git -C "$dir" checkout -q "$base"
}

write_meta() {
  local case_dir=$1 project=$2 mode=${3:-local-only}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$project" \
    "kind=ship" \
    "mode=$mode"
}

# Run fm-merge-local with the case's state; extra leading VAR=val pairs go
# through the env prefix of the caller instead.
run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

test_baseline_ff_into_main() {
  local case_dir proj before
  case_dir=$(make_case baseline)
  proj="$case_dir/project"
  init_repo_on_main "$proj"
  before=$(git -C "$proj" rev-parse main)
  add_task_branch "$proj" main
  write_meta "$case_dir" "$proj"

  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "baseline: fm-merge-local failed: $(cat "$case_dir/stderr")"

  [ "$(git -C "$proj" rev-parse main)" = "$(git -C "$proj" rev-parse fm/task-x1)" ] \
    || fail "baseline: main was not fast-forwarded to the task branch"
  [ "$(git -C "$proj" rev-parse main)" != "$before" ] \
    || fail "baseline: main did not advance"
  assert_grep 'into local main' "$case_dir/stdout" "baseline: merge outcome did not name main"
  pass "fm-merge-local fast-forwards the project default branch (baseline)"
}

test_non_local_only_mode_refused() {
  local case_dir proj rc
  case_dir=$(make_case wrong-mode)
  proj="$case_dir/project"
  init_repo_on_main "$proj"
  add_task_branch "$proj" main
  write_meta "$case_dir" "$proj" no-mistakes

  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-mode: fm-merge-local should refuse non-local-only tasks"
  assert_grep 'not local-only' "$case_dir/stderr" "wrong-mode: refusal did not name the mode guard"
  pass "fm-merge-local refuses tasks that are not mode=local-only"
}

test_baseline_ff_into_main
test_non_local_only_mode_refused
