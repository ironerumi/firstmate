#!/usr/bin/env bash
# fm-nm-guard-lib.sh - the single decision owner for the validation-owner guard.
#
# One live no-mistakes run owns validation for one branch. A worker that starts a
# second run, pushes a superseding commit, or abandons an answerable gate does not
# just waste that run: every completed review, test and documentation step is
# discarded and re-run from the first step, and the diff is larger the second time.
# The measured cost of exactly those three moves was 1,105 minutes of restarted
# pipeline work in one twelve-day window, none of it a review-quality signal.
#
# This library classifies what a worker command WOULD DO to the live run, and
# combines that with the run state it reads from the worktree itself (the run
# read below is folded in from the former bin/fm-nm-status-lib.sh). It never
# executes the command, and it is deliberately blind to everything that does not
# take ownership away from a live run: inspection, attachment, and the gate
# response path are always allowed, and any command that is not a no-mistakes
# lifecycle call or a git push is not classified at all.
#
# docs/nm-validation-owner-guard.md is the human-readable contract, including the
# per-harness and per-backend reach of the shim transport that calls this.

# ---- run read -------------------------------------------------------------
#
# This section is the single owner of reading a no-mistakes run from a
# worktree for this guard: it decides whether a worker command would take
# validation ownership away from a live run. bin/fm-crew-state.sh reads the
# pipeline independently through bin/fm-nm-run-lib.sh, so the two are
# independent readers by design - do not assume a coupling here.
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

# ---- the decision ---------------------------------------------------------

# git global options that take a separate value word, so the word after them is
# never the subcommand.
FM_NM_GUARD_GIT_VALUE_OPTS=' -C -c --git-dir --work-tree --namespace --exec-path --config-env '

# What a command would do to a live run: run, abort, push, or none.
# `none` covers every inspection and continuation path on purpose - axi status,
# axi logs, axi respond, attach, runs, status, doctor, and any git command that
# is not a push.
fm_nm_guard_action() {  # <tool> [args...]
  local tool=$1 arg sub='' axi=0 expect_value=0
  shift
  for arg in "$@"; do
    case "$arg" in
      -h|--help) printf 'none'; return 0 ;;
    esac
  done
  case "$tool" in
    no-mistakes)
      for arg in "$@"; do
        if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
        case "$arg" in
          --skip) expect_value=1; continue ;;
          -*) continue ;;
        esac
        if [ "$axi" -eq 1 ]; then sub=$arg; break; fi
        case "$arg" in
          axi) axi=1; continue ;;
          *) sub=$arg; break ;;
        esac
      done
      case "$axi:$sub" in
        1:run|0:rerun) printf 'run'; return 0 ;;
        1:abort) printf 'abort'; return 0 ;;
      esac
      printf 'none'
      ;;
    git)
      for arg in "$@"; do
        if [ "$expect_value" -eq 1 ]; then expect_value=0; continue; fi
        case "$FM_NM_GUARD_GIT_VALUE_OPTS" in
          *" $arg "*) expect_value=1; continue ;;
        esac
        case "$arg" in
          -*) continue ;;
        esac
        sub=$arg
        break
      done
      if [ "$sub" != push ]; then printf 'none'; return 0; fi
      # A dry run reports what would happen without moving the remote ref, so it
      # cannot supersede anything.
      for arg in "$@"; do
        case "$arg" in
          -n|--dry-run) printf 'none'; return 0 ;;
        esac
      done
      printf 'push'
      ;;
    *) printf 'none' ;;
  esac
}

# 0 when the task's own status file already reports this run id, which is the
# durable record that firstmate has been told about the failure. With no status
# file bound to this session there is nothing to check, so the failure counts as
# reported and the guard stays permissive.
fm_nm_guard_failure_reported() {  # <status-file> <run-id>
  local status_file=$1 run_id=$2
  [ -n "$status_file" ] && [ -f "$status_file" ] || return 0
  [ -n "$run_id" ] || return 0
  grep -qF "$run_id" "$status_file" 2>/dev/null
}

# The decision. Prints `allow`, or `deny<TAB><code><TAB><reason>`.
fm_nm_guard_decide() {  # <action> <state> <run-id> <step> <status-file>
  local action=$1 state=$2 run_id=$3 step=$4 status_file=${5:-} where tab
  tab=$(printf '\t')
  [ "$action" != none ] || { printf 'allow'; return 0; }
  where="run ${run_id:-unknown}"
  [ -z "$step" ] || where="$where at its $step step"
  # shellcheck disable=SC2016  # the refusal text is literal prose; its backticks quote commands for the reader, they never expand.
  case "$state:$action" in
    active:run|parked:run)
      printf 'deny%snm-run-active%sthis branch already has a live no-mistakes run (%s), and starting another one cancels it: every review, test and documentation step it has finished is discarded and re-run from the beginning. Drive the run you have instead - `no-mistakes axi status` to see where it is, `no-mistakes axi logs --step <step>` to read a step, `no-mistakes attach` to reconnect, and `no-mistakes axi respond` to answer the gate it is parked at. If the run cannot be driven forward, report it to firstmate with a blocked line naming the run id and the failing step.' "$tab" "$tab" "$where"
      ;;
    active:push|parked:push)
      printf 'deny%snm-push-supersedes%sthis branch has a live no-mistakes run (%s), and pushing now cancels it as superseded - the whole pipeline restarts on a larger diff. The pipeline pushes the branch itself when it reaches its push step. Let the run finish, or answer its gate with `no-mistakes axi respond`; if it cannot be driven forward, report it to firstmate with a blocked line naming the run id.' "$tab" "$tab" "$where"
      ;;
    parked:abort)
      printf 'deny%snm-abandon-gate%sthe no-mistakes run on this branch (%s) is parked at an answerable gate, and aborting it discards every step it has already completed. Answer the gate with `no-mistakes axi respond` - `no-mistakes axi status` names the gate and its findings. A decision that is not yours to make goes to firstmate as a needs-decision line, not to an abort.' "$tab" "$tab" "$where"
      ;;
    active:abort)
      printf 'deny%snm-abandon-run%sthe no-mistakes run on this branch (%s) is still working, and aborting it discards every step it has already completed. Watch it with `no-mistakes axi status` or `no-mistakes attach`. If it is genuinely stuck, report that to firstmate with a blocked line naming the run id and the step, and let firstmate decide whether to abandon it.' "$tab" "$tab" "$where"
      ;;
    failed:run)
      if fm_nm_guard_failure_reported "$status_file" "$run_id"; then
        printf 'allow'
      else
        printf 'deny%snm-unreported-failure%sthe last no-mistakes run on this branch (%s) ended in failure, and a replacement run would start from the first step with that failure unexplained and unreported. Read it first - `no-mistakes axi status` for the failing step and `no-mistakes axi logs --step <step> --run %s` for its output - then append a blocked line naming run %s and its concrete failure to your status file. Once that failure is recorded this guard allows the replacement run.' "$tab" "$tab" "$where" "${run_id:-<run-id>}" "${run_id:-<run-id>}"
      fi
      ;;
    *)
      # none, terminal, unknown, and every failed-run action other than a
      # replacement run: nothing is holding validation ownership, so a genuinely
      # new run, a push, or an abort is the worker's own call.
      printf 'allow'
      ;;
  esac
}