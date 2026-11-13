#!/usr/bin/env bash
# Fork automatic/manual CI policy, using the upstream suite's expression
# evaluator and YAML execution helpers rather than a duplicate simulator.
set -u

# shellcheck source=tests/fm-ci-workflow.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-ci-workflow.test.sh"

# The fork's automatic events run just the two guards; a full manual call
# restores the same complete inventory the upstream-variable matrix checks.
# A missing repository/full context or a guard mistakenly joining the expensive
# jobs would fail this table rather than silently change the expected job set.
test_fork_automatic_guards_and_manual_full_call() {
  local all event full skip_push skip_macos expected want actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  while read -r event full skip_push skip_macos expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    case "$expected" in
      guards) want=$(printf '%s\n' test-coverage invariants) ;;
      all) want=$all ;;
      none) want= ;;
      all-but-macos) want=$(printf '%s\n' "$all" | grep -vx macos-stock-bash) ;;
      *) fail "unknown fork expectation $expected" ;;
    esac
    actual=$(jobs_running_under event="$event" repository=ironerumi/firstmate head=ironerumi/firstmate \
      full="$full" skip_push="$skip_push" skip_macos="$skip_macos") \
      || fail "could not resolve fork $event full=$full conditions"
    [ "$actual" = "$want" ] \
      || fail "fork $event full=$full must run $expected jobs, got: $actual"
  done <<'TABLE'
push              false - - guards
pull_request      false - - guards
push              false 1 - none
pull_request      false 1 1 guards
workflow_dispatch true  - - all
workflow_dispatch true  1 - all
workflow_dispatch true  - 1 all-but-macos
TABLE
  actual=$(job_runs_under tests-timing-aggregate repository=ironerumi/firstmate head=ironerumi/firstmate needs=failure) \
    || fail "could not resolve fork automatic aggregate"
  [ "$actual" = false ] || fail "the aggregate must not run in a lightweight fork event"
  actual=$(job_runs_under tests-timing-aggregate event=workflow_dispatch repository=ironerumi/firstmate full=true needs=failure) \
    || fail "could not resolve fork full aggregate"
  [ "$actual" = true ] || fail "the full fork aggregate must run even after a failed lane"
  run_full_suite_verdict event=workflow_dispatch repository=ironerumi/firstmate full=true >/dev/null \
    || fail "a passing full fork run must conclude a passing Full suite verdict"
  if run_full_suite_verdict event=workflow_dispatch repository=ironerumi/firstmate full=true needs=failure >/dev/null; then
    fail "a full fork run with a failed lane must conclude a failing Full suite verdict"
  fi
  pass "fork automatic CI retains guards and manual full calls restore all eligible jobs"
}


test_fork_automatic_guards_and_manual_full_call
