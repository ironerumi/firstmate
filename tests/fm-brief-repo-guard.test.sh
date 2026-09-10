#!/usr/bin/env bash
# Tests for bin/fm-brief-repo-guard.sh, the fork-added wrapper that appends a
# control-plane boundary section to briefs targeting Firstmate's own repo.
#
# Matrix:
#   (a) a Firstmate-repo secondmate charter is byte-identical to a raw scaffold
#   (b) Firstmate-repo ship and scout briefs gain the boundary exactly once
#   (c) a non-firstmate target produces byte-identical brief content to a raw
#       bin/fm-brief.sh run with the same arguments
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

test_firstmate_workers_append_the_boundary_once() {
  local kind case_dir brief count
  for kind in ship scout; do
    case_dir=$(make_case "firstmate-$kind-target" firstmate)
    if [ "$kind" = ship ]; then
      run_brief "$case_dir" "$GUARD" firstmate "task-$kind" firstmate --mode no-mistakes \
        > "$case_dir/stdout" 2>&1 || fail "firstmate-$kind: the guarded scaffold failed"
    else
      run_brief "$case_dir" "$GUARD" firstmate "task-$kind" firstmate --scout \
        > "$case_dir/stdout" 2>&1 || fail "firstmate-$kind: the guarded scaffold failed"
    fi

    brief="$case_dir/home/data/task-$kind/brief.md"
    count=$(grep -c '^## Control-plane boundary$' "$brief")
    [ "$count" = 1 ] || fail "firstmate-$kind: expected exactly one boundary section, got $count"
    assert_grep 'Do not run any Firstmate control or lifecycle script' "$brief" \
      "firstmate-$kind: the boundary did not forbid running the control scripts"
    assert_grep 'If you find a decision that belongs to the captain, append' "$brief" \
      "firstmate-$kind: the boundary did not route captain decisions to needs-decision"
  done
  pass "Firstmate ship and scout targets gain the control-plane boundary exactly once"
}

test_firstmate_secondmate_charter_is_transparent() {
  local case_dir raw_brief wrapped_brief
  case_dir=$(make_case firstmate-secondmate firstmate)

  run_brief "$case_dir" "$RAW" firstmate mate --secondmate firstmate \
    > "$case_dir/raw.stdout" 2>&1 || fail "firstmate-secondmate: the raw scaffold failed"
  raw_brief="$case_dir/raw-brief.md"
  cp "$case_dir/home/data/mate/brief.md" "$raw_brief"
  rm -rf "$case_dir/home/data/mate"

  run_brief "$case_dir" "$GUARD" firstmate mate --secondmate firstmate \
    > "$case_dir/wrapped.stdout" 2>&1 || fail "firstmate-secondmate: the wrapped scaffold failed"
  wrapped_brief="$case_dir/home/data/mate/brief.md"

  cmp -s "$raw_brief" "$wrapped_brief" \
    || fail "firstmate-secondmate: the wrapper changed a secondmate charter"
  assert_no_grep '## Control-plane boundary' "$wrapped_brief" \
    "firstmate-secondmate: the boundary section was appended to a secondmate charter"
  pass "a Firstmate-repo secondmate charter scaffolds byte-identically through the wrapper"
}

test_firstmate_secondmate_charter_is_transparent
test_firstmate_workers_append_the_boundary_once
test_non_firstmate_target_is_byte_identical
