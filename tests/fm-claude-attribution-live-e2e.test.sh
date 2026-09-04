#!/usr/bin/env bash
# Opt-in live regression for Claude commit attribution suppression in its
# production shape (portable pin: tests/fm-spawn-claude-attribution.test.sh).
# The user-global ~/.claude/settings.json carries the attribution object
# (attribution.commit="" + attribution.sessionUrl=false, captain-approved);
# bin/fm-spawn.sh writes no per-worker attribution any more, only the lifecycle
# hooks in <worktree>/.claude/settings.local.json. This guard drives the real
# installed Claude Code twice, proving that shape end to end:
#   baseline - no attribution anywhere: the Co-Authored-By trailer appears.
#   candidate - the user-global attribution object present: the same commit
#     carries neither the trailer nor any Claude-Session claude.ai line.
#   composed - the spawn's hooks-only settings.local.json sits in the repo
#     alongside the user-global object: suppression still holds, so the
#     production composition never re-enables the trailer.
# The baseline run keeps the guard from going quietly vacuous - a regression
# that lets the trailer through fails loudly naming the harness and version.
# The attribution object is injected through `claude --settings`, the same
# merged settings view a user-global settings.json resolves into, because
# CLAUDE_CONFIG_DIR redirection breaks OAuth refresh in this install; the real
# HOME and managed auth stay in place.
# The project is isolated under a lab root.
set -u

if [ "${FM_CLAUDE_ATTRIBUTION_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_ATTRIBUTION_LIVE_E2E=1 to run the Claude attribution live regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
source "$ROOT/bin/fm-timeout-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found: the attribution live guard checked nothing"
CLAUDE_VERSION=$(claude --version) || fail "claude --version failed"
CLAUDE_BIN=$(command -v claude)
CLAUDE_MODEL=${FM_CLAUDE_ATTRIBUTION_MODEL:-claude-sonnet-4-5}
# The user-global attribution shape firstmate deploys to ~/.claude/settings.json.
GLOBAL_SHAPE='{"attribution":{"commit":"","sessionUrl":false}}'
# The hooks-only settings.local.json bin/fm-spawn.sh now writes for claude
# crews, byte-identical to its heredoc (upstream shape, no attribution key).
LOCAL_HOOKS='{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"true"}]}],"Stop":[{"hooks":[{"type":"command","command":"true"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"true"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"true"}]}]}}'

LAB="$ROOT/.claude-attribution-live-e2e.$$"
REPO="$LAB/repo"
SETTINGS="$REPO/.claude/settings.local.json"

KEEP_LAB=${FM_KEEP_LAB:-0}
cleanup() {
  if [ "$KEEP_LAB" = 1 ]; then
    printf 'kept lab at %s\n' "$LAB" >&2
  else
    rm -rf "$LAB"
  fi
}
trap cleanup EXIT

mkdir -p "$LAB" "$REPO/.claude"
git -C "$REPO" init -q
git -C "$REPO" config user.email "fm-live-guard@example.invalid"
git -C "$REPO" config user.name "Firstmate Live Guard"
printf 'attribution live guard fixture\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm initial

# claude_commit <message> [extra claude args...] runs one real Claude session,
# cwd locked to the lab repo, that edits the fixture and commits; the commit
# body is the guard's signal. The post-run subject check refuses a commit that
# landed anywhere but the lab repo, so a stray cwd can never pass silently.
claude_commit() {
  local message=$1
  shift
  printf 'live guard change\n' >> "$REPO/file.txt"
  ( cd "$REPO" \
      && fm_run_timed 300 "$CLAUDE_BIN" "$@" -p --dangerously-skip-permissions --model "$CLAUDE_MODEL" \
        "Append a line 'live guard change' to file.txt, then create a git commit with the message '$message'." \
        > "$LAB/run.log" 2>&1 ) \
    || fail "claude $CLAUDE_VERSION run failed (see $LAB/run.log)"
  git -C "$REPO" log -1 --format=%s | grep -qF "$message" \
    || fail "claude $CLAUDE_VERSION did not commit '$message' in the lab repo"
  git -C "$REPO" log -1 --format=%B
}

no_co_author() {  # <commit-body>
  printf '%s\n' "$1" | grep -qi '^Co-Authored-By: ' \
    && return 1
  printf '%s\n' "$1" | grep -q 'Claude-Session:' \
    && return 1
  printf '%s\n' "$1" | grep -q 'claude.ai/code' \
    && return 1
  return 0
}

# Baseline: no attribution anywhere. The trailer must appear; if it does not,
# the guard's divergence assumption is broken and it must not pass silently.
BASELINE_BODY=$(claude_commit "attribution live guard baseline")
printf '%s\n' "$BASELINE_BODY" | grep -q '^Co-Authored-By: ' \
  || fail "claude $CLAUDE_VERSION baseline commit carried no Co-Authored-By trailer; divergence assumption broken"

# Candidate: the user-global attribution object present (via --settings, the
# merged settings view the global file resolves into, with the real global
# settings still in place underneath). Both lines must disappear.
CANDIDATE_BODY=$(claude_commit "attribution live guard candidate" --settings "$GLOBAL_SHAPE")
no_co_author "$CANDIDATE_BODY" \
  || fail "claude $CLAUDE_VERSION still emitted attribution with the user-global object present"
printf '%s\n' "$CANDIDATE_BODY" | grep -q 'attribution live guard candidate' \
  || fail "claude $CLAUDE_VERSION candidate commit lost its descriptive message"

# Composed: the hooks-only settings.local.json fm-spawn writes for claude
# crews sits in the repo next to the user-global object. A project-level file
# that reintroduced or overrode attribution would break suppression here.
printf '%s\n' "$LOCAL_HOOKS" > "$SETTINGS"

COMPOSED_BODY=$(claude_commit "attribution live guard composed" --settings "$GLOBAL_SHAPE")
no_co_author "$COMPOSED_BODY" \
  || fail "claude $CLAUDE_VERSION re-emitted attribution next to the spawn's hooks-only settings.local.json"
printf '%s\n' "$COMPOSED_BODY" | grep -q 'attribution live guard composed' \
  || fail "claude $CLAUDE_VERSION composed commit lost its descriptive message"

echo "ok - claude $CLAUDE_VERSION (bin: $CLAUDE_BIN) commit attribution suppressed via the user-global settings shape"