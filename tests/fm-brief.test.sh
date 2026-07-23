#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  assert_contains "$help" "Ship briefs route review ownership by delivery mode" "fm-brief.sh --help omitted delivery-mode routing"
  assert_contains "$help" "no-mistakes projects always" "fm-brief.sh --help omitted the pipeline-led no-mistakes route"
  assert_contains "$help" "--free-form opts a direct-PR or local-only ship task" "fm-brief.sh --help omitted the free-form opt-out"
  assert_contains "$help" "--no-narration explicitly arms the default-off narration experiment" \
    "fm-brief.sh --help omitted the narration experiment toggle"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- nm-proj [no-mistakes] - fixture for no-mistakes mode (added 2026-07-01)
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" --free-form >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# PR-mode ship briefs must keep the default merge prohibition while carrying
# the one narrowly authorized exception: an exact firstmate-issued
# bin/fm-pr-merge.sh command naming this task. The exception must admit both
# accepted authority forms - an explicit per-PR authorization and an explicit
# standing preference - without weakening the no-self-selection prohibition.
# Local-only briefs stay free of any PR merge channel.
test_ship_briefs_carry_guarded_merge_exception() {
  local home id proj brief
  home="$TMP_ROOT/merge-exception-home"
  write_registry "$home"
  for id_proj in "brief-merge-nm-b1:no-registry-proj" "brief-merge-dp-b2:direct-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" --free-form >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep 'Never merge a PR on your own' "$brief" \
      "$id: brief lost the default merge prohibition"
    # shellcheck disable=SC2016  # Literal backtick-wrapped brief text is the expected value.
    assert_grep 'raw `gh`, `gh-axi pr merge`, API merge calls, direct pushes, and self-selected PRs are all forbidden' "$brief" \
      "$id: brief lost the forbidden merge channels"
    assert_grep "bin/fm-pr-merge.sh $id <PR url>" "$brief" \
      "$id: brief exception does not name the task and canonical PR command"
    assert_grep 'command that firstmate itself sends you; run it verbatim' "$brief" \
      "$id: brief exception is not limited to a firstmate-issued exact command"
    assert_grep 'a per-PR authorization or an explicit standing preference' "$brief" \
      "$id: brief exception does not admit both accepted authority forms"
    assert_grep 'branch protection the only blocker' "$brief" \
      "$id: brief exception lost the authorization conditions"
  done
  id='brief-merge-lo-b3'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_no_grep 'fm-pr-merge.sh' "$brief" "local-only brief gained a PR merge exception"
  assert_grep 'Never push to any remote and never open a PR' "$brief" \
    "local-only brief lost its no-remote rule"
  pass "fm-brief.sh: ship briefs keep the default merge prohibition with the narrow firstmate-issued exception"
}

test_ship_briefs_route_review_ownership_by_delivery_mode() {
  local home id brief lines output status=0
  home="$TMP_ROOT/delivery-mode-routing-home"
  write_registry "$home"

  id="brief-pipeline-led-a4"
  output=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" nm-proj 2>&1)
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "pipeline-led brief was not scaffolded"
  assert_contains "$output" "pipeline-led ship, mode=no-mistakes" \
    "no-mistakes scaffold did not identify the pipeline-led route"
  assert_grep "no-mistakes axi run --help" "$brief" \
    "pipeline-led brief lost the axi-run contract"
  assert_grep "# Project memory" "$brief" \
    "pipeline-led brief lost the full ship safety envelope"
  assert_no_grep "Invoke the named skill exactly as written" "$brief" \
    "pipeline-led brief gave review ownership to a skill"
  assert_no_grep "Do not stack a second workflow or independent review" "$brief" \
    "pipeline-led brief retained the skill-led review-ownership clause"

  id="brief-pipeline-led-free-form-a5"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" nm-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "no-mistakes axi run --help" "$brief" \
    "--free-form changed the no-mistakes pipeline-led route"
  assert_no_grep "Invoke the named skill exactly as written" "$brief" \
    "--free-form resurrected skill-led review ownership on a no-mistakes project"

  for mode_proj in "direct:direct-proj" "local:local-proj"; do
    id="brief-skill-led-${mode_proj%%:*}"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "${mode_proj##*:}" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: skill-led brief was not scaffolded"
    assert_grep "both resolve to this isolated task worktree" "$brief" \
      "$id: skill-led brief lost the isolation assertion"
    assert_grep "Invoke the named skill exactly as written" "$brief" \
      "$id: skill-led brief did not delegate mechanics to the owning skill"
    assert_grep "Do not stack a second workflow or independent review" "$brief" \
      "$id: skill-led brief allowed a duplicate workflow"
    assert_grep "Never discard, reset, or hide unlanded work" "$brief" \
      "$id: skill-led brief lost unlanded-work protection"
    assert_grep "Merge only when the task text explicitly grants that authority" "$brief" \
      "$id: skill-led brief lost explicit merge authority"
    assert_grep "corrected document path, ready branch, or full green PR URL" "$brief" \
      "$id: skill-led brief did not require a concrete terminal artifact"
    assert_no_grep "no-mistakes doctor" "$brief" \
      "$id: skill-led brief stacked the standard no-mistakes setup"
    assert_no_grep "# Project memory" "$brief" \
      "$id: skill-led brief retained the full ship template"
    lines=$(wc -l < "$brief" | tr -d ' ')
    [ "$lines" -le 45 ] || fail "$id: skill-led brief is not concise ($lines lines, expected at most 45)"
  done

  id="brief-free-form-a6"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "# Project memory" "$brief" \
    "--free-form direct-PR ship did not preserve the full ship body"
  assert_no_grep "Do not stack a second workflow or independent review" "$brief" \
    "--free-form direct-PR ship retained the skill-led anti-stack clause"
  assert_no_grep "narration_arm:" "$brief" \
    "--free-form direct-PR ship gained a pipeline-only experiment marker"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" bad-scout some-proj --scout --free-form >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--free-form combined with --scout must fail"
  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x "$ROOT/bin/fm-brief.sh" bad-mate --secondmate --no-projects --free-form >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--free-form combined with --secondmate must fail"
  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" removed-flag some-proj --skill-led >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "removed --skill-led flag must be rejected as unknown"
  pass "fm-brief.sh: ship briefs route review ownership by delivery mode"
}

test_pipeline_narration_arm_is_explicit_and_diff_bounded() {
  local off_home on_home state id off_brief on_brief diff changes status=0
  off_home="$TMP_ROOT/narration-off-home"
  on_home="$TMP_ROOT/narration-on-home"
  state="$TMP_ROOT/narration-shared-state"
  id="brief-narration-arm-a7"
  write_registry "$off_home"
  write_registry "$on_home"
  mkdir -p "$state"

  FM_HOME="$off_home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-brief.sh" "$id" nm-proj >/dev/null 2>&1
  FM_HOME="$on_home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-brief.sh" "$id" nm-proj --no-narration >/dev/null 2>&1
  off_brief="$off_home/data/$id/brief.md"
  on_brief="$on_home/data/$id/brief.md"
  diff="$TMP_ROOT/narration-arm.diff"

  [ "$(grep -c '^narration_arm: off$' "$off_brief")" -eq 1 ] \
    || fail "default pipeline-led brief did not carry exactly one off marker"
  assert_no_grep "No-narration experiment arm" "$off_brief" \
    "default pipeline-led brief enabled the clause without an explicit toggle"
  [ "$(grep -c '^narration_arm: on$' "$on_brief")" -eq 1 ] \
    || fail "toggled pipeline-led brief did not carry exactly one on marker"
  assert_grep "emit only status signals and the pipeline's required output; no meta-commentary between tool calls" "$on_brief" \
    "toggled pipeline-led brief did not carry the no-narration clause"

  diff -u "$off_brief" "$on_brief" > "$diff" || status=$?
  expect_code 1 "$status" "the on/off narration scaffolds must differ"
  changes=$(grep -Ec '^[+-][^+-]' "$diff")
  [ "$changes" -eq 3 ] \
    || fail "narration arm changed $changes lines; expected only marker replacement plus clause insertion"
  grep -qxF -- '-narration_arm: off' "$diff" \
    || fail "narration arm diff did not remove only the off marker"
  grep -qxF -- '+narration_arm: on' "$diff" \
    || fail "narration arm diff did not add the on marker"
  grep -qxF -- "+1a. No-narration experiment arm: emit only status signals and the pipeline's required output; no meta-commentary between tool calls." "$diff" \
    || fail "narration arm diff did not add the exact clause"
  pass "fm-brief.sh: narration arm is default-off, explicit, marked, and diff-bounded"
}

test_no_narration_rejects_non_pipeline_briefs() {
  local home status
  home="$TMP_ROOT/narration-misuse-home"
  write_registry "$home"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" narration-direct direct-proj --no-narration >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--no-narration on direct-PR must fail"
  assert_absent "$home/data/narration-direct/brief.md" "rejected direct-PR toggle still wrote a brief"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" narration-scout nm-proj --scout --no-narration >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--no-narration on a scout must fail"
  assert_absent "$home/data/narration-scout/brief.md" "rejected scout toggle still wrote a brief"

  status=0
  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops \
    "$ROOT/bin/fm-brief.sh" narration-mate --secondmate --no-projects --no-narration >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--no-narration on a secondmate charter must fail"
  assert_absent "$home/data/narration-mate/brief.md" "rejected secondmate toggle still wrote a brief"
  pass "fm-brief.sh: no non-pipeline brief can enable the narration experiment"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --free-form >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --free-form >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'or a blocker clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

# Provenance stamping (--source/--batch): defaults, explicit values, and the
# batch sentinel. Every scaffolded variant carries exactly one well-formed
# `source:` + `batch_id:` pair for the kaizen batch scanner.
test_provenance_defaults_to_human_and_unknown() {
  local home id brief
  home="$TMP_ROOT/provenance-default-home"
  mkdir -p "$home/data"
  id="brief-provenance-default-e1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "source: human" "$brief" \
    "ship brief without --source must default to source: human"
  assert_grep "batch_id: unknown" "$brief" \
    "ship brief without --batch must default to the unknown sentinel"
  pass "fm-brief.sh: provenance defaults to source: human / batch_id: unknown"
}

test_provenance_explicit_values_stamp_ship_brief() {
  local home id brief
  home="$TMP_ROOT/provenance-explicit-home"
  mkdir -p "$home/data"
  id="brief-provenance-explicit-e2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --source firstmate --batch wave-42 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "source: firstmate" "$brief" \
    "ship brief did not stamp explicit --source firstmate"
  assert_grep "batch_id: wave-42" "$brief" \
    "ship brief did not stamp explicit --batch wave-42"
  pass "fm-brief.sh: explicit --source/--batch stamp the ship brief"
}

test_provenance_stamps_all_variants() {
  local home brief
  home="$TMP_ROOT/provenance-variants-home"
  write_registry "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-ship-e3 nm-proj --source firstmate --batch wave-e3 >/dev/null 2>&1
  brief="$home/data/prov-ship-e3/brief.md"
  assert_grep "source: firstmate" "$brief" "pipeline-led ship variant missing source: stamp"
  assert_grep "batch_id: wave-e3" "$brief" "pipeline-led ship variant missing batch_id: stamp"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-scout-e3 alpha --scout --source firstmate --batch wave-e3 >/dev/null 2>&1
  brief="$home/data/prov-scout-e3/brief.md"
  assert_grep "source: firstmate" "$brief" "scout variant missing source: stamp"
  assert_grep "batch_id: wave-e3" "$brief" "scout variant missing batch_id: stamp"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops' \
    "$ROOT/bin/fm-brief.sh" prov-sm-e3 --secondmate --no-projects --source firstmate --batch wave-e3 >/dev/null 2>&1
  brief="$home/data/prov-sm-e3/brief.md"
  assert_grep "source: firstmate" "$brief" "secondmate variant missing source: stamp"
  assert_grep "batch_id: wave-e3" "$brief" "secondmate variant missing batch_id: stamp"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-skill-led-e3 direct-proj --source firstmate --batch wave-e3 >/dev/null 2>&1
  brief="$home/data/prov-skill-led-e3/brief.md"
  assert_grep "source: firstmate" "$brief" "skill-led variant missing source: stamp"
  assert_grep "batch_id: wave-e3" "$brief" "skill-led variant missing batch_id: stamp"

  pass "fm-brief.sh: ship, scout, secondmate, and skill-led variants all stamp source/batch_id"
}

test_provenance_validation_rejects_malformed_input() {
  local home status
  home="$TMP_ROOT/provenance-validation-home"
  mkdir -p "$home/data"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-bad-source alpha --source bogus >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--source with an invalid value must fail"
  assert_absent "$home/data/prov-bad-source/brief.md" "rejected --source still wrote a brief"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-missing-source alpha --source >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--source with no value must fail"
  assert_absent "$home/data/prov-missing-source/brief.md" "value-less --source still wrote a brief"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-missing-batch alpha --batch >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--batch with no value must fail"
  assert_absent "$home/data/prov-missing-batch/brief.md" "value-less --batch still wrote a brief"

  status=0
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" prov-empty-batch alpha --batch "" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "--batch with an empty value must fail"
  assert_absent "$home/data/prov-empty-batch/brief.md" "empty --batch still wrote a brief"

  pass "fm-brief.sh: malformed or missing --source/--batch values are rejected"
}

test_provenance_preserves_existing_template_body() {
  local home id brief
  home="$TMP_ROOT/provenance-template-home"
  mkdir -p "$home/data"
  id="brief-provenance-template-e5"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --free-form --source firstmate --batch wave-e5 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "# Definition of done" "$brief" "provenance flags regressed the Definition of done section"
  assert_grep "{TASK}" "$brief" "provenance flags regressed the {TASK} placeholder"
  assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "provenance flags regressed the unguarded Herdr declaration"
  assert_grep "# Project memory" "$brief" \
    "provenance flags regressed the project-memory section"
  assert_grep "Never merge a PR on your own" "$brief" \
    "provenance flags regressed the default merge prohibition"
  assert_no_grep "EOF" "$brief" "provenance flags left a leaked heredoc EOF marker"
  pass "fm-brief.sh: --source/--batch stamping does not regress the existing template body"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_ship_briefs_carry_guarded_merge_exception
test_ship_briefs_route_review_ownership_by_delivery_mode
test_pipeline_narration_arm_is_explicit_and_diff_bounded
test_no_narration_rejects_non_pipeline_briefs
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_provenance_defaults_to_human_and_unknown
test_provenance_explicit_values_stamp_ship_brief
test_provenance_stamps_all_variants
test_provenance_validation_rejects_malformed_input
test_provenance_preserves_existing_template_body
