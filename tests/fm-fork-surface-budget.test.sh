#!/usr/bin/env bash
# Execute fm-lint's fork-budget interface against real divergent Git histories.
# Oracle: replacing one of two upstream lines is one file and two changed lines;
# additive fork files and later upstream commits do not consume that budget.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

fixture() {
  repo=$(fm_test_tmproot fork-surface)
  git -C "$repo" init -q
  printf 'old\nkept\n' > "$repo/owned file"
  printf 'other\n' > "$repo/other"
  git -C "$repo" add -- 'owned file' other
  git -C "$repo" commit -qm upstream
  local base
  base=$(git -C "$repo" rev-parse HEAD)
  printf 'upstream only\n' > "$repo/later"
  git -C "$repo" add -- later
  git -C "$repo" commit -qm 'later upstream'
  git -C "$repo" update-ref refs/remotes/reference/main HEAD
  git -C "$repo" checkout -qb fork "$base"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-lint.sh" "$repo/bin/"
  printf 'new\nkept\n' > "$repo/owned file"
  printf 'fork only\n' > "$repo/additive"
  git -C "$repo" add -- additive
  git -C "$repo" commit -qm 'fork addition'
}

check() { bash "$repo/bin/fm-lint.sh" --check-fork-surface; }

at_budget() {
  fixture
  printf '1 2\n' > "$repo/.fork-surface-budget"
  check || fail 'exact budget must pass, counting tracked uncommitted changes'
  pass 'exact budget passes; additive and upstream-only paths excluded'
}

line_growth() {
  fixture
  printf '1 1\n' > "$repo/.fork-surface-budget"
  local out rc=0
  out=$(check 2>&1) || rc=$?
  assert_equals 1 "$rc" 'line growth must fail'
  assert_contains "$out" 'fork surface measured: 1 upstream files, 2 changed lines' 'measurement'
  assert_contains "$out" 'fork surface budget: 1 upstream files, 1 changed lines' 'budget'
  assert_equals 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 'two diagnostic lines'
  pass 'over-budget lines fail with actual and permitted values'
}

file_growth() {
  fixture
  printf '1 20\n' > "$repo/.fork-surface-budget"
  printf 'changed\n' > "$repo/other"
  if check > "$repo/output" 2>&1; then fail 'file growth must fail independently of lines'; fi
  assert_grep 'fork surface measured: 2 upstream files, 4 changed lines' "$repo/output" 'file count'
  pass 'over-budget files fail independently of line budget'
}

rename_and_binary() {
  fixture
  mv "$repo/other" "$repo/renamed"
  git -C "$repo" add -- other renamed
  printf '2 3\n' > "$repo/.fork-surface-budget"
  check || fail 'renamed upstream path must count as one deletion'
  printf '\000binary\n' > "$repo/owned file"
  printf '2 1\n' > "$repo/.fork-surface-budget"
  check || fail 'binary still counts as a file with zero textual lines'
  printf '1 100\n' > "$repo/.fork-surface-budget"
  if check > "$repo/output" 2>&1; then fail 'binary must not disappear from file count'; fi
  pass 'renames retain upstream deletion cost and binaries retain file cost'
}

missing_reference() {
  fixture
  printf '1 2\n' > "$repo/.fork-surface-budget"
  git -C "$repo" update-ref -d refs/remotes/reference/main
  if check > "$repo/output" 2>&1; then fail 'missing upstream base must fail'; fi
  assert_grep 'fetch reference/main' "$repo/output" 'actionable missing-base failure'
  pass 'missing reference refuses measurement'
}

invalid_budget() {
  fixture
  printf 'one 2\n' > "$repo/.fork-surface-budget"
  if check > "$repo/output" 2>&1; then fail 'malformed budget must fail'; fi
  assert_grep 'repair .fork-surface-budget' "$repo/output" 'actionable invalid-budget failure'
  pass 'malformed budget refuses comparison'
}

fm_test_run at_budget line_growth file_growth rename_and_binary missing_reference invalid_budget
