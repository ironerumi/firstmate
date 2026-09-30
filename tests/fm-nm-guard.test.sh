#!/usr/bin/env bash
# tests/fm-nm-guard.test.sh - acceptance matrix for the validation-owner guard.
#
# Covers the contract in docs/nm-validation-owner-guard.md: which worker commands
# are refused while one no-mistakes run owns validation of a branch, which are
# always permitted, how a terminally failed run is recovered, that a genuinely
# new run after a terminal one is never interfered with, and that every failure
# to read the pipeline execs the real tool instead of refusing work.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-nm-guard)
REPO="$TMP/repo"
REMOTE="$TMP/remote.git"
FAKEBIN=$(fm_fakebin "$TMP")
STATUS_FILE="$TMP/task.status"
NM_FAKE_LOG="$TMP/nm.log"
NM_FAKE_STATUS="$TMP/nm-status.toon"
NM_FAKE_REVIEW_LOG="$TMP/nm-review.log"
SHIMS="$ROOT/bin/shims"

fm_git_identity
fm_git_init_commit "$REPO"
fm_git_add_origin "$REPO" "$REMOTE"
git -C "$REPO" checkout -q -b fm/task-x
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NM_FAKE_LOG"
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  [ -f "$NM_FAKE_STATUS" ] && cat "$NM_FAKE_STATUS"
elif [ "${1:-}" = axi ] && [ "${2:-}" = logs ]; then
  [ -f "$NM_FAKE_REVIEW_LOG" ] && cat "$NM_FAKE_REVIEW_LOG"
fi
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"

export NM_FAKE_LOG NM_FAKE_STATUS NM_FAKE_REVIEW_LOG
: > "$STATUS_FILE"
export FM_NM_GUARD_STATUS=$STATUS_FILE
export PATH="$SHIMS:$FAKEBIN:$PATH"

# --- fixtures ---------------------------------------------------------------

set_run() {  # <status-word> <run-id> [step-row] [head]
  local status=$1 id=$2 row=${3:-'    review,running,0,120'} head=${4:-$HEAD_SHA}
  cat > "$NM_FAKE_STATUS" <<EOF
run:
  id: "$id"
  branch: fm/task-x
  status: $status
  head: $head
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,10
$row
EOF
}

no_run() {
  cat > "$NM_FAKE_STATUS" <<EOF
run:
  id: "01OTHER"
  branch: fm/some-other-branch
  status: running
  head: $HEAD_SHA
EOF
}

# The run's review step log records one `user-fix round starting after round N`
# line per fix round the user advanced. The first line keeps a readable log with
# zero rounds distinguishable from an unreadable one.
set_review_rounds() {  # <n>
  local n=$1 i=1
  printf 'reviewing changes...\n' > "$NM_FAKE_REVIEW_LOG"
  while [ "$i" -le "$n" ]; do
    printf 'user-fix round starting after round %s (1 finding selected)\n' "$i" >> "$NM_FAKE_REVIEW_LOG"
    i=$((i + 1))
  done
}

run_in_repo() {  # <cmd...>  -> sets OUT/CODE
  OUT=$( (cd "$REPO" && "$@") 2>&1 )
  CODE=$?
}

assert_refused() {  # <code-token> <label>
  expect_code 3 "$CODE" "$2"
  assert_contains "$OUT" "REFUSED BY FIRSTMATE" "$2 must render the refusal banner"
  assert_contains "$OUT" "[$1]" "$2 must carry the $1 code"
}

assert_allowed() {  # <label>
  assert_not_contains "$OUT" "REFUSED BY FIRSTMATE" "$1 must not be refused"
  [ "$CODE" != 3 ] || fail "$1 must not exit with the refusal status"
}

nm_called_with() {  # <exact arg string>
  grep -qxF "$1" "$NM_FAKE_LOG" 2>/dev/null
}

# --- 1. a live run refuses every command that would take ownership ----------

set_run running 01LIVE
: > "$NM_FAKE_LOG"

run_in_repo no-mistakes axi run
assert_refused nm-run-active "a second axi run under a live run"
nm_called_with "axi run" && fail "the refused run must never reach the real binary"
pass "a second axi run is refused while a run is live"

run_in_repo no-mistakes rerun
assert_refused nm-run-active "rerun under a live run"
pass "rerun is refused while a run is live"

run_in_repo no-mistakes axi abort
assert_refused nm-abandon-run "abort of a working run"
assert_contains "$OUT" "01LIVE" "the refusal names the run id"
pass "aborting a working run is refused and names the run"

run_in_repo git push origin fm/task-x
assert_refused nm-push-supersedes "push under a live run"
pass "a superseding push is refused while a run is live"

# --- 2. inspection, reconnection and the gate response path stay open -------

for probe in "axi status" "axi logs --step review" "attach" "runs --limit 5" "status" "doctor"; do
  # shellcheck disable=SC2086 # deliberate word splitting of the probe argument list
  run_in_repo no-mistakes $probe
  assert_allowed "no-mistakes $probe under a live run"
done
pass "inspection and reconnection stay permitted under a live run"

run_in_repo no-mistakes axi respond --action fix --findings 1,2
assert_allowed "axi respond under a live run"
nm_called_with "axi respond --action fix --findings 1,2" \
  || fail "axi respond must reach the real binary with its arguments intact"
pass "the axi respond continuation path is permitted and passes arguments through"

run_in_repo no-mistakes axi run --help
assert_allowed "axi run --help under a live run"
pass "help for a refused subcommand stays readable"

# --- 3. unrelated commands are never touched --------------------------------

for probe in status log "diff --stat" "rev-parse HEAD"; do
  # shellcheck disable=SC2086 # deliberate word splitting of the probe argument list
  run_in_repo git $probe
  assert_allowed "git $probe under a live run"
done
run_in_repo git commit --allow-empty -m "push the work forward"
assert_allowed "a commit whose message mentions push"
run_in_repo git push --dry-run origin fm/task-x
assert_allowed "a dry-run push under a live run"
pass "unrelated git commands and dry-run pushes are never refused"
git -C "$REPO" reset -q --hard HEAD~1

# --- 4. a parked gate is refused as an abandoned gate ------------------------

set_run running 01PARKED '    review,awaiting_approval,3,900'
run_in_repo no-mistakes axi abort
assert_refused nm-abandon-gate "abort of a parked run"
assert_contains "$OUT" "axi respond" "the refusal names the continuation path"
pass "abandoning an answerable gate is refused and points at the gate response"

run_in_repo no-mistakes axi respond --action approve
assert_allowed "axi respond at a parked gate"
pass "the parked gate can still be answered"

# --- 5. a terminally failed run: evidence first, then recovery --------------

set_run failed 01FAILED '    push,failed,0,300'
run_in_repo no-mistakes axi run
assert_refused nm-unreported-failure "a replacement run after an unreported failure"
assert_contains "$OUT" "01FAILED" "the refusal names the failed run"
assert_contains "$OUT" "axi logs" "the refusal names the command that preserves the evidence"
pass "a replacement run after an unreported failure is refused with the evidence path"

printf 'blocked: run 01FAILED failed at its push step\n' >> "$STATUS_FILE"
run_in_repo no-mistakes axi run
assert_allowed "a replacement run after the failure was reported"
nm_called_with "axi run" || fail "the reported-failure replacement run must reach the real binary"
pass "recording the failure clears the refusal"

# A failed run on another line of history does not gate this worktree.
set_run failed 01ELSEWHERE '    push,failed,0,300' 0000000000000000000000000000000000000000
: > "$STATUS_FILE"
run_in_repo no-mistakes axi run
assert_allowed "a failed run whose head is not this worktree's history"
pass "a failed run outside this worktree's history never gates it"

# A gate row in the steps table promotes an ACTIVE run to parked and nothing
# else: a run that ended at its gate is finished, not answerable, so it must keep
# the terminal behaviour its own status word states.
set_run cancelled 01CANCELGATE '    review,awaiting_approval,3,900'
: > "$STATUS_FILE"
: > "$NM_FAKE_LOG"
run_in_repo no-mistakes axi run
assert_refused nm-unreported-failure "a replacement run after a cancellation at a gate"
nm_called_with "axi run" && fail "the refused run must never reach the real binary"
run_in_repo no-mistakes axi abort
assert_allowed "an abort of a run already cancelled at its gate"
printf 'blocked: run 01CANCELGATE cancelled at its review gate\n' >> "$STATUS_FILE"
run_in_repo no-mistakes axi run
assert_allowed "a replacement run once the cancellation was reported"
pass "a run cancelled at a gate stays terminal and clears through the reporting path"

set_run failed 01GATEELSEWHERE '    review,fix_review,2,400' 0000000000000000000000000000000000000000
: > "$STATUS_FILE"
run_in_repo no-mistakes axi run
assert_allowed "a failed run at a gate outside this worktree's history"
pass "a gate row never bypasses the failed-run code-identity test"

set_run harvesting 01UNKNOWNGATE '    review,awaiting_approval,3,900'
: > "$NM_FAKE_LOG"
run_in_repo no-mistakes axi run
assert_allowed "an unrecognized run word carrying a gate row"
nm_called_with "axi run" || fail "an unrecognized run word must exec the real tool"
run_in_repo git push origin fm/task-x
assert_allowed "a push under an unrecognized run word carrying a gate row"
pass "an unrecognized run word stays permissive even with a gate row"

# --- 6. a conclusively terminal run never blocks the next one ---------------

set_run completed 01DONE '    ci,completed,0,600'
run_in_repo no-mistakes axi run
assert_allowed "a new run after a completed run"
set_run completed 01DONEGATE '    review,awaiting_approval,0,900'
run_in_repo no-mistakes axi run
assert_allowed "a new run after a completed run whose steps table kept a gate row"
set_run completed 01DONE '    ci,completed,0,600'
run_in_repo git push origin fm/task-x
assert_allowed "a push after a completed run"
pass "a genuinely new run and push after a terminal run are not interfered with"

# --- 7. no run attributed to this branch ------------------------------------

no_run
run_in_repo no-mistakes axi run
assert_allowed "a run when another branch holds the only run"
run_in_repo no-mistakes axi abort
assert_allowed "an abort when another branch holds the only run"
pass "another branch's run never gates this one"

# A scout worktree sits at a detached HEAD and drives no validation of its own.
git -C "$REPO" checkout -q --detach
set_run running 01LIVE
run_in_repo no-mistakes axi run
assert_allowed "a detached-HEAD worktree with no branch to attribute"
git -C "$REPO" checkout -q fm/task-x
pass "a task with no branch of its own is never gated"

# --- 8. fail open, and the deliberate escape --------------------------------

set_run running 01LIVE
printf 'not toon at all\n' > "$NM_FAKE_STATUS"
run_in_repo git push origin fm/task-x
assert_allowed "an unreadable pipeline answer"
pass "an unreadable pipeline answer fails open"

set_run running 01LIVE
OUT=$( (cd "$REPO" && PATH="$SHIMS:$(dirname "$(fm_real_tool git)")" git push origin fm/task-x) 2>&1 )
CODE=$?
assert_allowed "a push with no no-mistakes binary reachable"
pass "an absent no-mistakes binary fails open"

set_run running 01LIVE
OUT=$( (cd "$REPO" && FM_NM_GUARD_ALLOW=1 no-mistakes axi run) 2>&1 )
CODE=$?
assert_allowed "the authorized escape"
pass "FM_NM_GUARD_ALLOW=1 allows an authorized recovery"

# --- 9. the review fix-round budget -----------------------------------------

# The count comes from the run's own review step log. Rounds 1-3 are allowed,
# the fourth is refused with the batch-decision path, and every uncertainty
# stays permissive.
set_run running 01LIVE '    review,fix_review,2,400'
: > "$NM_FAKE_LOG"
set_review_rounds 0
run_in_repo no-mistakes axi respond --action fix --findings 1
assert_allowed "the first review fix response"
nm_called_with "axi respond --action fix --findings 1" \
  || fail "an allowed review fix response must reach the real binary"
for rounds in 1 2; do
  set_review_rounds "$rounds"
  run_in_repo no-mistakes axi respond --action fix --findings 1
  assert_allowed "review fix round $rounds under the budget"
done
pass "a review fix response before the budget is allowed"

set_review_rounds 3
: > "$NM_FAKE_LOG"
run_in_repo no-mistakes axi respond --action fix --findings 1
assert_refused nm-review-budget "a fourth review fix response"
assert_contains "$OUT" "needs-decision" "the refusal must route the leftovers to firstmate"
assert_contains "$OUT" "dismiss" "the refusal must name the dismissal disposition"
assert_contains "$OUT" "attach" "the refusal must name the attach disposition"
assert_contains "$OUT" "FM_NM_GUARD_REVIEW_UNLOCK=1" "the refusal must name the per-run unlock"
nm_called_with "axi respond --action fix --findings 1" && fail "the refused response must never reach the real binary"
pass "the fourth review fix response is refused with the batch-decision path"

OUT=$( (cd "$REPO" && FM_NM_GUARD_REVIEW_UNLOCK=1 no-mistakes axi respond --action fix --findings 1) 2>&1 )
CODE=$?
assert_allowed "the per-run unlock"
nm_called_with "axi respond --action fix --findings 1" || fail "the unlock must exec the real tool"
pass "FM_NM_GUARD_REVIEW_UNLOCK=1 permits one authorized further round"

# Only a review fix response is budgeted: another step's fix, and approve or
# skip anywhere, are untouched.
set_run running 01LIVE '    test,awaiting_approval,2,400'
set_review_rounds 3
run_in_repo no-mistakes axi respond --action fix --findings 1
assert_allowed "a fix response at the test gate past the budget"
set_run running 01LIVE '    review,fix_review,2,400'
run_in_repo no-mistakes axi respond --action approve
assert_allowed "approve at a review gate past the budget"
run_in_repo no-mistakes axi respond --action skip
assert_allowed "skip at a review gate past the budget"
pass "the budget refuses only a review fix response"

# An unreadable round count does not refuse; the shim reports the gap.
: > "$NM_FAKE_REVIEW_LOG"
run_in_repo no-mistakes axi respond --action fix --findings 1
assert_allowed "a review fix response with no readable round count"
assert_contains "$OUT" "was not applied" "the shim must report the unreadable round count"
pass "an unreadable review round count fails open and is reported"

# --- 10. classification and decision units ----------------------------------

# shellcheck disable=SC1091
. "$ROOT/bin/fm-nm-guard-lib.sh"

check_action() {  # <expected> <tool> <args...>
  local expected=$1 got
  shift
  got=$(fm_nm_guard_action "$@")
  [ "$got" = "$expected" ] || fail "action for '$*': expected $expected, got $got"
}

check_action run no-mistakes axi run
check_action run no-mistakes --skip lint axi run
check_action run no-mistakes rerun
check_action abort no-mistakes axi abort
check_action none no-mistakes axi status
check_action review-fix no-mistakes axi respond --action fix
check_action review-fix no-mistakes axi respond --action fix --findings 1,2
check_action review-fix no-mistakes axi respond --action=fix
check_action none no-mistakes axi respond --action approve
check_action none no-mistakes axi respond --action skip
check_action none no-mistakes axi respond
check_action none no-mistakes axi respond --findings 1
check_action none no-mistakes axi logs --step review --full
check_action none no-mistakes attach
check_action none no-mistakes axi run --help
check_action push git push
check_action push git -C /tmp push --force
check_action none git push --dry-run
check_action none git status
check_action none git commit -m "push"
check_action none rg push
pass "argv classification is exact for every documented shape"

check_decision() {  # <expected-prefix> <action> <state> <label>
  local out
  out=$(fm_nm_guard_decide "$2" "$3" 01X review "")
  case "$out" in
    "$1"*) : ;;
    *) fail "$4: expected $1, got $out" ;;
  esac
}

check_decision allow none active "no action is always allowed"
check_decision deny run active "a run under an active run denies"
check_decision deny run parked "a run under a parked run denies"
check_decision allow run terminal "a run after a terminal run allows"
check_decision allow run unknown "a run under an unreadable state allows"
check_decision allow run none "a run with no attributed run allows"
check_decision allow push terminal "a push after a terminal run allows"
check_decision allow abort none "an abort with no attributed run allows"
pass "the decision table matches the documented contract"

check_review_decision() {  # <expected-prefix> <rounds> <label>
  local out
  out=$(fm_nm_guard_decide review-fix parked 01X review "" "$2")
  case "$out" in
    "$1"*) : ;;
    *) fail "$3: expected $1, got $out" ;;
  esac
}

check_review_decision allow 0 "a review fix with no completed rounds is allowed"
check_review_decision allow 2 "the third review fix round is allowed"
check_review_decision deny 3 "the fourth review fix round is refused"
check_review_decision allow "" "an unreadable round count fails open"
out=$(fm_nm_guard_decide review-fix parked 01X test "" 3)
[ "$out" = allow ] || fail "the budget must not apply to a non-review step, got: $out"
out=$(FM_NM_GUARD_REVIEW_UNLOCK=1 fm_nm_guard_decide review-fix parked 01X review "" 3)
[ "$out" = allow ] || fail "the per-run unlock must allow a fourth round, got: $out"
pass "the review fix-round budget decision matches the documented contract"

# --- 10b. a refusal reports itself -------------------------------------------

# Every refusal appends one keyed blocked line, so firstmate learns of it even
# when the worker routes around it, and a retry loop cannot flood the record.
set_run running 01REPORT
: > "$STATUS_FILE"
for _ in 1 2 3; do run_in_repo no-mistakes axi run; done
assert_refused nm-run-active "a repeated duplicate run"
[ "$(grep -c '^blocked .*\[key=guard-nm-run-active\]' "$STATUS_FILE")" = 1 ] \
  || fail "three identical refusals must leave exactly one open report: $(cat "$STATUS_FILE")"
assert_contains "$(cat "$STATUS_FILE")" "guard refused no-mistakes" "the report names the refused tool"
pass "a refusal appends one keyed blocked line, idempotent per refusal code"

printf 'resolved [at=1] [key=guard-nm-run-active]: firstmate answered\n' >> "$STATUS_FILE"
run_in_repo no-mistakes axi run
[ "$(grep -c '^blocked .*\[key=guard-nm-run-active\]' "$STATUS_FILE")" = 2 ] \
  || fail "a refusal after the report was resolved must report again: $(cat "$STATUS_FILE")"
pass "a resolved refusal report re-opens on the next refusal"

# The report must never satisfy a guard that reads the record: the failed-run
# refusal stays in force because the report does not name the run.
set_run failed 01REPORTFAIL '    push,failed,0,300'
: > "$STATUS_FILE"
run_in_repo no-mistakes axi run
assert_refused nm-unreported-failure "a replacement run after an unreported failure"
run_in_repo no-mistakes axi run
assert_refused nm-unreported-failure "a second replacement run after the guard's own report"
assert_not_contains "$(cat "$STATUS_FILE")" "01REPORTFAIL" "the report must not echo the run id the guard looks for"
pass "the guard's own report cannot count as the worker's failure report"

# An unset status file is a quiet no-op: the refusal still stands.
set_run running 01NORECORD
( unset FM_NM_GUARD_STATUS; cd "$REPO" && no-mistakes axi run ) >/dev/null 2>&1
expect_code 3 $? "a refusal without a status record must still refuse"
pass "a refusal without a status record still refuses"

# --- 11. reach: one wiring line, every harness and every backend -------------

# The shims reach a worker through the pane environment rather than a per-harness
# hook, which is what makes the coverage complete. bin/fm-worker-env-lib.sh owns
# that environment and tests/fm-worker-env-composition.test.sh runs the whole
# worker environment, while tests/fm-backend-orca.test.sh proves the line reaches
# a non-default backend end to end.
# shellcheck source=bin/fm-worker-env-lib.sh
. "$ROOT/bin/fm-worker-env-lib.sh"
WORKER_LINE=$(fm_worker_guard_export_line "$TMP/state dir" t1 "$ROOT/bin")
WORKER_ENV=$(env -i PATH=/usr/bin:/bin bash -c "$WORKER_LINE; printf '%s\n' \"\$FM_NM_GUARD_STATUS\" \"\$FM_WORKTREE_GUARD_META\" \"\$PATH\"")
[ "$(printf '%s\n' "$WORKER_ENV" | sed -n 1p)" = "$TMP/state dir/t1.status" ] \
  || fail "the export must bind the guard to this task's status file"
[ "$(printf '%s\n' "$WORKER_ENV" | sed -n 2p)" = "$TMP/state dir/t1.meta" ] \
  || fail "the export must bind the guard to this task's durable record"
[ "$(printf '%s\n' "$WORKER_ENV" | sed -n 3p)" = "$ROOT/bin/shims:/usr/bin:/bin" ] \
  || fail "the export must prepend the shim directory rather than replace PATH"
pass "fm-spawn wires the shims once, through the backend-agnostic pane environment"

for tool in no-mistakes git; do
  [ -L "$SHIMS/$tool" ] || fail "$SHIMS/$tool must be a symlink to the one shim owner"
  [ -x "$SHIMS/$tool" ] || fail "$SHIMS/$tool must be executable"
  [ "$(readlink "$SHIMS/$tool")" = "../fm-nm-guard-shim.sh" ] \
    || fail "$SHIMS/$tool must resolve to bin/fm-nm-guard-shim.sh"
done
pass "both shims are one owner reached under two names"

pass "fm-nm-guard.test.sh"
