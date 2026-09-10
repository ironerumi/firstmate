#!/usr/bin/env bash
# Tests for bin/fm-brief-repo-guard.sh, the fork-added wrapper that appends a
# control-plane boundary section to briefs targeting Firstmate's own repo.
#
# Matrix:
#   (a) a non-firstmate target produces byte-identical brief content to a raw
#       bin/fm-brief.sh run with the same arguments
#   (b) a firstmate target gains the boundary section exactly once, and the raw
#       scaffold alone never contains it
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-brief-repo-guard.sh"
RAW="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-repo-guard-tests)

# Build one case dir with a data root, a state root, and a fake code root whose
# basename is <root_name>. That basename is the wrapper's primary detection
# signal, so the same fixture drives both the positive and negative cases.
# Echoes the case dir.
make_case() {
  local name=$1 root_name=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/data" "$case_dir/home/state" "$case_dir/fmroot/$root_name"
  printf '%s\n' "$case_dir"
}

# run_brief <case_dir> <script> <task-id> <repo> <extra args...>: scaffold one
# brief with FM_DATA_OVERRIDE/FM_STATE_OVERRIDE pointed at the case so both the
# raw and the wrapped run write their artifact under identical absolute paths.
run_brief() {
  local case_dir=$1 script=$2 root_name=$3
  shift 3
  FM_ROOT_OVERRIDE="$case_dir/fmroot/$root_name" FM_HOME="$case_dir/fmroot/$root_name" \
    FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$script" "$@"
}

test_non_firstmate_target_is_byte_identical() {
  local case_dir raw_brief wrapped_brief rc
  case_dir=$(make_case foreign-target notfirstmate)

  run_brief "$case_dir" "$RAW" notfirstmate taska1 some-project --mode no-mistakes \
    > "$case_dir/raw.stdout" 2>&1 || fail "foreign-target: the raw scaffold failed"
  raw_brief="$case_dir/raw-brief.md"
  cp "$case_dir/home/data/taska1/brief.md" "$raw_brief"
  rm -rf "$case_dir/home/data/taska1"

  set +e
  run_brief "$case_dir" "$GUARD" notfirstmate taska1 some-project --mode no-mistakes \
    > "$case_dir/wrapped.stdout" 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "foreign-target: the wrapper must pass a normal scaffold through"
  wrapped_brief="$case_dir/home/data/taska1/brief.md"

  cmp -s "$raw_brief" "$wrapped_brief" \
    || fail "foreign-target: the wrapper changed a non-firstmate brief"
  assert_no_grep '## Control-plane boundary' "$wrapped_brief" \
    "foreign-target: the boundary section was appended to a non-firstmate brief"
  pass "a non-firstmate target scaffolds byte-identically through the wrapper"
}

test_firstmate_target_appends_the_boundary_once() {
  local case_dir brief count
  case_dir=$(make_case firstmate-target firstmate)

  run_brief "$case_dir" "$GUARD" firstmate taskb1 firstmate --mode no-mistakes \
    > "$case_dir/stdout" 2>&1 || fail "firstmate-target: the guarded scaffold failed"

  brief="$case_dir/home/data/taskb1/brief.md"
  count=$(grep -c '^## Control-plane boundary$' "$brief")
  [ "$count" = 1 ] || fail "firstmate-target: expected exactly one boundary section, got $count"
  assert_grep 'Do not run any Firstmate control or lifecycle script' "$brief" \
    "firstmate-target: the boundary did not forbid running the control scripts"
  assert_grep 'If you find a decision that belongs to the captain, append' "$brief" \
    "firstmate-target: the boundary did not route captain decisions to needs-decision"
  pass "a firstmate target gains the control-plane boundary section exactly once"
}

test_raw_scaffold_alone_has_no_boundary() {
  local case_dir
  case_dir=$(make_case raw-control firstmate)

  run_brief "$case_dir" "$RAW" firstmate taskc1 firstmate --mode no-mistakes \
    > "$case_dir/stdout" 2>&1 || fail "raw-control: the raw scaffold failed"

  assert_no_grep '## Control-plane boundary' "$case_dir/home/data/taskc1/brief.md" \
    "raw-control: the boundary section leaked into the unpatched upstream scaffold"
  pass "the untouched bin/fm-brief.sh adds no boundary section of its own"
}

test_non_firstmate_target_is_byte_identical
test_firstmate_target_appends_the_boundary_once
test_raw_scaffold_alone_has_no_boundary
