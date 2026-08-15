#!/usr/bin/env bash
# Regression test for the claude) branch of bin/fm-spawn.sh: the generated
# <worktree>/.claude/settings.local.json must carry the attribution object that
# suppresses Claude's Co-Authored-By commit trailer (attribution.commit="") and
# the Claude-Session claude.ai link (attribution.sessionUrl=false), while the
# lifecycle hooks the file exists for stay intact.
#
# Exercises fm-spawn's real interface: a full spawn run against a fake tmux,
# with the claude harness, followed by a JSON parse of the generated settings
# artifact in the isolated worktree. Never asserts source bytes. The behavior
# is scoped to the claude branch, so a second spawn on another harness must
# produce no Claude attribution settings file at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-attribution)

# make_fakebin <dir> builds a fake tmux whose pane always reports the settled
# worktree path, plus exit-0 stubs for the other spawn-touched tools. Same
# shape as the worktree-settle suite: the pane reads settle instantly.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> <harness> builds an isolated home, a project with a
# real git worktree, and the fake toolchain, echoing the pipe record.
make_case() {
  local name=$1 id=$2 harness=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'source: human\nbatch_id: test-fixture\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1 harness=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$harness" --mode no-mistakes --yolo off 2>&1
}

# The claude settings artifact carries the suppression object next to the
# hooks, and stays valid JSON that a real claude session would load.
test_claude_spawn_writes_attribution_suppression() {
  local rec id out status settings
  id=claude-attrib-settings-z1
  rec=$(make_case claude-attrib "$id" claude)
  read_case_record "$rec"

  out=$(run_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed against the fake tmux"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the spawned worktree"

  settings="$WT_DIR/.claude/settings.local.json"
  [ -f "$settings" ] || fail "claude spawn did not generate $settings"
  command -v jq >/dev/null 2>&1 || fail "jq is required to parse the generated settings"
  jq -e '(.attribution.commit | type == "string")
    and .attribution.commit == ""
    and (.attribution.sessionUrl | type == "boolean")
    and .attribution.sessionUrl == false' "$settings" >/dev/null \
    || fail "generated attribution settings have the wrong values or JSON types"
  for hook in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks.\"$hook\" | length > 0" "$settings" >/dev/null \
      || fail "generated settings lost the $hook lifecycle hook"
  done
  pass "claude spawn settings carry commit=\"\" + sessionUrl=false with hooks intact"
}

# Scope pin: another harness's spawn must not receive a Claude attribution
# settings file, so the suppression cannot leak outside the claude branch.
test_non_claude_spawn_has_no_claude_attribution_settings() {
  local rec id out status
  id=codex-no-attrib-z2
  rec=$(make_case codex-no-attrib "$id" codex)
  read_case_record "$rec"

  out=$(run_spawn "$id" codex)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed against the fake tmux"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ ! -e "$WT_DIR/.claude/settings.local.json" ] \
    || fail "codex worktree must not carry a claude attribution settings file"
  pass "non-claude spawn carries no claude attribution settings file"
}

test_claude_spawn_writes_attribution_suppression
test_non_claude_spawn_has_no_claude_attribution_settings

echo "# all fm-spawn-claude-attribution tests passed"
