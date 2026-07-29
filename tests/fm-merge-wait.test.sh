#!/usr/bin/env bash
# tests/fm-merge-wait.test.sh - a ready PR that needs the captain must leave a
# durable record of that wait.
#
# Covers bin/fm-merge-wait-lib.sh's predicate and both surfaces that enforce it:
# the pull-based reminder in bin/fm-guard.sh and the turn-end block in
# bin/fm-turnend-guard.sh. Nothing here polls a forge or measures elapsed time -
# the readiness signal is the worker's own durable status line, and the record is
# the captain-kind hold the backlog already supports.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP=$(fm_test_tmproot fm-merge-wait)

# shellcheck disable=SC1091
. "$ROOT/bin/fm-merge-wait-lib.sh"

make_home() {  # <name>
  local home="$TMP/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

add_task() {  # <home> <id>
  (cd "$1" && tasks-axi add "$2" "sample ship" --repo sample --start) >/dev/null
}

ready_task() {  # <home> <id> [yolo]
  local home=$1 id=$2 yolo=${3:-off}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/wt" \
    "project=$home/projects/sample" \
    "harness=echo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=$yolo" \
    "pr=https://github.com/o/r/pull/7"
  printf 'working: implementing\ndone: PR https://github.com/o/r/pull/7 checks green\n' \
    > "$home/state/$id.status"
}

unrecorded() {  # <home>
  fm_merge_wait_unrecorded "$1/state" "$1"
}

# --- 1. the predicate --------------------------------------------------------

HOME_A=$(make_home captain-merge)
add_task "$HOME_A" ship-a
ready_task "$HOME_A" ship-a
[ "$(unrecorded "$HOME_A")" = "ship-a" ] || fail "a ready captain-merge PR must be reported as unrecorded"
pass "a ready PR waiting on the captain with no hold is reported"

(cd "$HOME_A" && tasks-axi hold ship-a --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null
[ -z "$(unrecorded "$HOME_A")" ] || fail "a captain-held task must not be reported"
pass "recording the wait as a captain hold clears the report"

(cd "$HOME_A" && tasks-axi unhold ship-a) >/dev/null
[ "$(unrecorded "$HOME_A")" = "ship-a" ] || fail "clearing the hold must re-report the wait"
(cd "$HOME_A" && tasks-axi hold ship-a --reason "waiting on an upstream release" --kind external) >/dev/null
[ "$(unrecorded "$HOME_A")" = "ship-a" ] || fail "a non-captain hold does not record a captain wait"
pass "only a captain-kind hold records a captain merge wait"

# The reason string is what distinguishes a merge wait from a captain-reserved
# post-merge step, so landing the PR can clear one without touching the other.
(cd "$HOME_A" && tasks-axi unhold ship-a) >/dev/null
(cd "$HOME_A" && tasks-axi hold ship-a --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null
fm_merge_wait_hold_is_merge_wait "$HOME_A" ship-a || fail "a merge-wait hold must be recognised as one"
(cd "$HOME_A" && tasks-axi unhold ship-a) >/dev/null
(cd "$HOME_A" && tasks-axi hold ship-a --reason "captain-reserved production release after merge" --kind captain) >/dev/null
fm_merge_wait_hold_is_merge_wait "$HOME_A" ship-a && fail "a reserved post-merge step must not be read as a merge wait"
fm_merge_wait_hold_is_merge_wait "$HOME_A" ship-absent && fail "an unknown task must not be read as a merge wait"
pass "a captain-reserved post-merge step is never mistaken for a merge wait"

HOME_B=$(make_home standing-authority)
add_task "$HOME_B" ship-b
ready_task "$HOME_B" ship-b on
[ -z "$(unrecorded "$HOME_B")" ] || fail "a yolo task merges under standing authority and has no captain wait"
pass "a task firstmate may merge itself is never reported"

HOME_C=$(make_home not-ready)
add_task "$HOME_C" ship-c
ready_task "$HOME_C" ship-c
printf 'working: fixing a review finding\n' >> "$HOME_C/state/ship-c.status"
[ -z "$(unrecorded "$HOME_C")" ] || fail "a task that moved past its done line is not waiting on a merge"
: > "$HOME_C/state/ship-c.status"
[ -z "$(unrecorded "$HOME_C")" ] || fail "a task with no reported PR is not waiting on a merge"
pass "the wait is read from the current status event, never from history alone"

HOME_D=$(make_home no-pr)
add_task "$HOME_D" ship-d
ready_task "$HOME_D" ship-d
grep -v '^pr=' "$HOME_D/state/ship-d.meta" > "$HOME_D/state/ship-d.meta.tmp"
mv "$HOME_D/state/ship-d.meta.tmp" "$HOME_D/state/ship-d.meta"
[ -z "$(unrecorded "$HOME_D")" ] || fail "a task with no recorded PR has no merge wait"
pass "a task with no recorded PR is never reported"

HOME_E=$(make_home no-backlog-item)
ready_task "$HOME_E" ship-e
[ -z "$(unrecorded "$HOME_E")" ] || fail "a task with no backlog item cannot carry a hold and must be skipped"
pass "a task with no backlog item is skipped rather than falsely reported"

# --- 2. the pull-based reminder ---------------------------------------------

HOME_F=$(make_home guard-warning)
add_task "$HOME_F" ship-f
ready_task "$HOME_F" ship-f
touch "$HOME_F/state/.last-watcher-beat"
OUT=$(FM_HOME="$HOME_F" FM_STATE_OVERRIDE="$HOME_F/state" FM_CONFIG_OVERRIDE="$HOME_F/config" \
  "$ROOT/bin/fm-guard.sh" 2>&1 || true)
assert_contains "$OUT" "ship-f has a PR waiting on the captain" "fm-guard.sh must name the waiting task"
assert_contains "$OUT" "tasks-axi hold ship-f" "fm-guard.sh must name the exact recording command"
pass "the pull-based guard names the wait and the command that records it"

# --- 3. the turn-end block ---------------------------------------------------

# The turn-end guard scopes itself to a primary-shaped checkout, so the fixture
# is one: a plain git repo with AGENTS.md and its own bin/ copy of the guard, the
# same shape tests/fm-turnend-guard.test.sh builds.
make_primary_home() {  # <name>
  local home
  home=$(make_home "$1")
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  mkdir -p "$home/bin" "$home/docs"
  local script
  for script in fm-turnend-guard.sh fm-supervision-instructions.sh fm-harness.sh \
    fm-operational-input.sh fm-primary-scope-lib.sh fm-supervision-lib.sh \
    fm-wake-lib.sh fm-merge-wait-lib.sh fm-tasks-axi-lib.sh; do
    cp "$ROOT/bin/$script" "$home/bin/$script"
  done
  cp -R "$ROOT/docs/supervision-protocols" "$home/docs/supervision-protocols"
  chmod +x "$home/bin/fm-turnend-guard.sh" "$home/bin/fm-supervision-instructions.sh" \
    "$home/bin/fm-harness.sh" "$home/bin/fm-operational-input.sh"
  printf '%s\n' "$home"
}

turnend() {  # <home>
  printf '{"stop_hook_active":false,"session_id":"s1"}' |
    FM_HOME="$1" "$1/bin/fm-turnend-guard.sh" 2>&1
}

HOME_G=$(make_primary_home turnend-block)
add_task "$HOME_G" ship-g
ready_task "$HOME_G" ship-g
touch "$HOME_G/state/.last-watcher-beat"
OUT=$(turnend "$HOME_G"); CODE=$?
expect_code 2 "$CODE" "an unrecorded captain merge wait must block the turn end"
assert_contains "$OUT" "A CAPTAIN MERGE DECISION IS WAITING" "the turn-end block must announce the wait"
assert_contains "$OUT" "tasks-axi hold ship-g" "the turn-end block must name the recording command"
pass "an unrecorded captain merge wait blocks the turn end once"

OUT=$(turnend "$HOME_G"); CODE=$?
assert_not_contains "$OUT" "A CAPTAIN MERGE DECISION IS WAITING" "the same wait must not block twice"
pass "the same unrecorded wait never blocks a second turn"

add_task "$HOME_G" ship-g2
ready_task "$HOME_G" ship-g2
OUT=$(turnend "$HOME_G"); CODE=$?
expect_code 2 "$CODE" "a newly unrecorded wait must block again"
assert_contains "$OUT" "ship-g2" "the new block must name the new wait"
pass "a new unrecorded wait blocks again"

(cd "$HOME_G" && tasks-axi hold ship-g --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null
(cd "$HOME_G" && tasks-axi hold ship-g2 --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null
OUT=$(turnend "$HOME_G"); CODE=$?
assert_not_contains "$OUT" "A CAPTAIN MERGE DECISION IS WAITING" "recorded waits must not block"
pass "recording every wait lets the turn end"

pass "fm-merge-wait.test.sh"
