#!/usr/bin/env bash
# fm-nm-status-lib.sh - the single owner of reading a no-mistakes run from a
# worktree.
#
# Two callers need the same three primitives and must not drift apart:
#   - bin/fm-crew-state.sh, which reconciles a crew's CURRENT state for firstmate
#   - bin/fm-nm-guard-lib.sh, which decides whether a worker command would take
#     validation ownership away from a live run (docs/nm-validation-owner-guard.md)
#
# The primitives are: a bounded invocation of the real no-mistakes binary in a
# given worktree, a scalar read of a TOON key from its output, and the
# code-identity test that binds a reported run to that worktree's HEAD.
# fm_nm_run_state adds the one classification the guard needs on top of them.
#
# Nothing here writes, and every failure degrades to "cannot tell" rather than to
# a guess: an absent CLI, an absent timeout runner, a timed-out call, or an
# unrecognized status word all report `unknown`, which every caller treats as
# permissive. A guard that denies work because it could not read the pipeline
# would be worse than the duplication it prevents.

# Bounded-call runner, resolved once per shell.
fm_nm_timeout_runner() {
  if [ -n "${FM_NM_TIMEOUT_RUNNER:-}" ]; then
    printf '%s' "$FM_NM_TIMEOUT_RUNNER"
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then FM_NM_TIMEOUT_RUNNER=timeout
  elif command -v gtimeout >/dev/null 2>&1; then FM_NM_TIMEOUT_RUNNER=gtimeout
  elif command -v perl >/dev/null 2>&1; then FM_NM_TIMEOUT_RUNNER=perl
  else FM_NM_TIMEOUT_RUNNER=none
  fi
  printf '%s' "$FM_NM_TIMEOUT_RUNNER"
}

fm_nm_trim() {  # <text>
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {  # <text>
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Absolute path of a real tool of <name> on PATH, skipping firstmate's own shim
# directory.
#
# bin/shims/ holds PATH shims named exactly like the tools they guard, so a naive
# lookup from inside a shim would re-enter that shim and recurse. Walk PATH by
# hand and skip every candidate that resolves inside the shim directory.
fm_nm_path_bin() {  # <name>
  local name=$1 shim_dir entry candidate candidate_dir
  shim_dir=${FM_NM_SHIM_DIR:-}
  [ -z "$shim_dir" ] || shim_dir=$(CDPATH='' cd -- "$shim_dir" 2>/dev/null && pwd -P) || shim_dir=
  local IFS=:
  for entry in ${PATH:-}; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/$name"
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    if [ -n "$shim_dir" ]; then
      candidate_dir=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
      [ "$candidate_dir" != "$shim_dir" ] || continue
    fi
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Absolute path of the real no-mistakes binary. FM_NM_BIN overrides the search
# for tests and for a non-PATH install.
fm_nm_bin() {
  if [ -n "${FM_NM_BIN:-}" ]; then
    [ -x "$FM_NM_BIN" ] || return 1
    printf '%s' "$FM_NM_BIN"
    return 0
  fi
  fm_nm_path_bin no-mistakes
}

# Bounded no-mistakes call inside <worktree>; stdout only, never fails the
# caller. Prints nothing when the CLI, the worktree, or a timeout runner is
# unavailable, which every caller reads as "cannot tell".
fm_nm_call() {  # <worktree> <timeout-seconds> <args...>
  local wt=$1 secs=$2 bin
  shift 2
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ -d "$wt" ] || return 0
  bin=$(fm_nm_bin) || return 0
  case "$(fm_nm_timeout_runner)" in
    timeout)  ( cd "$wt" && timeout "$secs" "$bin" "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$wt" && gtimeout "$secs" "$bin" "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$wt" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$bin" "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in captured no-mistakes output.
fm_nm_field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 when a reported run head binds to this worktree's code identity: the two
# commits are equal, or the worktree HEAD is an ancestor of the run head because
# the pipeline's own fix commits advanced the run on the same history. Local work
# that advanced past the run head, or diverged from it, does not bind.
fm_nm_head_matches() {  # <worktree> <run-head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# Classify one run status word. The three lists are exhaustive over the words
# the installed CLI is known to print; anything else is `unknown` and therefore
# permissive, because a status vocabulary that grew is far more likely than a
# guard that should start blocking a word it has never seen.
fm_nm_classify_status() {  # <status-word>
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    running|pending|fixing|active|in_progress|queued|started) printf 'active' ;;
    intent|rebase|review|test|document|lint|push|pr|ci) printf 'active' ;;
    awaiting_approval|fix_review|awaiting_decision|parked|needs_decision) printf 'parked' ;;
    completed|passed|checks-passed|checks_passed|succeeded) printf 'terminal' ;;
    failed|cancelled|canceled|aborted|errored) printf 'failed' ;;
    *) printf 'unknown' ;;
  esac
}

# The one line the guard needs about a worktree's branch:
#
#   <state>\t<run-id>\t<step>
#
# state is one of none, active, parked, failed, terminal, unknown.
#   none     - no run is attributed to this branch, so nothing owns validation
#   active   - a run is mid-pipeline; a second run or a superseding push kills it
#   parked   - a run is waiting at an answerable gate; abandoning it discards
#              every completed step
#   failed   - the attributed run is terminally failed or cancelled
#   terminal - the attributed run completed
#   unknown  - the pipeline could not be read; callers must stay permissive
#
# A run is attributed to this worktree by branch identity alone: an active run on
# this branch is exactly the run a second run or a push would supersede, whatever
# the current HEAD. Code identity is applied only to a `failed` run, where the
# question is whether THIS worktree's work is the work that failed.
fm_nm_run_state() {  # <worktree> [timeout-seconds]
  local wt=$1 secs=${2:-${FM_NM_STATUS_TIMEOUT:-10}} out branch run_branch state run_id step
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ -z "$branch" ]; then
    printf 'none\t\t\n'
    return 0
  fi
  out=$(fm_nm_call "$wt" "$secs" axi status)
  if [ -z "$out" ]; then
    printf 'unknown\t\t\n'
    return 0
  fi
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  if [ -z "$run_branch" ] || [ "$run_branch" != "$branch" ]; then
    printf 'none\t\t\n'
    return 0
  fi
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  state=$(fm_nm_classify_status "$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")")
  # A gate parks the run even when the run-level status word still reads active:
  # the steps table is where awaiting_approval and fix_review always appear. Only
  # an active run is read that way: a terminal, failed or unrecognized run word is
  # the run's own verdict, and it outranks a gate row the run left behind.
  if [ "$state" = active ]; then
    if printf '%s\n' "$out" | grep -Eq '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,'; then
      state=parked
    fi
  fi
  step=$(printf '%s\n' "$out" | grep -Eo '^[[:space:]]*[a-z]+,[[:space:]]*"?(running|fixing|awaiting_approval|fix_review|failed)"?' | head -1 | sed 's/,.*//')
  step=$(fm_nm_trim "$step")
  if [ "$state" = failed ] && ! fm_nm_head_matches "$wt" "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")"; then
    # A failed run whose head is not this worktree's line of history describes
    # other work; it must not gate this worktree.
    printf 'none\t\t\n'
    return 0
  fi
  printf '%s\t%s\t%s\n' "$state" "$run_id" "$step"
}
