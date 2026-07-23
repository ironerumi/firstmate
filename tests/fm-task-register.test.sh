#!/usr/bin/env bash
# Tests for bin/fm-task-register.sh's create-only ad-hoc task identity.
# Covers private metadata creation, collision/ID refusal, guarded PR merge
# compatibility, and non-destructive ad-hoc cleanup through fm-teardown.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTER="$ROOT/bin/fm-task-register.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-register-tests)

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/data" "$case_dir/home/config" "$case_dir/state" "$case_dir/fakebin"
  printf '%s\n' '- firstmate [no-mistakes +yolo] - test Firstmate home' > "$case_dir/home/data/projects.md"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

run_register() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
    "$REGISTER" "$@"
}

test_registers_private_adhoc_meta() {
  local case_dir meta
  case_dir=$(make_case registers)
  meta="$case_dir/state/adhoc-one.meta"

  run_register "$case_dir" adhoc-one > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "registers: registration failed"

  grep -qxF 'registered: state/adhoc-one.meta' "$case_dir/stdout" \
    || fail "registers: success output did not identify the metadata"
  [ "$(file_mode "$meta")" = 600 ] || fail "registers: metadata mode was not 0600"
  grep -qxF 'window=' "$meta" || fail "registers: ad-hoc metadata acquired a worker endpoint"
  grep -qxF 'worktree=' "$meta" || fail "registers: ad-hoc metadata acquired a worktree"
  grep -qxF "project=$ROOT" "$meta" || fail "registers: project did not resolve to the Firstmate code root"
  grep -qxF 'harness=adhoc' "$meta" || fail "registers: harness marker missing"
  grep -qxF 'kind=adhoc' "$meta" || fail "registers: kind marker missing"
  grep -qxF 'mode=no-mistakes' "$meta" || fail "registers: project delivery mode missing"
  grep -qxF 'yolo=on' "$meta" || fail "registers: project autonomy posture missing"
  grep -qxF "home=$(cd "$case_dir/home" && pwd -P)" "$meta" || fail "registers: home field missing"
  pass "fm-task-register creates private ad-hoc metadata with the fields its consumers read"
}

test_refuses_existing_meta_without_mutation() {
  local case_dir meta before after rc
  case_dir=$(make_case existing)
  meta="$case_dir/state/adhoc-one.meta"
  printf '%s\n' 'sentinel=preserve' > "$meta"
  before=$(shasum -a 256 "$meta" | awk '{print $1}')

  set +e
  run_register "$case_dir" adhoc-one > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  after=$(shasum -a 256 "$meta" | awk '{print $1}')

  expect_code 1 "$rc" "existing: registration should refuse an existing identity"
  [ "$before" = "$after" ] || fail "existing: registration changed existing metadata"
  assert_grep 'task metadata already exists' "$case_dir/stderr" \
    "existing: refusal did not explain the collision"
  pass "fm-task-register never overwrites an existing task identity"
}

test_refuses_invalid_id() {
  local case_dir rc
  case_dir=$(make_case invalid)

  set +e
  run_register "$case_dir" '../escape' > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "invalid: registration should reject path-like IDs"
  assert_grep 'invalid task id' "$case_dir/stderr" "invalid: refusal did not explain the ID error"
  assert_absent "$case_dir/escape.meta" "invalid: registration escaped the state directory"
  pass "fm-task-register rejects unsafe task IDs before writing state"
}

add_merge_mocks() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

test_registered_identity_merges_and_cleans_up() {
  local case_dir meta
  case_dir=$(make_case merge-and-cleanup)
  meta="$case_dir/state/adhoc-merge.meta"
  add_merge_mocks "$case_dir"
  : > "$case_dir/gh-axi.log"

  run_register "$case_dir" adhoc-merge >/dev/null \
    || fail "merge-and-cleanup: registration failed"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" adhoc-merge https://github.com/example/repo/pull/41 \
    > "$case_dir/merge.stdout" 2> "$case_dir/merge.stderr" \
    || fail "merge-and-cleanup: guarded merge rejected registered metadata"

  grep -qxF 'pr=https://github.com/example/repo/pull/41' "$meta" \
    || fail "merge-and-cleanup: fm-pr-check did not record the PR"
  grep -qxF 'pr merge 41 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "merge-and-cleanup: fm-pr-merge did not invoke the guarded merge CLI"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" adhoc-merge > "$case_dir/teardown.stdout" 2> "$case_dir/teardown.stderr" \
    || fail "merge-and-cleanup: ad-hoc cleanup failed"

  assert_absent "$meta" "merge-and-cleanup: cleanup retained ad-hoc metadata"
  assert_grep 'teardown adhoc-merge complete' "$case_dir/teardown.stdout" \
    "merge-and-cleanup: cleanup did not complete"
  assert_no_grep 'Backlog:' "$case_dir/teardown.stdout" \
    "merge-and-cleanup: ad-hoc cleanup emitted a worker backlog reminder"
  pass "a registered ad-hoc identity supports guarded merge recording and non-destructive cleanup"
}

test_registers_private_adhoc_meta
test_refuses_existing_meta_without_mutation
test_refuses_invalid_id
test_registered_identity_merges_and_cleans_up
