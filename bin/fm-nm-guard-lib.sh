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
# combines that with the run state read by bin/fm-nm-status-lib.sh. It never
# executes the command, and it is deliberately blind to everything that does not
# take ownership away from a live run: inspection, attachment, and the gate
# response path are always allowed, and any command that is not a no-mistakes
# lifecycle call or a git push is not classified at all.
#
# docs/nm-validation-owner-guard.md is the human-readable contract, including the
# per-harness and per-backend reach of the shim transport that calls this.

# shellcheck source=bin/fm-nm-status-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-status-lib.sh"

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
