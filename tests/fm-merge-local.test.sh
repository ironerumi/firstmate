#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded local-only landing path.
#
# Matrix:
#   (a) baseline: an approved local-only branch fast-forwards the project's
#       default branch (origin-default resolution)
#   (b) home-checkout landing: when the project IS this home's primary
#       branch and the default branch stays untouched
#       branch of that name exists in the project (no weakening)
#       when the home checkout sits on another branch
#   (e) non-local-only tasks are refused
#   (f) the test runner keeps this file in the pr-forge family, so --changed
#       selection on bin/fm-merge-local.sh still runs it
#   (g) a change to bin/fm-tangle* (home of the landing-branch helper) also
#       selects this file through the runner's changed-file map
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
  mkdir -p "$case_dir/state"
  touch "$case_dir/state/.last-watcher-beat"
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

# This file is the only test covering the local-only landing path, so it must
# stay inside the runner's pr-forge family: bin/fm-merge-local.sh changes select
# that family via families_for_changed_path, and an unclassified test would be
# skipped by --changed selection. Upstream owns the family map, so a future
# upstream merge could drop this entry silently; assert it here instead.
test_runner_classifies_this_test_into_pr_forge() {
  local listing
  listing=$("$ROOT/bin/fm-test-run.sh" --list --family pr-forge) \
    || fail "family-map: fm-test-run.sh --list --family pr-forge failed"
  printf '%s\n' "$listing" | grep -Fqx 'tests/fm-merge-local.test.sh' \
    || fail "family-map: fm-merge-local.test.sh is not in the pr-forge family; --changed selection would skip it"
  pass "the test runner classifies fm-merge-local.test.sh into the pr-forge family"
}

# bin/fm-tangle-lib.sh, and the only tests exercising it are pr-forge ones (this
# file and fm-teardown). The runner's changed-path map otherwise routes
# bin/fm-tangle* to session-bootstrap alone, so editing the helper would select
# no test that covers it; assert the map keeps selecting this file.
test_tangle_source_change_selects_this_test() {
  local case_dir repo listed
  case_dir=$(make_case tangle-changed-map)
  repo="$case_dir/repo"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  printf '#!/usr/bin/env bash\n' > "$repo/tests/fm-merge-local.test.sh"
  printf '#!/usr/bin/env bash\n' > "$repo/tests/fm-teardown.test.sh"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline

  : > "$repo/bin/fm-tangle-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) \
    || fail "tangle-map: --changed selection failed for a bin/fm-tangle-lib.sh change"
  printf '%s\n' "$listed" | grep -Fqx 'tests/fm-merge-local.test.sh' \
    || fail "tangle-map: a bin/fm-tangle* change does not select fm-merge-local.test.sh; the landing helper would change untested"
  pass "changed-file selection covers the landing path when bin/fm-tangle* changes"
}

test_baseline_ff_into_main
test_non_local_only_mode_refused
test_runner_classifies_this_test_into_pr_forge
test_tangle_source_change_selects_this_test
