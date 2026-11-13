#!/usr/bin/env bash
# Fork returned-home, default-branch and Orca launch regressions.
# Existing upstream cases remain in their hosts; their fork extensions live here.
set -u

# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-slot-safety)
export FM_BACKEND=tmux
fm_git_identity fmtest fmtest@example.invalid
trap fm_test_cleanup EXIT
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

write_spawn_brief() {  # <data-dir> <id>
  local data=$1 id=$2
  cat > "$data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Orca dispatch.

## Firstmate spec
Verify the Orca lifecycle behavior under test.
EOF
}

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

# A fresh git repo on `main` with one commit and a local origin. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_secondmate_teardown_scrubs_returned_slot() {
  local home subhome subhome_abs fakebin log fmroot leftover
  home="$TMP_ROOT/scrub-home"
  subhome="$TMP_ROOT/scrub-subhome"
  fmroot="$TMP_ROOT/scrub-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state/procevent" "$subhome/data/domain" "$subhome/config" "$subhome/projects/alpha"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  printf 'local\n%s\n' "$home" > "$subhome/.fm-secondmate-parent"
  printf 'x\n' > "$subhome/state/domain.status"
  subhome_abs=$(cd "$subhome" && pwd -P)
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/scrub-fake")
  log="$TMP_ROOT/scrub-fake/tmux.log"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/scrub-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_KEEP=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed for a leased secondmate home whose return keeps the slot"
  grep -F "treehouse return --force $subhome_abs" "$log" >/dev/null || fail "teardown did not return the leased home"
  [ -d "$subhome" ] || fail "the returned pool slot itself must remain"
  [ -f "$subhome/AGENTS.md" ] || fail "scrub touched tracked content of the returned slot"
  for leftover in state data config projects .fm-secondmate-home .fm-secondmate-parent; do
    [ ! -e "$subhome/$leftover" ] || fail "returned slot still carries the retired home's $leftover"
  done
  pass "secondmate teardown scrubs the retired home's operational dirs and markers from the returned slot"
}

test_secondmate_teardown_scrub_spares_reseeded_slot() {
  local home subhome fakebin log fmroot
  home="$TMP_ROOT/scrub-spare-home"
  subhome="$TMP_ROOT/scrub-spare-subhome"
  fmroot="$TMP_ROOT/scrub-spare-fmroot"
  make_firstmate_git_root "$fmroot"
  git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
  mkdir -p "$home/state" "$home/data" "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cat > "$home/state/domain.meta" <<EOF
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
EOF
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/scrub-spare-fake")
  log="$TMP_ROOT/scrub-spare-fake/tmux.log"
  # The slot is reseeded for another home between the return and the scrub.
  cat > "$fakebin/treehouse.real" < "$fakebin/treehouse"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
"$fakebin/treehouse.real" "\$@" || exit \$?
[ "\${1:-}" != return ] || printf 'other\n' > "$subhome/.fm-secondmate-home"
SH
  chmod +x "$fakebin/treehouse" "$fakebin/treehouse.real"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/scrub-spare-fake/pane.txt" \
    FM_FAKE_TREEHOUSE_RETURN_KEEP=1 \
    "$ROOT/bin/fm-teardown.sh" domain >/dev/null 2>/dev/null \
    || fail "teardown failed while the slot was reseeded after its return"
  [ -d "$subhome/state" ] || fail "scrub removed state from a slot now marked for another home"
  [ "$(cat "$subhome/.fm-secondmate-home")" = other ] || fail "scrub removed another home's marker"
  pass "secondmate teardown scrub spares a slot that no longer carries the retired home's marker"
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"

  git -C "$repo" branch develop main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  out=$(run_guard "$repo")
  assert_contains "$out" "not its default branch 'develop'" "guard did not resolve a non-main default branch"
  assert_contains "$out" "checkout develop" "guard used the wrong restore branch for a non-main repository"
  pass "fm-guard: bordered tangle banner resolves the default branch and suppresses repair commands in read-only mode"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log staged launch
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  write_spawn_brief "$data" "$id"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn::/orca/wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  out=$( HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn::/orca/wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  assert_contains "$(cat "$log")" "$id.status' PATH='$ROOT/bin/shims':\$PATH" \
    "spawn did not bind the validation-owner guard to this task through the Orca terminal"
  staged=$(tr '\037' '\n' < "$log" | sed -n "s/^\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] \
    || fail "spawn did not send Orca a readable staged launch command"
  launch=$(cat "$staged")
  add_dirs="--add-dir '$(cd "$state" && pwd -P)/operational-inbox' --add-dir '$(cd "$state" && pwd -P)/$id.inbox' --add-dir '$(cd "$data" && pwd -P)/$id' --add-dir '$(cd "$ROOT" && pwd -P)/.agents/skills'"
  assert_contains "$launch" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions $add_dirs --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}'" \
    "the staged launch sent through Orca did not select the Claude harness"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

fm_test_run \
  test_secondmate_teardown_scrubs_returned_slot \
  test_secondmate_teardown_scrub_spares_reseeded_slot \
  test_guard_banner \
  test_spawn_writes_orca_metadata_and_launches_harness
