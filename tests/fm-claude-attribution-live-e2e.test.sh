#!/usr/bin/env bash
# Opt-in live regression for Claude commit attribution suppression
# (bin/fm-spawn.sh claude branch; portable pin: tests/fm-spawn-claude-attribution.test.sh).
# Proves, against the real installed Claude Code: WITHOUT the generated
# .claude/settings.local.json attribution object, a Claude-made commit carries
# a Co-Authored-By trailer; WITH attribution.commit="" and
# attribution.sessionUrl=false, the same commit carries neither the trailer
# nor any Claude-Session claude.ai line. The baseline run keeps the guard from
# going quietly vacuous - a regression that lets the trailer through fails
# loudly naming the harness and version.
# The project is isolated under a lab root; Claude keeps its managed auth.
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

# claude_commit <message> runs one real Claude session, cwd locked to the
# lab repo, that edits the fixture and commits; the commit body is the guard's
# signal. The post-run subject check refuses a commit that landed anywhere
# but the lab repo, so a stray cwd can never pass silently.
claude_commit() {
  local message=$1
  printf 'live guard change\n' >> "$REPO/file.txt"
  ( cd "$REPO" \
      && fm_run_timed 300 "$CLAUDE_BIN" -p --dangerously-skip-permissions --model "$CLAUDE_MODEL" \
        "Append a line 'live guard change' to file.txt, then create a git commit with the message '$message'." \
        > "$LAB/run.log" 2>&1 ) \
    || fail "claude $CLAUDE_VERSION run failed (see $LAB/run.log)"
  git -C "$REPO" log -1 --format=%s | grep -qF "$message" \
    || fail "claude $CLAUDE_VERSION did not commit '$message' in the lab repo"
  git -C "$REPO" log -1 --format=%B
}

# Baseline: no attribution setting. The trailer must appear; if it does not,
# the guard's divergence assumption is broken and it must not pass silently.
BASELINE_BODY=$(claude_commit "attribution live guard baseline")
printf '%s\n' "$BASELINE_BODY" | grep -q '^Co-Authored-By: ' \
  || fail "claude $CLAUDE_VERSION baseline commit carried no Co-Authored-By trailer; divergence assumption broken"

# Candidate: the attribution object and complete lifecycle hook set fm-spawn
# emits for claude crews. Both lines must disappear.
cat > "$SETTINGS" <<'JSON'
{"attribution":{"commit":"","sessionUrl":false},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"true"}]}],"Stop":[{"hooks":[{"type":"command","command":"true"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"true"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"true"}]}]}}
JSON

CANDIDATE_BODY=$(claude_commit "attribution live guard candidate")
printf '%s\n' "$CANDIDATE_BODY" | grep -qi '^Co-Authored-By: ' \
  && fail "claude $CLAUDE_VERSION still emitted a Co-Authored-By trailer with attribution.commit=\"\""
printf '%s\n' "$CANDIDATE_BODY" | grep -q 'Claude-Session:' \
  && fail "claude $CLAUDE_VERSION still emitted a Claude-Session line with attribution.sessionUrl=false"
printf '%s\n' "$CANDIDATE_BODY" | grep -q 'claude.ai/code' \
  && fail "claude $CLAUDE_VERSION still emitted a claude.ai/code link with attribution.sessionUrl=false"
printf '%s\n' "$CANDIDATE_BODY" | grep -q 'attribution live guard candidate' \
  || fail "claude $CLAUDE_VERSION candidate commit lost its descriptive message"

echo "ok - claude $CLAUDE_VERSION (bin: $CLAUDE_BIN) commit attribution suppressed via settings.local.json"
