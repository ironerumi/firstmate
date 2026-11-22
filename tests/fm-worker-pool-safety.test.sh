#!/usr/bin/env bash
# Fork pooled-slot residue regressions moved from the upstream spawn suite.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-pool-safety)
trap fm_test_cleanup EXIT

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_pool_slot_with_retired_home_leftovers_is_refused() {
  local rec id out status leftover
  for leftover in marker parent state; do
    id="pool-home-residue-$leftover-r1"
    rec=$(make_case "home-residue-$leftover" "$id")
    read_case_record "$rec"
    case "$leftover" in
      marker) printf 'retired\n' > "$POOL_DIR/.fm-secondmate-home" ;;
      parent) printf 'schema=fm-secondmate-parent.v1\nroute=local\n' > "$POOL_DIR/.fm-secondmate-parent" ;;
      state)
        # A firstmate checkout keeps its runtime records in gitignored dirs.
        mkdir -p "$POOL_DIR/bin" "$POOL_DIR/state"
        : > "$POOL_DIR/AGENTS.md" && : > "$POOL_DIR/bin/fm-spawn.sh"
        printf 'state/\n' > "$POOL_DIR/.gitignore"
        git -C "$POOL_DIR" add -f AGENTS.md bin/fm-spawn.sh .gitignore
        git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm firstmate-shaped
        printf 'x\n' > "$POOL_DIR/state/retired.status"
        ;;
    esac

    out=$(run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "spawn succeeded in a pooled worktree carrying a retired home's $leftover"
    assert_contains "$out" "retired firstmate home's leftovers" "spawn did not name the retired home's leftovers ($leftover)"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused slot still published a task record ($leftover)"
    case "$leftover" in
      marker) assert_grep 'retired' "$POOL_DIR/.fm-secondmate-home" "spawn removed the marker it refused on" ;;
      parent) [ -f "$POOL_DIR/.fm-secondmate-parent" ] || fail "spawn removed the parent record it refused on" ;;
      state) assert_grep 'x' "$POOL_DIR/state/retired.status" "spawn removed the state it refused on" ;;
    esac
  done
  pass "a pooled worktree carrying a retired home's markers or state is refused and left untouched"
}

test_pool_slot_with_empty_home_dirs_launches() {
  local rec id out status name
  for name in state data config projects; do
    id="pool-empty-$name-r1"
    rec=$(make_case "empty-$name" "$id")
    read_case_record "$rec"
    mkdir -p "$POOL_DIR/bin" "$POOL_DIR/$name"
    : > "$POOL_DIR/AGENTS.md" && : > "$POOL_DIR/bin/fm-spawn.sh"
    printf '%s/\n' "$name" > "$POOL_DIR/.gitignore"
    git -C "$POOL_DIR" add -f AGENTS.md bin/fm-spawn.sh .gitignore
    git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm firstmate-shaped
    out=$(run_spawn "$id" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "an empty $name/ dir is not a retired home's leftover"$'\n'"$out"
  done
  pass "an empty state/data/config/projects dir does not block a worker launch"
}

test_pool_slot_with_ordinary_project_data_dirs_launches() {
  local rec id out status
  id='pool-project-data-r1'
  rec=$(make_case project-data "$id")
  read_case_record "$rec"
  mkdir -p "$POOL_DIR/data" "$POOL_DIR/state"
  printf 'state/\ndata/\n' > "$POOL_DIR/.gitignore"
  git -C "$POOL_DIR" add .gitignore
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm ignore-project-dirs
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "another project's own ignored data/ and state/ dirs are not a retired home's leftovers"$'\n'"$out"
  pass "a non-firstmate project's ignored data/state dirs do not block a worker launch"
}

fm_test_run \
  test_pool_slot_with_retired_home_leftovers_is_refused \
  test_pool_slot_with_empty_home_dirs_launches \
  test_pool_slot_with_ordinary_project_data_dirs_launches
