#!/usr/bin/env bash
# Regression test for the claude) branch of bin/fm-spawn.sh: the generated
# <worktree>/.claude/settings.local.json must carry the lifecycle hooks it
# exists for, the task-keyed keep-warm self-wake entry, and NO attribution object.
#
# Co-author suppression is owned upstream now: upstream 72bfdd0 (#3945) passes an
# explicit `"attribution":{"commit":"","pr":"","sessionUrl":false}` object in
# every claude launch's inline `--settings` JSON, which
# tests/fm-spawn-dispatch-profile.test.sh asserts for the launch side. This file
# stays the zero-divergence pin for the worktree artifact: a regression that
# reintroduces a per-worker attribution object into the spawned settings file
# fails loudly. Exercises fm-spawn's real interface: a full spawn run against a
# fake tmux, with the claude harness, followed by a JSON parse of the generated
# settings artifact in the isolated worktree. Never asserts source bytes. The
# behavior is scoped to the claude branch, so a second spawn on another harness
# must produce no Claude settings file at all.
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
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ "${FM_FAKE_RELAUNCH:-0}" != 1 ] || printf '%s\n' "${FM_FAKE_WINDOW_ID:?FM_FAKE_WINDOW_ID unset}"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # Every text line and literal the spawn sends into the pane lands here, so a
    # test can assert the pane environment fm-spawn.sh builds.
    [ -n "${FM_FAKE_TMUX_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    if [ -n "${FM_FAKE_PANE_ENV:-}" ] && [ "${5:-}" = Enter ]; then
      (
        set +u
        [ ! -f "$FM_FAKE_PANE_ENV" ] || . "$FM_FAKE_PANE_ENV"
        eval "$4"
        export -p > "$FM_FAKE_PANE_ENV.tmp"
        mv "$FM_FAKE_PANE_ENV.tmp" "$FM_FAKE_PANE_ENV"
      )
    fi
    exit 0
    ;;
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
  # fm-spawn.sh refuses a ship brief with no filled intent/spec subsections.
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task

## Captain's intent
brief for $id

## Firstmate spec
Exercise the spawn behavior under test.
BRIEF
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn_command() {
  local fake_relaunch=0
  [ "${2:-}" != --relaunch ] || fake_relaunch=1
  : > "$HOME_DIR/state/.fake-tmux-send.log"
  env -u FM_NM_KEEPWARM_SECS \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TMUX_LOG="$HOME_DIR/state/.fake-tmux-send.log" \
    FM_FAKE_PANE_ENV="$HOME_DIR/state/.fake-pane-env" \
    FM_FAKE_RELAUNCH="$fake_relaunch" FM_FAKE_WINDOW_ID="fm-$1" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_spawn() {
  local id=$1 harness=$2
  run_spawn_command "$id" "$PROJ_DIR" "$harness" --mode no-mistakes --yolo off
}

run_relaunch() {
  run_spawn_command "$1" --relaunch
}

pane_keepwarm_secs() {
  env -i bash -c ". '$HOME_DIR/state/.fake-pane-env'; printf '%s' \"\${FM_NM_KEEPWARM_SECS-}\""
}

# The claude settings artifact must keep the lifecycle hooks and must NOT
# reintroduce the per-worker attribution object: co-author suppression is
# user-global now, and project settings must not carry it.
test_claude_spawn_settings_carry_hooks_without_attribution() {
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
  jq -e 'has("attribution") | not' "$settings" >/dev/null \
    || fail "the per-worker attribution object was reintroduced into the spawned settings"
  for hook in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks.\"$hook\" | length > 0" "$settings" >/dev/null \
      || fail "generated settings lost the $hook lifecycle hook"
  done
  pass "claude spawn settings carry the hooks and no per-worker attribution object"
}

# Scope pin: another harness's spawn must not receive a Claude settings file,
# so the carrier cannot leak outside the claude branch.
test_non_claude_spawn_has_no_claude_settings_file() {
  local rec id out status
  id=codex-no-attrib-z2
  rec=$(make_case codex-no-attrib "$id" codex)
  read_case_record "$rec"

  out=$(run_spawn "$id" codex)
  status=$?
  expect_code 0 "$status" "codex spawn should succeed against the fake tmux"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  [ ! -e "$WT_DIR/.claude/settings.local.json" ] \
    || fail "codex worktree must not carry a claude settings file"
  pass "non-claude spawn carries no claude settings file"
}

# The keep-warm self-wake (bin/fm-claude-keepwarm-selfwake.sh) rides the same
# artifact as a second asyncRewake Stop entry keyed to this task, so an idle
# Claude crew in any project repo warms its own cache. The injected command is
# run for real with a seconds-scale interval: it must fire the marked wake from
# the spawning home's state dir, and stand down when the home disables it.
test_claude_spawn_settings_inject_keepwarm_selfwake() {
  local rec id out status settings cmd rc marker
  id=claude-keepwarm-inject-z3
  rec=$(make_case claude-keepwarm "$id" claude)
  read_case_record "$rec"

  out=$(run_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed against the fake tmux"
  settings="$WT_DIR/.claude/settings.local.json"
  [ -f "$settings" ] || fail "claude spawn did not generate $settings"
  cmd=$(jq -r '.hooks.Stop[0].hooks[] | select(.asyncRewake == true) | .command' "$settings")
  [ -n "$cmd" ] || fail "generated settings carry no asyncRewake Stop entry for the keep-warm self-wake"
  jq -e '.hooks.Stop[0].hooks[] | select(.asyncRewake == true) | .timeout == 3600' "$settings" >/dev/null \
    || fail "the keep-warm Stop entry must declare the 3600s hook timeout"

  marker="$HOME_DIR/state/.keepwarm-$id"
  rc=0
  printf '%s\n' '{"session_id":"sess-crew","stop_hook_active":false}' \
    | (cd "$WT_DIR" && FM_NM_KEEPWARM_SECS=1 sh -c "$cmd") > "$TMP_ROOT/keepwarm-inject.out" 2>&1 || rc=$?
  expect_code 2 "$rc" "the injected crew hook must fire the native wake at the deadline"
  assert_contains "$(cat "$TMP_ROOT/keepwarm-inject.out")" $'\xE2\x81\xA3FIRSTMATE_OP: v1 keep-warm: ' \
    "the injected crew hook must deliver the marked keep-warm banner"
  assert_present "$marker" "the crew wake must record its marker in the spawning home's state dir"
  assert_absent "$WT_DIR/state" "the crew wake must not create state inside the project worktree"

  rm -f "$marker"
  rc=0
  printf '%s\n' '{"session_id":"sess-crew","stop_hook_active":false}' \
    | (cd "$WT_DIR" && FM_NM_KEEPWARM_SECS=0 sh -c "$cmd") > "$TMP_ROOT/keepwarm-inject-off.out" 2>&1 || rc=$?
  expect_code 0 "$rc" "FM_NM_KEEPWARM_SECS=0 must disable the injected crew hook"
  assert_absent "$marker" "a disabled home must not arm the crew wake"
  pass "claude spawn injects the task-keyed keep-warm self-wake into the crew's Stop hooks"
}

# A home that configures config/keepwarm-secs hands its spawned crew the
# resolved cadence in the pane environment, so the crew's injected keep-warm
# hook needs no reach into this home's config dir from a project worktree. A
# home without that file leaves the pane exactly as it was before.
test_claude_spawn_injects_configured_keepwarm_cadence() {
  local rec id out status log
  id=claude-keepwarm-config-off-z4
  rec=$(make_case claude-keepwarm-config "$id" claude)
  read_case_record "$rec"

  out=$(run_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed against the fake tmux"
  log="$HOME_DIR/state/.fake-tmux-send.log"
  assert_present "$log" "the fake tmux must record the text lines the spawn sends"
  assert_contains "$(cat "$log")" "export FM_TASK_ID=$id" \
    "the ship marker must still be sent into the pane"
  assert_not_contains "$(cat "$log")" "export FM_NM_KEEPWARM_SECS=" \
    "an unconfigured home must not inject a keep-warm cadence"
  [ -z "$(pane_keepwarm_secs)" ] \
    || fail "an unconfigured home must leave an unmarked pane cadence unset"

  id=claude-keepwarm-config-on-z5
  rec=$(make_case claude-keepwarm-config-set "$id" claude)
  read_case_record "$rec"
  printf '3000\n' > "$HOME_DIR/config/keepwarm-secs"
  out=$(run_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed against the fake tmux"
  log="$HOME_DIR/state/.fake-tmux-send.log"
  assert_contains "$(cat "$log")" "export FM_NM_KEEPWARM_SECS=3000" \
    "a configured home must hand the crew the resolved keep-warm cadence"
  assert_contains "$(cat "$log")" "export FM_TASK_ID=$id" \
    "the ship marker must still be sent alongside it"
  [ "$(pane_keepwarm_secs)" = 3000 ] \
    || fail "the configured cadence did not reach the pane environment"

  rm -f "$HOME_DIR/config/keepwarm-secs"
  out=$(run_relaunch "$id")
  status=$?
  expect_code 0 "$status" "claude relaunch should succeed after keepwarm-secs removal: $out"
  [ -z "$(pane_keepwarm_secs)" ] \
    || fail "relaunch retained a cadence injected from the removed config file"

  # The injected value is the resolved interval, not the raw file: the cap
  # clamps a request above 3000 exactly as it does for the environment variable.
  id=claude-keepwarm-config-cap-z6
  rec=$(make_case claude-keepwarm-config-cap "$id" claude)
  read_case_record "$rec"
  printf '7200\n' > "$HOME_DIR/config/keepwarm-secs"
  out=$(run_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed against the fake tmux"
  assert_contains "$(cat "$HOME_DIR/state/.fake-tmux-send.log")" \
    "export FM_NM_KEEPWARM_SECS=3000" \
    "an above-cap config value must reach the crew already clamped"
  pass "claude spawn hands crews the configured cadence and clears stale injected values on relaunch"
}

test_claude_spawn_settings_carry_hooks_without_attribution
test_non_claude_spawn_has_no_claude_settings_file
test_claude_spawn_settings_inject_keepwarm_selfwake
test_claude_spawn_injects_configured_keepwarm_cadence

echo "# all fm-spawn-claude-attribution tests passed"
