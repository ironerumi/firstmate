#!/usr/bin/env bash
# Fork-owned admin-merge and hold-gate cases for bin/fm-pr-merge.sh, migrated
# out of tests/fm-pr-merge.test.sh so the upstream suite stays clean. The
# harness below is the self-contained subset of the upstream fixture set these
# cases use; tests/fm-pr-merge.test.sh owns the upstream suite and its helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-admin-tests)
REAL_MV=$(fm_real_tool mv) || fail "these tests need mv to simulate a failed poll publish"

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  cp "$ROOT/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  # The base branch the forge reports by default: unprotected, with no ruleset
  # rule, so nothing is required unless a case says otherwise.
  write_github_required "$case_dir"
  : > "$case_dir/gh.log"
  # The worktree is a git copy whose HEAD is on a remote-tracking ref, as a
  # pushed ship task's is, so fm-pr-check.sh's named-head gate accepts it when
  # the forge supplies no head (GitLab). No project clone exists on disk.
  printf '%s\n' "$case_dir"
}

write_github_required() {
  local case_dir=$1 spec contexts='' checks='' rules='' protected=false
  shift
  for spec in "$@"; do
    case "$spec" in
      classic:*)
        protected=true
        contexts="${contexts:+$contexts,}\"${spec#classic:}\""
        checks="${checks:+$checks,}{\"context\":\"${spec#classic:}\",\"app_id\":null}"
        ;;
      ruleset:*)
        rules="${rules:+$rules,}{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"${spec#ruleset:}\"}]}}"
        ;;
      *) fail "write_github_required: unknown spec '$spec'" ;;
    esac
  done
  printf '{"name":"main","protected":%s,"protection":{"enabled":%s,"required_status_checks":{"enforcement_level":"%s","contexts":[%s],"checks":[%s]}}}\n' \
    "$protected" "$protected" "$([ "$protected" = true ] && echo non_admins || echo off)" "$contexts" "$checks" \
    > "$case_dir/github-branch.json"
  printf '[{"type":"deletion"}%s]\n' "${rules:+,$rules}" > "$case_dir/github-required-rules.json"
}

write_github_live_json() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  write_github_live_json "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        cat "$FM_TEST_GH_VIEW_JSON"
        if [ -f "${FM_TEST_AWAY_RECORD_AFTER_VIEW:-}" ]; then
          if [ -s "${FM_TEST_AWAY_RECORD_AFTER_VIEW}" ]; then
            cp "$FM_TEST_AWAY_RECORD_AFTER_VIEW" "$FM_STATE_OVERRIDE/.afk-contract"
          else
            rm -f "$FM_STATE_OVERRIDE/.afk-contract"
          fi
        fi
        exit 0
        ;;
      *headRefOid*)
        cat "$FM_TEST_GH_HEAD"
        exit 0
        ;;
      *isDraft*)
        cat "$FM_TEST_GH_VIEW_JSON"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    if [ -n "${FM_TEST_META_AT_MERGE:-}" ] && [ -f "${FM_STATE_OVERRIDE:-}/task-x1.meta" ]; then
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    fi
    # The forge call runs inside the merge's critical section, so a real
    # away-record change attempted from here is the TOCTOU itself: whatever
    # happens to it happens between the authority read and the merge.
    if [ -x "${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" ]; then
      away_rc=0
      "$FM_TEST_AWAY_MUTATE_AT_MERGE" > "$FM_TEST_AWAY_MUTATE_OUT" 2>&1 || away_rc=$?
      printf '%s\n' "$away_rc" > "$FM_TEST_AWAY_MUTATE_RC"
      "$FM_TEST_ROOT/bin/fm-afk-contract.sh" words \
        > "$FM_TEST_AWAY_WORDS_AT_MERGE" 2>/dev/null \
        || printf 'no-live-record\n' > "$FM_TEST_AWAY_WORDS_AT_MERGE"
    fi
    if [ -n "${FM_TEST_GH_MERGE_OUTPUT:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_MERGE_OUTPUT"
    else
      printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    fi
    merge_rc=0
    if [ -f "${FM_TEST_GH_MERGE_RC_FILE:-}" ]; then
      merge_rc=$(cat "$FM_TEST_GH_MERGE_RC_FILE")
    fi
    exit "$merge_rc"
    ;;
  "api graphql")
    if [ -f "${FM_TEST_GH_GRAPHQL_FAIL:-}" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    # The required-check reads: the branch itself, and its rules read without
    # the merge-queue filter the queue reader below applies.
    case " $* " in
      *" repos/"*"/commits/"*"/check-runs"*)
        case "$*" in
          *"/commits/$(cat "$FM_TEST_GH_HEAD")/check-runs"*) ;;
          *) exit 1 ;;
        esac
        cat "$FM_TEST_GH_RUNS"
        exit $?
        ;;
      *" repos/"*"/rules/branches/"*merge_queue*) ;;
      *" repos/"*"/rules/branches/"*)
        if [ -f "${FM_TEST_GH_REQUIRED_RULES_FAIL:-}" ]; then
          cat "$FM_TEST_GH_REQUIRED_RULES_FAIL" >&2
          exit 1
        fi
        cat "$FM_TEST_GH_REQUIRED_RULES"
        exit 0
        ;;
      *" repos/"*"/branches/"*)
        if [ -f "${FM_TEST_GH_BRANCH_FAIL:-}" ]; then
          cat "$FM_TEST_GH_BRANCH_FAIL" >&2
          exit 1
        fi
        cat "$FM_TEST_GH_BRANCH"
        exit 0
        ;;
    esac
    if [ -f "${FM_TEST_GH_RULES_FAIL_BODY:-}" ]; then
      cat "$FM_TEST_GH_RULES_FAIL_BODY" >&2
      exit 1
    fi
    if [ -f "${FM_TEST_GH_RULES_FAIL:-}" ]; then
      exit 1
    fi
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

assert_logged_gh_merge() {
  local case_dir=$1 number=$2 repo=$3 head line extra=
  shift 3
  head=$(cat "$case_dir/github-head")
  [ "$#" -eq 0 ] || extra=" $*"
  line="pr merge $number --repo $repo --match-head-commit $head$extra"
  grep -qxF "$line" "$case_dir/gh.log" \
    || fail "expected gh merge line: $line"$'\n'"got: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_RUNS="$case_dir/github-runs.json" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="$(cat "$case_dir/github-merge-output" 2>/dev/null || true)" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_GH_RULES_FAIL_BODY="$case_dir/github-rules-fail-body" \
  FM_TEST_GH_BRANCH="$case_dir/github-branch.json" \
  FM_TEST_GH_BRANCH_FAIL="$case_dir/github-branch-fail" \
  FM_TEST_GH_REQUIRED_RULES="$case_dir/github-required-rules.json" \
  FM_TEST_GH_REQUIRED_RULES_FAIL="$case_dir/github-required-rules-fail" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$ROOT" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_WORDS_AT_MERGE="$case_dir/away-words-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  HOME="${FM_TEST_USER_HOME:-$case_dir/user-home}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_admin_flag_routes_through_gh() {
  local case_dir head
  case_dir=$(make_case admin-flag)
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks "$case_dir" "$head"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/30 -- --admin \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "admin-flag: fm-pr-merge failed: $(cat "$case_dir/stderr")"

  assert_logged_gh_merge "$case_dir" 30 example/repo --squash --admin
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "admin-flag: gh-axi was invoked for an admin merge"
  assert_grep 'pr=https://github.com/example/repo/pull/30' "$case_dir/state/task-x1.meta" \
    "admin-flag: pr= was not recorded on the admin path"
  assert_grep "pr_head=$head" "$case_dir/state/task-x1.meta" \
    "admin-flag: pr_head= was not recorded on the admin path"
  pass "fm-pr-merge carries the exact --admin invocation through plain gh with metadata recorded"
}

test_admin_variant_refused_before_recording() {
  local case_dir rc
  case_dir=$(make_case admin-variant)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 -- --admin=true \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "admin-variant: fm-pr-merge should refuse --admin=<value>"
  assert_grep 'pass exactly --admin' "$case_dir/stderr" \
    "admin-variant: refusal did not name the exact token"
  assert_no_grep 'pr=https://github.com/example/repo/pull/31' "$case_dir/state/task-x1.meta" \
    "admin-variant: PR was recorded before rejecting the admin variant"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "admin-variant: gh-axi pr merge was invoked despite the refusal"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "admin-variant: gh pr merge was invoked despite the refusal"
  pass "fm-pr-merge refuses near-miss --admin spellings before recording state"
}

test_admin_with_repo_override_refused() {
  local case_dir rc
  case_dir=$(make_case admin-repo-override)
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/32 -- --admin --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "admin-repo-override: fm-pr-merge should refuse repo overrides on the admin path"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "admin-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/32' "$case_dir/state/task-x1.meta" \
    "admin-repo-override: PR was recorded before rejecting the repo override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "admin-repo-override: gh pr merge was invoked despite the repo override"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "admin-repo-override: gh-axi pr merge was invoked despite the repo override"
  pass "fm-pr-merge still refuses repo overrides when --admin is present"
}

test_hold_gate_refuses_until_released() {
  local case_dir home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "SKIP (tasks-axi not found): a held task blocks the merge"
    return
  fi
  case_dir=$(make_case hold-gate)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  home="$case_dir/home"
  (cd "$home" && tasks-axi add task-x1 "sample ship" --repo sample --start) >/dev/null
  (cd "$home" && tasks-axi hold task-x1 --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null

  set +e
  FM_TEST_HOME="$home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "hold-gate: a still-held task must refuse the merge"
  assert_grep 'still held for the captain' "$case_dir/stderr" \
    "hold-gate: the refusal did not name the unreleased captain hold"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "hold-gate: the forge was invoked for a still-held task"

  (cd "$home" && tasks-axi unhold task-x1) >/dev/null
  FM_TEST_HOME="$home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "hold-gate: the merge failed after the hold was released"
  assert_logged_gh_merge "$case_dir" 71 example/repo --squash
  pass "fm-pr-merge refuses a still-held task and merges once the hold is released"
}

test_admin_path_passes_through_the_hold_gate() {
  local case_dir home rc
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "SKIP (tasks-axi not found): the admin path respects the hold gate"
    return
  fi
  case_dir=$(make_case admin-hold-gate)
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  home="$case_dir/home"
  (cd "$home" && tasks-axi add task-x1 "sample ship" --repo sample --start) >/dev/null
  (cd "$home" && tasks-axi hold task-x1 --reason "green PR waiting on the captain to merge" --kind captain) >/dev/null

  set +e
  FM_TEST_HOME="$home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 -- --admin \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "admin-hold-gate: an admin merge of a still-held task must refuse"
  assert_grep 'still held for the captain' "$case_dir/stderr" \
    "admin-hold-gate: the refusal did not name the unreleased captain hold"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "admin-hold-gate: the admin path reached plain gh for a still-held task"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "admin-hold-gate: the gh-axi path was invoked for a still-held task"
  pass "the --admin path refuses a still-held task before reaching the forge"
}

test_admin_flag_routes_through_gh
test_admin_variant_refused_before_recording
test_admin_with_repo_override_refused
test_hold_gate_refuses_until_released
test_admin_path_passes_through_the_hold_gate
