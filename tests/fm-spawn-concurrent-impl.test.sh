#!/usr/bin/env bash
# Behavior tests for the one-implementation-task-per-repository cap in
# bin/fm-spawn.sh.
#
# The cap exists because this fleet's GitHub plan has no merge queue, so a
# second open PR on one repository lands behind the first merge and re-runs CI
# for nothing. These tests drive the real spawn path against a fake terminal and
# a no-op treehouse, and assert the guard's decision through its own interface:
# a refused spawn exits non-zero naming the task in flight and publishes no
# record, an allowed spawn launches and reports success.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-concurrent-impl)

# make_world <name>: one isolated firstmate home plus the fake spawn toolchain.
# Echoes "<case-dir>|<home>|<fakebin>".
make_world() {
  local name=$1 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$fakebin"
}

# make_repo <name> <repo-name>: a real project repository with a local bare
# origin and one clean worktree standing in for the Treehouse slot a spawn
# allocates. Echoes "<project>|<worktree>".
make_repo() {
  local name=$1 repo_name=$2 repo
  repo="$TMP_ROOT/$name/$repo_name"
  fm_git_worktree "$repo" "$repo.slot" "slot-$repo_name"
  printf '%s|%s\n' "$repo" "$repo.slot"
}

# add_slot <repo> <slot-name>: a second clean worktree of the SAME repository,
# so a case can attempt two spawns against one project without reusing a path.
add_slot() {
  local repo=$1 name=$2
  git -C "$repo" worktree add --quiet -b "$name" "$repo.$name" || return 1
  printf '%s\n' "$repo.$name"
}

write_brief() {  # <home> <id>
  fm_test_spawn_brief "$1" "$2" "Exercise the per-repository implementation cap."
}

run_spawn() {  # <home> <slot> <fakebin> [args...]
  local home=$1 slot=$2 fakebin=$3
  shift 3
  fm_test_run_spawn "$home" "$slot" "$fakebin" "$@"
}

test_second_ship_on_one_repo_is_refused() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world second-ship)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo second-ship project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-first-z1
  write_brief "$home" impl-second-z2

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-first-z1 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first ship spawn for a repository should succeed"$'\n'"$out"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" impl-second-z2 "$project" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a second ship spawn for the same repository should be refused"$'\n'"$out"
  assert_contains "$out" "an implementation task is already in flight for project: impl-first-z1" \
    "the refusal did not name the task already in flight and the repository"
  if [ -e "$home/state/impl-second-z2.meta" ]; then
    fail "the refused spawn published a task record for impl-second-z2"
  fi
  pass "a second ship spawn for a repository already in flight is refused and publishes nothing"
}

test_direct_pr_second_ship_is_refused_too() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world direct-pr-second)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo direct-pr-second project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-dp-first-z3
  write_brief "$home" impl-dp-second-z4

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-dp-first-z3 "$project" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the first direct-PR ship spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" impl-dp-second-z4 "$project" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a PR-mode ship behind an open direct-PR task should be refused"$'\n'"$out"
  assert_contains "$out" "an implementation task is already in flight for project: impl-dp-first-z3" \
    "the refusal did not name the open direct-PR task"
  pass "an open direct-PR task blocks another PR-mode ship for the same repository"
}

test_other_repository_is_independent() {
  local repo_a repo_b world home fakebin project_a slot_a project_b slot_b out status
  world=$(make_world other-repo)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_a=$(make_repo other-repo project-a)
  IFS='|' read -r project_a slot_a <<EOF
$repo_a
EOF
  repo_b=$(make_repo other-repo project-b)
  IFS='|' read -r project_b slot_b <<EOF
$repo_b
EOF
  write_brief "$home" impl-repo-a-z5
  write_brief "$home" impl-repo-b-z6

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-repo-a-z5 "$project_a" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first repository's ship spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" impl-repo-b-z6 "$project_b" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a different repository must not be blocked by the first"$'\n'"$out"
  assert_contains "$out" "spawned impl-repo-b-z6" "the second repository's spawn did not report success"
  pass "a ship spawn for a different repository is allowed"
}

test_scout_on_a_busy_repository_is_allowed() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world scout-parallel)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo scout-parallel project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-busy-z7
  write_brief "$home" scout-parallel-z8

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-busy-z7 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the ship spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" scout-parallel-z8 "$project" --scout)
  status=$?
  expect_code 0 "$status" "a read-only scout on the same repository must run in parallel"$'\n'"$out"
  assert_contains "$out" "spawned scout-parallel-z8" "the scout spawn did not report success"
  pass "a scout on a repository with a ship in flight is allowed"
}

test_escape_hatch_allows_authorized_concurrency() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world escape-hatch)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo escape-hatch project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-hatch-a-z9
  write_brief "$home" impl-hatch-b-z10

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-hatch-a-z9 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first ship spawn should succeed"$'\n'"$out"

  out=$(FM_ALLOW_CONCURRENT_IMPL=1 \
    run_spawn "$home" "$slot_b" "$fakebin" impl-hatch-b-z10 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "FM_ALLOW_CONCURRENT_IMPL=1 must bypass the cap"$'\n'"$out"
  assert_contains "$out" "spawned impl-hatch-b-z10" "the authorized concurrent spawn did not report success"
  pass "FM_ALLOW_CONCURRENT_IMPL=1 bypasses the per-repository cap"
}

test_local_only_ship_opens_no_pr_and_is_not_refused() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world local-only)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo local-only project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-lo-a-z11
  write_brief "$home" impl-lo-b-z12

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-lo-a-z11 "$project" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "the direct-PR ship spawn should succeed"$'\n'"$out"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" impl-lo-b-z12 "$project" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "a local-only spawn opens no PR and must not be refused"$'\n'"$out"
  assert_contains "$out" "spawned impl-lo-b-z12" "the local-only spawn did not report success"
  pass "a local-only ship is not screened by the per-repository cap"
}

test_torn_down_ship_releases_the_repository() {
  local repo_rec world home fakebin project slot_a slot_b out status
  world=$(make_world released)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo released project)
  IFS='|' read -r project slot_a <<EOF
$repo_rec
EOF
  slot_b=$(add_slot "$project" slot-b) || fail "could not add the second worktree"
  write_brief "$home" impl-done-z13
  write_brief "$home" impl-next-z14

  out=$(run_spawn "$home" "$slot_a" "$fakebin" impl-done-z13 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first ship spawn should succeed"$'\n'"$out"

  # Teardown removes the record; that is the release the cap documents.
  rm -f "$home/state/impl-done-z13.meta"

  out=$(run_spawn "$home" "$slot_b" "$fakebin" impl-next-z14 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the repository should be free once the in-flight task is torn down"$'\n'"$out"
  assert_contains "$out" "spawned impl-next-z14" "the next ship spawn did not report success"
  pass "a torn-down ship task no longer blocks the repository"
}

test_secondmate_and_scout_records_never_block() {
  local repo_rec world home fakebin project slot out status
  world=$(make_world non-impl-records)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo non-impl-records project)
  IFS='|' read -r project slot <<EOF
$repo_rec
EOF
  # A secondmate record and a scout record both name the same project; neither
  # is an implementation task, so neither may refuse a ship spawn.
  fm_write_meta "$home/state/sm-other-y1.meta" \
    "window=firstmate:fm-sm-other-y1" \
    "endpoint_task_id=sm-other-y1" \
    "worktree=$home" \
    "project=$project" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home"
  fm_write_meta "$home/state/scout-other-y2.meta" \
    "window=firstmate:fm-scout-other-y2" \
    "endpoint_task_id=scout-other-y2" \
    "worktree=$project.slot" \
    "project=$project" \
    "harness=codex" \
    "kind=scout"
  write_brief "$home" impl-after-non-impl-z15

  out=$(run_spawn "$home" "$slot" "$fakebin" impl-after-non-impl-z15 "$project" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "secondmate and scout records must not block a ship spawn"$'\n'"$out"
  assert_contains "$out" "spawned impl-after-non-impl-z15" "the ship spawn did not report success"
  pass "a secondmate record and a scout record on the same project never block"
}

# A record written before kind= existed carries no kind; fm-spawn.sh reads such a
# record as ship everywhere else, so the guard must agree rather than letting a
# legacy implementation task through.
test_record_without_kind_is_treated_as_ship() {
  local repo_rec world home fakebin project slot out status
  world=$(make_world legacy-record)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo legacy-record project)
  IFS='|' read -r project slot <<EOF
$repo_rec
EOF
  fm_write_meta "$home/state/legacy-inflight-z16.meta" \
    "window=firstmate:fm-legacy-inflight-z16" \
    "endpoint_task_id=legacy-inflight-z16" \
    "worktree=$project.slot" \
    "project=$project"
  write_brief "$home" impl-after-legacy-z17

  out=$(run_spawn "$home" "$slot" "$fakebin" impl-after-legacy-z17 "$project" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a kind-less ship record must still block"$'\n'"$out"
  assert_contains "$out" "an implementation task is already in flight for project: legacy-inflight-z16" \
    "the kind-less record was not read as an implementation task in flight"
  pass "a task record with no kind= is read as ship and blocks"
}

# The script's own interface, exercised directly: it never counts the task it is
# checking as its own blocker (the relaunch shape), it screens only a PR-opening
# mode, and it reports a usage error rather than guessing.
test_guard_interface_is_a_standalone_command() {
  local repo_rec world home fakebin project slot guard out status
  world=$(make_world guard-interface)
  IFS='|' read -r _ home fakebin <<EOF
$world
EOF
  repo_rec=$(make_repo guard-interface project)
  IFS='|' read -r project slot <<EOF
$repo_rec
EOF
  guard="$ROOT/bin/fm-impl-concurrency-guard.sh"
  fm_write_meta "$home/state/guard-self-z18.meta" \
    "window=firstmate:fm-guard-self-z18" \
    "endpoint_task_id=guard-self-z18" \
    "worktree=$slot" \
    "project=$project" \
    "kind=ship"

  out=$(env -u FM_ALLOW_CONCURRENT_IMPL "$guard" "$home/state" "$project" guard-self-z18 no-mistakes 2>&1)
  status=$?
  expect_code 0 "$status" "the guard must not count the checked task as its own blocker"$'\n'"$out"

  out=$(env -u FM_ALLOW_CONCURRENT_IMPL "$guard" "$home/state" "$project" guard-other-z19 no-mistakes 2>&1)
  status=$?
  expect_code 1 "$status" "a different PR-mode task must be refused"$'\n'"$out"

  out=$(env -u FM_ALLOW_CONCURRENT_IMPL "$guard" "$home/state" "$project" guard-other-z19 local-only 2>&1)
  status=$?
  expect_code 0 "$status" "a mode that opens no PR must pass the guard"$'\n'"$out"

  out=$(env -u FM_ALLOW_CONCURRENT_IMPL "$guard" "$home/state" "$project" guard-other-z19 2>&1)
  status=$?
  expect_code 2 "$status" "a missing argument must be a usage error"$'\n'"$out"
  assert_contains "$out" "usage: fm-impl-concurrency-guard.sh" "the usage error did not print the usage line"
  pass "the guard is a standalone command with its own documented exit codes"
}

test_second_ship_on_one_repo_is_refused
test_direct_pr_second_ship_is_refused_too
test_other_repository_is_independent
test_scout_on_a_busy_repository_is_allowed
test_escape_hatch_allows_authorized_concurrency
test_local_only_ship_opens_no_pr_and_is_not_refused
test_torn_down_ship_releases_the_repository
test_secondmate_and_scout_records_never_block
test_record_without_kind_is_treated_as_ship
test_guard_interface_is_a_standalone_command
