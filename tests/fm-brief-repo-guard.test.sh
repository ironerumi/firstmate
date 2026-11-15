#!/usr/bin/env bash
# Tests for bin/fm-brief-repo-guard.sh, the fork-added wrapper that appends
# fork-local sections to worker briefs scaffolded by bin/fm-brief.sh.
#
# Matrix:
#   (a) a Firstmate-repo secondmate charter is byte-identical to a raw scaffold
#   (b) Firstmate-repo ship and scout briefs gain the boundary exactly once
#   (c) a non-firstmate ship brief, in every mode, equals a raw scaffold plus
#       only the falsification section; a non-firstmate scout brief is
#       byte-identical to a raw scaffold
#   (d) a same-named project with a foreign origin gets no boundary
#   (e) equivalent supported origin spellings identify the Firstmate repo
#   (f) --port appends the porting contract to a ship brief and nothing else
#   (g) a Firstmate-repo ship brief orders falsification, porting contract,
#       boundary; a Firstmate-repo scout brief carries only the boundary
#   (h) --port on a scout or secondmate scaffold is refused before scaffolding
#   (i) a failing scaffold appends nothing
#   (j) a backlog row's whip intent block lands under ## Captain's intent for
#       ship briefs (any target) and scout briefs, once
#   (k) no row, or a row without a begin marker, changes nothing; a secondmate
#       charter is untouched
#   (l) a malformed block or a failing backlog read exits non-zero, naming the
#       row and the fault, and inserts nothing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-brief-repo-guard.sh"
RAW="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-brief-repo-guard-tests)

# Build one case dir with a data root, a state root, and a fake code root whose
# basename is <root_name>. Cases can add origins when exercising the wrapper's
# origin-authoritative detection; otherwise the basename is its final fallback.
# Echoes the case dir.
make_case() {
  local name=$1 root_name=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/data" "$case_dir/home/state" "$case_dir/fmroot/$root_name"
  printf '%s\n' "$case_dir"
}

# run_brief <case_dir> <script> <task-id> <repo> <extra args...>: scaffold one
# brief with FM_DATA_OVERRIDE/FM_STATE_OVERRIDE pointed at the case so both the
# raw and the wrapped run write their artifact under identical absolute paths.
run_brief() {
  local case_dir=$1 script=$2 root_name=$3
  shift 3
  FM_ROOT_OVERRIDE="$case_dir/fmroot/$root_name" FM_HOME="$case_dir/fmroot/$root_name" \
    FM_DATA_OVERRIDE="$case_dir/home/data" FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$script" "$@"
}

# The section bodies the guard must append, verbatim from the issue.
FALSIFICATION_BODY='For every gate a change ADDS or MODIFIES — a test, CI job, route manifest, lint/coverage rule, alarm — demonstrate it can FAIL: show it red against a deliberate violation, then restore and show it green. A falsification that fails to fail is a COVERAGE HOLE to close, not a pass.'
PORT_BODY='- Never retype oracle constants. Extract rule tables / regex alternations / enum maps mechanically (AST or introspection dump) and convert programmatically; record the extraction script in the PR. Ported tests usually derive from the same retyped source, so retyping is a silent-corruption channel no test catches.
- Sweep the cross-language seam: Python \d/\w/\s are Unicode-aware, JS'"'"'s are ASCII-only; re.sub replaces all, .replace() without g replaces first.
- Corpus bar: generate inputs covering every literal alternative in every table; diff oracle vs port byte-exact.'

# heading_count <brief> <heading>: number of lines equal to "## <heading>".
heading_count() {
  grep -c -Fx "## $2" "$1" || true
}

# section_body <brief> <heading>: the lines between "## <heading>" and the next
# heading of level one or two, without leading or trailing blank lines.
section_body() {
  awk -v h="## $2" '
    $0 == h { on = 1; next }
    on && /^##? / { exit }
    on { buf[++n] = $0 }
    END {
      first = 1; while (first <= n && buf[first] == "") first++
      last = n; while (last >= first && buf[last] == "") last--
      for (i = first; i <= last; i++) print buf[i]
    }
  ' "$1"
}

# expect_section <brief> <heading> <body> <label>: exactly one such section,
# with exactly that body.
expect_section() {
  local count
  count=$(heading_count "$1" "$2")
  [ "$count" = 1 ] || fail "$4: expected exactly one '## $2' section, got $count"
  [ "$(section_body "$1" "$2")" = "$3" ] || fail "$4: the '## $2' body differs from the contract text"
}

# raw_then_guard <case_dir> <root_name> <task-id> <args...>: scaffold the same
# brief raw, then through the guard; leaves raw-brief.md beside the guarded
# brief at home/data/<task-id>/brief.md.
raw_then_guard() {
  local case_dir=$1 root_name=$2 id=$3
  shift 3
  run_brief "$case_dir" "$RAW" "$root_name" "$id" "$@" \
    > "$case_dir/raw.stdout" 2>&1 || fail "$id: the raw scaffold failed"
  cp "$case_dir/home/data/$id/brief.md" "$case_dir/raw-brief.md"
  rm -rf "$case_dir/home/data/$id"
  run_brief "$case_dir" "$GUARD" "$root_name" "$id" "$@" \
    > "$case_dir/wrapped.stdout" 2>&1 || fail "$id: the guarded scaffold failed"
}

# expect_raw_plus_falsification <case_dir> <task-id> <label>: the guarded brief
# is the raw brief followed by the falsification section and nothing else.
expect_raw_plus_falsification() {
  local expected="$1/expected-brief.md"
  { cat "$1/raw-brief.md"; printf '\n## Added-gate falsification\n\n%s\n' "$FALSIFICATION_BODY"; } > "$expected"
  cmp -s "$expected" "$1/home/data/$2/brief.md" \
    || fail "$3: the guarded ship brief is not the raw scaffold plus only the falsification section"
}

test_non_firstmate_ship_adds_only_falsification() {
  local mode case_dir brief
  for mode in no-mistakes direct-PR local-only; do
    case_dir=$(make_case "foreign-ship-$mode" notfirstmate)
    raw_then_guard "$case_dir" notfirstmate "taska-$mode" some-project --mode "$mode"
    brief="$case_dir/home/data/taska-$mode/brief.md"
    expect_section "$brief" 'Added-gate falsification' "$FALSIFICATION_BODY" "foreign-ship-$mode"
    expect_raw_plus_falsification "$case_dir" "taska-$mode" "foreign-ship-$mode"
    assert_no_grep '## Porting contract' "$brief" "foreign-ship-$mode: the porting contract appeared without --port"
    assert_no_grep '## Control-plane boundary' "$brief" \
      "foreign-ship-$mode: the boundary section was appended to a non-firstmate brief"
  done
  pass "a non-firstmate ship brief in every mode is the raw scaffold plus only the falsification section"
}

test_non_firstmate_scout_is_byte_identical() {
  local case_dir
  case_dir=$(make_case foreign-scout notfirstmate)
  raw_then_guard "$case_dir" notfirstmate taskb1 some-project --scout
  cmp -s "$case_dir/raw-brief.md" "$case_dir/home/data/taskb1/brief.md" \
    || fail "foreign-scout: the wrapper changed a non-firstmate scout brief"
  pass "a non-firstmate scout brief scaffolds byte-identically through the wrapper"
}

test_same_named_foreign_origin_gets_no_boundary() {
  local case_dir
  case_dir=$(make_case same-name-foreign-origin firstmate)
  mkdir -p "$case_dir/fmroot/firstmate/projects/firstmate"
  git -C "$case_dir/fmroot/firstmate" init -q
  git -C "$case_dir/fmroot/firstmate" remote add origin git@example.test:ironerumi/firstmate.git
  git -C "$case_dir/fmroot/firstmate/projects/firstmate" init -q
  git -C "$case_dir/fmroot/firstmate/projects/firstmate" remote add origin git@example.test:another/firstmate.git

  raw_then_guard "$case_dir" firstmate taskd1 firstmate --mode no-mistakes
  expect_raw_plus_falsification "$case_dir" taskd1 same-name-foreign-origin
  assert_no_grep '## Control-plane boundary' "$case_dir/home/data/taskd1/brief.md" \
    "same-name-foreign-origin: the boundary section was appended to a foreign repository brief"
  pass "a same-named foreign repository gets the falsification section but no boundary"
}

test_port_appends_only_the_porting_contract() {
  local case_dir plain ported expected
  case_dir=$(make_case foreign-port notfirstmate)
  run_brief "$case_dir" "$GUARD" notfirstmate taskf1 some-project --mode direct-PR \
    > "$case_dir/plain.stdout" 2>&1 || fail "port: the guarded scaffold without --port failed"
  plain="$case_dir/plain-brief.md"
  cp "$case_dir/home/data/taskf1/brief.md" "$plain"
  rm -rf "$case_dir/home/data/taskf1"
  assert_no_grep '## Porting contract' "$plain" "port: the porting contract appeared without --port"

  run_brief "$case_dir" "$GUARD" notfirstmate taskf1 --port some-project --mode direct-PR \
    > "$case_dir/ported.stdout" 2>&1 || fail "port: the guarded scaffold with --port failed"
  ported="$case_dir/home/data/taskf1/brief.md"
  expect_section "$ported" 'Porting contract' "$PORT_BODY" port
  expected="$case_dir/expected-brief.md"
  { cat "$plain"; printf '\n## Porting contract\n\n%s\n' "$PORT_BODY"; } > "$expected"
  cmp -s "$expected" "$ported" \
    || fail "port: --port changed the brief beyond appending the porting contract"
  cmp -s "$case_dir/plain.stdout" "$case_dir/ported.stdout" \
    || fail "port: --port reached bin/fm-brief.sh and changed its output"
  pass "--port appends exactly the porting contract to a ship brief"
}

test_firstmate_ship_orders_all_sections() {
  local case_dir brief order
  case_dir=$(make_case firstmate-ship-port firstmate)
  run_brief "$case_dir" "$GUARD" firstmate taskg1 firstmate --mode no-mistakes --port \
    > "$case_dir/stdout" 2>&1 || fail "firstmate-ship-port: the guarded scaffold failed"
  brief="$case_dir/home/data/taskg1/brief.md"
  expect_section "$brief" 'Added-gate falsification' "$FALSIFICATION_BODY" firstmate-ship-port
  expect_section "$brief" 'Porting contract' "$PORT_BODY" firstmate-ship-port
  [ "$(heading_count "$brief" 'Control-plane boundary')" = 1 ] \
    || fail "firstmate-ship-port: expected exactly one boundary section"
  order=$(grep -Fx -e '## Added-gate falsification' -e '## Porting contract' -e '## Control-plane boundary' "$brief" | tr '\n' '|')
  [ "$order" = '## Added-gate falsification|## Porting contract|## Control-plane boundary|' ] \
    || fail "firstmate-ship-port: sections out of order: $order"

  case_dir=$(make_case firstmate-scout-only firstmate)
  run_brief "$case_dir" "$GUARD" firstmate taskg2 firstmate --scout \
    > "$case_dir/stdout" 2>&1 || fail "firstmate-scout-only: the guarded scaffold failed"
  brief="$case_dir/home/data/taskg2/brief.md"
  [ "$(heading_count "$brief" 'Control-plane boundary')" = 1 ] \
    || fail "firstmate-scout-only: expected exactly one boundary section"
  assert_no_grep '## Added-gate falsification' "$brief" "firstmate-scout-only: a scout brief got the falsification section"
  assert_no_grep '## Porting contract' "$brief" "firstmate-scout-only: a scout brief got the porting contract"
  pass "a Firstmate ship brief orders falsification, porting contract, boundary; a scout gets only the boundary"
}

test_port_is_refused_off_ship_briefs() {
  local label case_dir rc
  for label in scout secondmate; do
    case_dir=$(make_case "port-refused-$label" notfirstmate)
    if [ "$label" = scout ]; then
      run_brief "$case_dir" "$GUARD" notfirstmate taskh1 some-project --scout --port \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    else
      run_brief "$case_dir" "$GUARD" notfirstmate taskh1 --secondmate some-project --port \
        > "$case_dir/stdout" 2> "$case_dir/stderr"
    fi
    rc=$?
    [ "$rc" -ne 0 ] || fail "port-refused-$label: --port was accepted on a $label scaffold"
    [ ! -e "$case_dir/home/data/taskh1" ] || fail "port-refused-$label: a brief was scaffolded despite the refusal"
    assert_grep 'ship briefs' "$case_dir/stderr" "port-refused-$label: the refusal did not name ship briefs"
  done
  pass "--port is refused on scout and secondmate scaffolds before anything is written"
}

test_failed_scaffold_appends_nothing() {
  local case_dir brief rc
  case_dir=$(make_case failed-scaffold notfirstmate)
  run_brief "$case_dir" "$GUARD" notfirstmate taski1 some-project --mode local-only --port \
    > "$case_dir/first.stdout" 2>&1 || fail "failed-scaffold: the first scaffold failed"
  brief="$case_dir/home/data/taski1/brief.md"
  cp "$brief" "$case_dir/first-brief.md"
  run_brief "$case_dir" "$GUARD" notfirstmate taski1 some-project --mode local-only --port \
    > "$case_dir/second.stdout" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "failed-scaffold: overwriting an existing brief was not refused"
  cmp -s "$case_dir/first-brief.md" "$brief" || fail "failed-scaffold: a failed scaffold changed the brief"
  pass "a failing scaffold exits non-zero and appends nothing"
}

test_equivalent_origin_spellings_append_the_boundary() {
  local case_dir count label target_origin
  while IFS='|' read -r label target_origin; do
    case_dir=$(make_case "equivalent-origin-$label" renamed-root)
    mkdir -p "$case_dir/fmroot/renamed-root/projects/firstmate"
    git -C "$case_dir/fmroot/renamed-root" init -q
    git -C "$case_dir/fmroot/renamed-root" remote add origin https://github.com/ironerumi/firstmate.git
    git -C "$case_dir/fmroot/renamed-root/projects/firstmate" init -q
    git -C "$case_dir/fmroot/renamed-root/projects/firstmate" remote add origin "$target_origin"

    run_brief "$case_dir" "$GUARD" renamed-root "task-$label" firstmate --mode no-mistakes \
      > "$case_dir/stdout" 2>&1 || fail "equivalent-origin-$label: the guarded scaffold failed"

    count=$(grep -c '^## Control-plane boundary$' "$case_dir/home/data/task-$label/brief.md")
    [ "$count" = 1 ] || fail "equivalent-origin-$label: expected exactly one boundary section, got $count"
  done <<'EOF'
https|https://GITHUB.COM/ironerumi/firstmate.git/
http|http://github.com/ironerumi/firstmate.git
ssh|ssh://git@github.com/ironerumi/firstmate.git
git|git://GitHub.Com/ironerumi/firstmate.git
scp|git@GITHUB.COM:ironerumi/firstmate.git
EOF
  pass "equivalent supported origin spellings identify the Firstmate repository"
}

test_firstmate_workers_append_the_boundary_once() {
  local kind case_dir brief count
  for kind in ship scout; do
    case_dir=$(make_case "firstmate-$kind-target" firstmate)
    if [ "$kind" = ship ]; then
      run_brief "$case_dir" "$GUARD" firstmate "task-$kind" firstmate --mode no-mistakes \
        > "$case_dir/stdout" 2>&1 || fail "firstmate-$kind: the guarded scaffold failed"
    else
      run_brief "$case_dir" "$GUARD" firstmate "task-$kind" firstmate --scout \
        > "$case_dir/stdout" 2>&1 || fail "firstmate-$kind: the guarded scaffold failed"
    fi

    brief="$case_dir/home/data/task-$kind/brief.md"
    count=$(grep -c '^## Control-plane boundary$' "$brief")
    [ "$count" = 1 ] || fail "firstmate-$kind: expected exactly one boundary section, got $count"
    assert_grep 'Do not run any Firstmate control or lifecycle script' "$brief" \
      "firstmate-$kind: the boundary did not forbid running the control scripts"
    assert_grep 'If you find a decision that belongs to the captain, append' "$brief" \
      "firstmate-$kind: the boundary did not route captain decisions to needs-decision"
  done
  pass "Firstmate ship and scout targets gain the control-plane boundary exactly once"
}

test_firstmate_secondmate_charter_is_transparent() {
  local case_dir raw_brief wrapped_brief
  case_dir=$(make_case firstmate-secondmate firstmate)

  run_brief "$case_dir" "$RAW" firstmate mate --secondmate firstmate \
    > "$case_dir/raw.stdout" 2>&1 || fail "firstmate-secondmate: the raw scaffold failed"
  raw_brief="$case_dir/raw-brief.md"
  cp "$case_dir/home/data/mate/brief.md" "$raw_brief"
  rm -rf "$case_dir/home/data/mate"

  run_brief "$case_dir" "$GUARD" firstmate mate --secondmate firstmate \
    > "$case_dir/wrapped.stdout" 2>&1 || fail "firstmate-secondmate: the wrapped scaffold failed"
  wrapped_brief="$case_dir/home/data/mate/brief.md"

  cmp -s "$raw_brief" "$wrapped_brief" \
    || fail "firstmate-secondmate: the wrapper changed a secondmate charter"
  assert_no_grep '## Control-plane boundary' "$wrapped_brief" \
    "firstmate-secondmate: the boundary section was appended to a secondmate charter"
  assert_no_grep '## Added-gate falsification' "$wrapped_brief" \
    "firstmate-secondmate: the falsification section was appended to a secondmate charter"
  pass "a Firstmate-repo secondmate charter scaffolds byte-identically through the wrapper"
}

# --- intent block intake --------------------------------------------------

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$ROOT/bin/fm-brief-heading-lib.sh"

# The block exactly as the Home repo's `whip dispatch` writes it: its lines go
# under ## Captain's intent; the marker lines do not.
INTENT_BLOCK='Acceptance criteria:
- [ ] the guard copies "quoted" text and é unchanged
- [ ] a closed fence may hold heading-like lines
```text
## not a heading inside a fence
```
### a level-3 heading stays inside the subsection

Out of scope:
- anything else'

# whip_body <block-lines>: a row body in the shape whip dispatch writes.
whip_body() {
  printf 'Issue: ironerumi/example#7\n\n<!-- whip:intent -->\n%s\n<!-- /whip:intent -->\n\nDispatch note.\n' "$1"
}

# backlog_home <case_dir>: give the case home a markdown backlog that Firstmate
# transitions, so the guard reads rows from it through the real tasks-axi.
backlog_home() {
  fm_test_tasks_toml "$1/home/.tasks.toml"
  : > "$1/home/data/backlog.md"
}

# add_row <case_dir> <id> <body>: add one backlog row through the real
# tasks-axi, which stores the body and shows it as one JSON-quoted line.
add_row() {
  local body_args=()
  if [ -n "$3" ]; then
    printf '%s' "$3" > "$1/row-body"
    body_args=(--body-file "$1/row-body")
  fi
  FM_HOME="$1/home" FM_DATA_OVERRIDE="$1/home/data" \
    "$ROOT/bin/fm-tasks-axi.sh" add "$2" "intent probe" --kind ship ${body_args[@]+"${body_args[@]}"} \
    > "$1/add.out" 2>&1 || fail "add_row $2: tasks-axi add failed: $(cat "$1/add.out")"
}

# with_block <brief> <block> <out>: the brief with the block's lines and one
# blank line inserted directly under the first "## Captain's intent" line.
with_block() {
  INTENT_BLOCK_LINES=$2 awk '
    { print }
    !done && $0 == "## Captain'"'"'s intent" { print ENVIRON["INTENT_BLOCK_LINES"]; print ""; done = 1 }
  ' "$1" > "$3"
}

test_intent_block_lands_under_captains_intent() {
  local target root case_dir id brief intent
  for target in some-project firstmate; do
    root=notfirstmate
    [ "$target" = some-project ] || root=firstmate
    case_dir=$(make_case "intent-ship-$target" "$root")
    backlog_home "$case_dir"
    id="ironerumi-tools-$target"
    add_row "$case_dir" "$id" "$(whip_body "$INTENT_BLOCK")"
    # The same scaffold with no row is the wrapper's output without the copy.
    run_brief "$case_dir" "$GUARD" "$root" "$id-norow" "$target" --mode no-mistakes \
      > "$case_dir/norow.stdout" 2>&1 || fail "intent-ship-$target: the row-less scaffold failed"
    run_brief "$case_dir" "$GUARD" "$root" "$id" "$target" --mode no-mistakes \
      > "$case_dir/stdout" 2>&1 || fail "intent-ship-$target: the guarded scaffold failed: $(cat "$case_dir/stdout")"
    brief="$case_dir/home/data/$id/brief.md"
    sed "s/$id-norow/$id/g" "$case_dir/home/data/$id-norow/brief.md" > "$case_dir/norow-brief.md"
    with_block "$case_dir/norow-brief.md" "$INTENT_BLOCK" "$case_dir/expected-brief.md"
    cmp -s "$case_dir/expected-brief.md" "$brief" \
      || fail "intent-ship-$target: the brief is not the row-less brief plus the block under Captain's intent"
    intent=$(fm_brief_task_heading_body "$brief" "## Captain's intent")
    [ "$intent" = "$INTENT_BLOCK"$'\n\n{TASK}\n' ] \
      || [ "$intent" = "$INTENT_BLOCK"$'\n\n{TASK}' ] \
      || fail "intent-ship-$target: Captain's intent read by spawn's reader is not the block then {TASK}: $intent"
    assert_no_grep 'whip:intent' "$brief" "intent-ship-$target: a marker line was copied"
    sed -e 's/^{TASK}$/Ship the probe./' -e 's/^{FIRSTMATE_SPEC}$/Spec text./' "$brief" > "$case_dir/filled.md"
    intent=$(fm_brief_task_heading_body "$case_dir/filled.md" "## Captain's intent")
    case "$intent" in
      "$INTENT_BLOCK"$'\n\nShip the probe.'*) ;;
      *) fail "intent-ship-$target: the filled --intent body does not carry the block: $intent" ;;
    esac
  done

  case_dir=$(make_case intent-scout notfirstmate)
  backlog_home "$case_dir"
  add_row "$case_dir" scout-7 "$(whip_body "$INTENT_BLOCK")"
  run_brief "$case_dir" "$GUARD" notfirstmate scout-7 some-project --scout \
    > "$case_dir/stdout" 2>&1 || fail "intent-scout: the guarded scaffold failed: $(cat "$case_dir/stdout")"
  intent=$(fm_brief_task_heading_body "$case_dir/home/data/scout-7/brief.md" "## Captain's intent")
  case "$intent" in
    "$INTENT_BLOCK"$'\n\n{TASK}'*) ;;
    *) fail "intent-scout: the scout brief's Captain's intent does not start with the block: $intent" ;;
  esac

  # Scaffolding the same brief again is refused by the scaffolder and leaves
  # exactly one copy of the block.
  cp "$case_dir/home/data/scout-7/brief.md" "$case_dir/first-brief.md"
  run_brief "$case_dir" "$GUARD" notfirstmate scout-7 some-project --scout > "$case_dir/again.stdout" 2>&1 \
    && fail "intent-scout: re-scaffolding an existing brief was accepted"
  cmp -s "$case_dir/first-brief.md" "$case_dir/home/data/scout-7/brief.md" \
    || fail "intent-scout: re-scaffolding changed the brief"
  pass "a row's intent block lands under Captain's intent for ship (any target) and scout briefs, once"
}

test_rows_without_block_are_byte_identical() {
  local case_dir label body
  case_dir=$(make_case intent-none notfirstmate)
  backlog_home "$case_dir"
  raw_then_guard "$case_dir" notfirstmate missing-row some-project --mode no-mistakes
  expect_raw_plus_falsification "$case_dir" missing-row "intent-none: no row"
  for label in plain endonly nobody; do
    case "$label" in
      plain) body='A row added by hand.' ;;
      endonly) body=$'Text\n<!-- /whip:intent -->\nmore' ;;
      nobody) body= ;;
    esac
    add_row "$case_dir" "row-$label" "$body"
    raw_then_guard "$case_dir" notfirstmate "row-$label" some-project --mode no-mistakes
    expect_raw_plus_falsification "$case_dir" "row-$label" "intent-none: row without a block ($label)"
  done

  add_row "$case_dir" mate "$(whip_body "$INTENT_BLOCK")"
  run_brief "$case_dir" "$RAW" notfirstmate mate --secondmate some-project > /dev/null 2>&1 \
    || fail "intent-none: the raw secondmate scaffold failed"
  cp "$case_dir/home/data/mate/brief.md" "$case_dir/raw-mate.md"
  rm -rf "$case_dir/home/data/mate"
  run_brief "$case_dir" "$GUARD" notfirstmate mate --secondmate some-project > /dev/null 2>&1 \
    || fail "intent-none: the guarded secondmate scaffold failed"
  cmp -s "$case_dir/raw-mate.md" "$case_dir/home/data/mate/brief.md" \
    || fail "intent-none: a secondmate charter changed although its row carries a block"
  pass "no row, or a row without a begin marker, leaves the brief byte-identical; a secondmate charter is untouched"
}

# expect_refusal <case_dir> <id> <label> <fault-text>: the guarded ship scaffold
# exits non-zero naming the row and the fault, and the brief is the raw scaffold
# plus only the section appended before the read.
expect_refusal() {
  local case_dir=$1 id=$2 label=$3 fault=$4 rc
  run_brief "$case_dir" "$RAW" notfirstmate "$id" some-project --mode no-mistakes > /dev/null 2>&1 \
    || fail "$label: the raw scaffold failed"
  cp "$case_dir/home/data/$id/brief.md" "$case_dir/raw-brief.md"
  rm -rf "$case_dir/home/data/$id"
  run_brief "$case_dir" "$GUARD" notfirstmate "$id" some-project --mode no-mistakes \
    > "$case_dir/$id.stdout" 2> "$case_dir/$id.stderr"
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the guard accepted a faulty row"
  assert_grep "$id" "$case_dir/$id.stderr" "$label: the error does not name row $id: $(cat "$case_dir/$id.stderr")"
  assert_grep "$fault" "$case_dir/$id.stderr" "$label: the error does not name the fault '$fault': $(cat "$case_dir/$id.stderr")"
  expect_raw_plus_falsification "$case_dir" "$id" "$label"
}

test_malformed_blocks_are_refused() {
  local case_dir
  case_dir=$(make_case intent-malformed notfirstmate)
  backlog_home "$case_dir"
  add_row "$case_dir" bad-open $'Issue: x\n\n<!-- whip:intent -->\nAcceptance criteria:\n- [ ] one'
  expect_refusal "$case_dir" bad-open intent-unterminated 'no end marker'
  add_row "$case_dir" bad-h1 "$(whip_body $'Acceptance criteria:\n# Out')"
  expect_refusal "$case_dir" bad-h1 intent-h1 'heading'
  add_row "$case_dir" bad-h2 "$(whip_body $'Acceptance criteria:\n   ##')"
  expect_refusal "$case_dir" bad-h2 intent-h2 'heading'
  add_row "$case_dir" bad-fence "$(whip_body $'Acceptance criteria:\n~~~~\n## hidden\n~~~')"
  expect_refusal "$case_dir" bad-fence intent-fence 'unclosed code fence'
  pass "an unterminated block, a level-1 or level-2 heading line, and an unclosed fence are refused, inserting nothing"
}

test_failing_backlog_read_is_refused() {
  local case_dir fakebin real
  case_dir=$(make_case intent-readfail notfirstmate)
  backlog_home "$case_dir"
  add_row "$case_dir" read-fail "$(whip_body "$INTENT_BLOCK")"
  fakebin=$(fm_fakebin "$case_dir")
  real=$(command -v tasks-axi)
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then
  echo 'error: backend exploded'
  exit 3
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  PATH="$fakebin:$PATH" expect_refusal "$case_dir" read-fail intent-readfail 'backend exploded'
  pass "a failing backlog read on a transitioning home exits non-zero naming the read error"
}

test_firstmate_secondmate_charter_is_transparent
test_firstmate_workers_append_the_boundary_once
test_non_firstmate_ship_adds_only_falsification
test_non_firstmate_scout_is_byte_identical
test_same_named_foreign_origin_gets_no_boundary
test_equivalent_origin_spellings_append_the_boundary
test_port_appends_only_the_porting_contract
test_firstmate_ship_orders_all_sections
test_port_is_refused_off_ship_briefs
test_failed_scaffold_appends_nothing
test_intent_block_lands_under_captains_intent
test_rows_without_block_are_byte_identical
test_malformed_blocks_are_refused
test_failing_backlog_read_is_refused
