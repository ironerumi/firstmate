#!/usr/bin/env bash
# fm-brief-repo-guard.sh - fork-added wrapper around bin/fm-brief.sh that adds a
# control-plane boundary block to Firstmate-repo briefs.
#
# bin/fm-brief.sh is upstream-owned and hot, so this fork never patches it. This
# wrapper takes exactly the same arguments, runs bin/fm-brief.sh unchanged, and
# then, ONLY when a ship or scout brief's target project resolves to the
# Firstmate repo itself, appends one "Control-plane boundary" section to the
# generated data/<task-id>/brief.md. Secondmate charters and every non-Firstmate
# invocation are transparent: the child's stdout, stderr, and exit status pass
# through untouched and the brief bytes are unchanged.
#
# The caller-supplied repo string cannot identify Firstmate's own repo on its
# own, so detection is explicit and conservative. The target counts as the
# Firstmate repo when a registered project clone has the same canonical
# host/owner/repo origin as the code root, or when its unresolved name matches
# the code root's origin repo name.
# The code-root basename is used only when neither origin can be resolved.
# Anything else leaves the brief alone.
#
# Usage: fm-brief-repo-guard.sh <same args as bin/fm-brief.sh>
#   Run bin/fm-brief.sh --help for the authoritative scaffold usage; that help
#   is authoritative for this wrapper too, with the single addition above.
#   FM_PROJECTS_OVERRIDE selects the project-clone root used by rule 3.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_BRIEF="$SCRIPT_DIR/fm-brief.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

case "${1:-}" in
  -h | --help)
    "$REAL_BRIEF" --help
    printf '\nThis wrapper additionally appends a control-plane boundary section when a ship or scout brief targets the Firstmate repo itself.\n'
    exit 0
    ;;
esac

# The first two positionals are <task-id> <repo-name> for a ship or scout brief.
# Scan the caller's own arguments the same way bin/fm-brief.sh does, without
# re-implementing its validation: a rejected argument list exits non-zero before
# anything is added.
positionals=()
want_value=
KIND=ship
for arg in "$@"; do
  if [ -n "$want_value" ]; then
    want_value=
    continue
  fi
  case "$arg" in
    --mode) want_value=1 ;;
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --*) ;;
    *) positionals+=("$arg") ;;
  esac
done
ID=${positionals[0]:-}
REPO=${positionals[1]:-}

"$REAL_BRIEF" "$@"

[ "$KIND" != secondmate ] || exit 0
[ -n "$ID" ] || exit 0

# Resolve the brief path the same way bin/fm-brief.sh does, so the appended
# section lands in the artifact the child just wrote.
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$FM_DATA_OVERRIDE
else
  DATA="$FM_HOME/data"
fi
BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || exit 0

# canonical_remote_identity <url>: normalize supported transport spellings to
# a host/owner/repo identity while preserving path case.
canonical_remote_identity() {
  local url=$1
  local authority host path
  url=${url%/}
  url=${url%.git}
  case "$url" in
    http://* | https://* | ssh://* | git://*)
      url=${url#*://}
      case "$url" in
        */*) ;;
        *) return 1 ;;
      esac
      authority=${url%%/*}
      path=${url#*/}
      host=${authority##*@}
      ;;
    *:*)
      authority=${url%%:*}
      path=${url#*:}
      host=${authority##*@}
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] && [ -n "$path" ] || return 1
  case "$path" in
    */*) ;;
    *) return 1 ;;
  esac
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  printf '%s/%s\n' "$host" "$path"
}

is_firstmate_repo() {
  local repo=$1 root_identity root_name root_origin target_identity target_origin
  [ -n "$repo" ] || return 1
  root_origin=$(git -C "$FM_ROOT" config --get remote.origin.url 2>/dev/null || true)
  target_origin=
  if [ -d "$PROJECTS/$repo" ]; then
    target_origin=$(git -C "$PROJECTS/$repo" config --get remote.origin.url 2>/dev/null || true)
  fi
  if [ -n "$target_origin" ]; then
    [ -n "$root_origin" ] || return 1
    root_identity=$(canonical_remote_identity "$root_origin") || return 1
    target_identity=$(canonical_remote_identity "$target_origin") || return 1
    [ "$target_identity" = "$root_identity" ]
    return
  fi
  if [ -n "$root_origin" ]; then
    root_identity=$(canonical_remote_identity "$root_origin") || return 1
    root_name=${root_identity##*/}
    [ -n "$root_name" ] && [ "$repo" = "$root_name" ]
    return
  fi
  [ "$repo" = "$(basename "$FM_ROOT")" ]
}

is_firstmate_repo "$REPO" || exit 0

if grep -Fqx '## Control-plane boundary' "$BRIEF"; then
  exit 0
fi

cat >> "$BRIEF" <<'EOF'

## Control-plane boundary

This brief targets Firstmate's own repository, so Firstmate's entire control plane sits in your worktree.
`bin/fm-*.sh` lifecycle entrypoints and the agent-only skills under `.agents/skills/` are Firstmate's controls, not tools for you to run.
Do not run any Firstmate control or lifecycle script, including `fm-spawn`, `fm-send`, `fm-control`, `fm-teardown`, `fm-promote`, `fm-wake-drain`, `fm-captain-hold`, `fm-pr-merge`, `fm-pr-check`, `fm-merge-local`, and `fm-task-register`.
Do not run any `tasks-axi` lifecycle verb (`hold`, `complete`, `answer`, `done`, `start`).
Do not run the commands documented inside Firstmate's authority skills, such as `captain-hold-lifecycle` and `ask-user-authority`.
You may and must edit those scripts as source code where the task calls for it: editing them is the work, running them as controls is not.
You may run ordinary development tooling, including `git`, `bin/fm-lint.sh`, `bin/fm-test-run.sh`, individual `tests/*.test.sh`, and the validation pipeline when Firstmate tells you to validate.
Firstmate files every decision, hold, and merge.
If you find a decision that belongs to the captain, append `needs-decision:` to your status file and stop.
EOF

exit 0
