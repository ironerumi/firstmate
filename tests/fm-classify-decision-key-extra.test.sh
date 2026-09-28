#!/usr/bin/env bash
# Fork-owned regression: both resolution shapes close a worker-opened keyed
# decision, with or without a persisted incremental cursor. Migrated out of
# tests/fm-classify-decision-key.test.sh so the upstream file stays clean; the
# fold owner is bin/fm-classify-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-decision-key-extra-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

assert_fold() {  # <status-file> <expected> <label>
  local f=$1 expected=$2 label=$3 full incr
  full=$(status_open_decisions "$f")
  incr=$(status_open_decisions_incremental "$f")
  [ "$full" = "$expected" ] \
    || fail "$label: full fold mismatch: got '$full' want '$expected'"
  [ "$incr" = "$full" ] \
    || fail "$label: incremental fold diverged from the full fold: got '$incr' want '$full'"
}

test_both_resolution_shapes_close_a_cleared_worker_key() {
  local dir a_cursor b_cursor a b
  dir=$(case_dir resolution-shapes)
  a_cursor="$dir/.a.open-decisions-cursor"
  b_cursor="$dir/.b.open-decisions-cursor"

  # Shape A: firstmate's writer (bin/fm-send.sh --resolve-key).
  printf 'needs-decision [key=mailcheck-190-empty-sample]: which sample should the empty inbox use\n' \
    > "$dir/a.status"
  rm -f "$a_cursor"
  assert_fold "$dir/a.status" \
    "$(printf 'mailcheck-190-empty-sample\tneeds-decision\twhich sample should the empty inbox use\n')" \
    "worker-opened key is open before any resolution"
  printf 'resolved [key=mailcheck-190-empty-sample]: answered: keep the current sample\n' >> "$dir/a.status"
  rm -f "$a_cursor"
  assert_fold "$dir/a.status" "" "firstmate-shaped resolution closes after a cursor clear"

  # Shape B: the colon-first worker form, over a blocked opener.
  printf 'blocked [key=mailcheck-190-empty-sample]: no sample available for the empty inbox\n' \
    > "$dir/b.status"
  rm -f "$b_cursor"
  assert_fold "$dir/b.status" \
    "$(printf 'mailcheck-190-empty-sample\tblocked\tno sample available for the empty inbox\n')" \
    "worker-opened blocked key is open before any resolution"
  printf 'resolved: [key=mailcheck-190-empty-sample] cleared once a sample arrived\n' >> "$dir/b.status"
  rm -f "$b_cursor"
  assert_fold "$dir/b.status" "" "colon-first resolution closes after a cursor clear"

  # Both shapes state the same key, so a stream using either one closes it.
  a=$(status_open_decisions "$dir/a.status")
  b=$(status_open_decisions "$dir/b.status")
  [ -z "$a" ] && [ -z "$b" ] \
    || fail "a resolution shape left the key open: firstmate='$a' worker='$b'"
  pass "both resolution shapes close a worker-opened key, with or without a cursor"
}

test_both_resolution_shapes_close_a_cleared_worker_key
