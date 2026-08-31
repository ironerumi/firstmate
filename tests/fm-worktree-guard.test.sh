#!/usr/bin/env bash
# tests/fm-worktree-guard.test.sh - acceptance matrix for the worktree-isolation
# guard.
#
# Covers the contract in docs/worktree-guard.md: which worker commands are
# refused because their target resolves outside the task's own worktree, which
# are always permitted, that a refused command leaves the sibling checkout
# untouched, that the escape allows an authorized removal, and that every
# failure to establish the worker's own root allows the command instead of
# refusing work.
#
# The decision matrix is driven through the library's public entry point, and
# every refusal case is ALSO driven end to end through the real bin/shims
# symlinks with real files on disk, so the suite proves the guard as a worker
# actually meets it rather than as a function in isolation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-worktree-guard)
SHIMS="$ROOT/bin/shims"
LIB="$ROOT/bin/fm-worktree-guard-lib.sh"

# The fixture tree mirrors a pool: two sibling task worktrees, the home's state
# directory beside them, and this task's own temp root.
POOL="$TMP/pool"
OWN="$POOL/task-own"
SIBLING="$POOL/task-sibling"
STATE="$TMP/state"
TASKTMP="$TMP/tmp/fm-t1"
META="$STATE/t1.meta"
mkdir -p "$OWN/src" "$SIBLING/src" "$STATE/t1.inbox/handled" "$TASKTMP"

fm_write_meta "$META" \
  "window=firstmate:fm-t1" \
  "endpoint_task_id=t1" \
  "worktree=$OWN" \
  "project=$TMP/project" \
  "harness=claude" \
  "kind=ship" \
  "tasktmp=$TASKTMP"

# The temp namespace is unprotected by contract, and this suite's own fixtures
# live in it, so every case that must reach a verdict pins the namespace
# somewhere the fixtures are not.
NO_TEMP="$TMP/never-a-temp-root"

# --- 1. the decision matrix -------------------------------------------------

# shellcheck source=bin/fm-worktree-guard-lib.sh
. "$LIB"

decision_code() { # <tool> <cwd> [argv...]
  local tool=$1 cwd=$2 out
  shift 2
  out=$(FM_WORKTREE_GUARD_TEMP_ROOTS="$NO_TEMP" \
    FM_WORKTREE_GUARD_STATE_PREFIX="$STATE/t1." \
    FM_WORKTREE_GUARD_TASKTMP="$TASKTMP" \
    fm_worktree_guard_decide "$tool" "$OWN" "$cwd" "$@")
  case "$out" in
    allow) printf 'allow\n' ;;
    deny*) printf '%s\n' "$out" | cut -f2 ;;
    *) printf 'malformed\n' ;;
  esac
}

check_decision() { # <expected> <label> <tool> <cwd> [argv...]
  local expected=$1 label=$2 got
  shift 2
  got=$(decision_code "$@")
  [ "$got" = "$expected" ] || fail "$label: expected $expected, got $got (command: $*)"
}

# Deny: the incident's own shape and its neighbours.
check_decision worktree-escape-delete "rm of a sibling worktree" rm "$OWN" -rf "$SIBLING"
check_decision worktree-escape-delete "rm of a sibling reached with .." rm "$OWN" -rf ../task-sibling
check_decision worktree-escape-delete "rm of the pool that holds every sibling" rm "$OWN" -rf ..
check_decision worktree-escape-delete "rm from a cwd already outside the root" rm "$SIBLING" -rf src
check_decision worktree-escape-delete "rm of another task's durable record" rm "$STATE" -f "$STATE/t2.meta"
check_decision worktree-escape-delete "rm of a fleet-wide record" rm "$OWN" -f "$STATE/.wake-queue"
check_decision worktree-escape-delete "rmdir outside the root" rmdir "$OWN" ../task-sibling/src
check_decision worktree-escape-delete "unlink outside the root" unlink "$OWN" "$SIBLING/src/x"
check_decision worktree-escape-delete "an outside target hidden after -- " rm "$OWN" -rf -- ../task-sibling
check_decision worktree-escape-move "mv whose source is outside" mv "$OWN" ../task-sibling/src/x .
check_decision worktree-escape-move "mv whose destination is outside" mv "$OWN" src/x ../task-sibling/
check_decision worktree-escape-move "mv -t naming an outside destination" mv "$OWN" -t "$SIBLING" src/x
check_decision worktree-remove "git worktree remove of a sibling" git "$OWN" worktree remove ../task-sibling
check_decision worktree-remove "git worktree remove of this task's own root" git "$OWN" worktree remove "$OWN"
check_decision worktree-remove "git -C rebasing a relative worktree removal" git "$OWN" -C "$POOL" worktree remove task-sibling
check_decision worktree-remove "git worktree remove behind an unknown option" git "$OWN" --no-optional-locks worktree remove --force "$SIBLING"
check_decision worktree-prune "git worktree prune rewrites shared records" git "$OWN" worktree prune
check_decision worktree-pool "treehouse return frees the lease" treehouse "$OWN" return --force "$SIBLING"
check_decision worktree-pool "treehouse destroy" treehouse "$OWN" destroy
check_decision worktree-pool "treehouse prune" treehouse "$OWN" prune

# Allow: everything inside the worker's own sandbox, and every non-target shape.
check_decision allow "rm inside the root" rm "$OWN" -rf src/build
check_decision allow "rm of the root itself is this task's own copy" rm "$OWN" -rf "$OWN"
check_decision allow "rm of a relative name from inside the root" rm "$OWN" -f notes.txt
check_decision allow "an option that looks like a path" rm "$OWN" --one-file-system -rf src
check_decision allow "mv inside the root" mv "$OWN" src/a src/b
check_decision allow "mv of this task's own inbox message" mv "$OWN" "$STATE/t1.inbox/001.msg" "$STATE/t1.inbox/handled/"
check_decision allow "rm of this task's own status file" rm "$OWN" -f "$STATE/t1.status"
check_decision allow "rm inside this task's own temp root" rm "$OWN" -rf "$TASKTMP/scratch"
check_decision allow "mv -S consumes a suffix, not a path" mv "$OWN" -S ../backup src/a src/b
check_decision allow "git worktree remove of a worktree nested in the root" git "$OWN" worktree remove nested/wt
check_decision allow "git worktree prune --dry-run changes nothing" git "$OWN" worktree prune --dry-run
check_decision allow "git worktree add" git "$OWN" worktree add ../elsewhere
check_decision allow "an ordinary git command" git "$OWN" status --porcelain
check_decision allow "a git push is the other guard's business" git "$OWN" push origin HEAD
check_decision allow "treehouse get" treehouse "$OWN" get
check_decision allow "an unfronted tool" cp "$OWN" ../task-sibling/x .
pass "the decision matrix matches the documented contract"

# The OS temp namespace is unprotected by contract, and only by contract.
got=$(FM_WORKTREE_GUARD_STATE_PREFIX="$STATE/t1." FM_WORKTREE_GUARD_TASKTMP="$TASKTMP" \
  fm_worktree_guard_decide rm "$OWN" "$OWN" -rf /tmp/scratch-file)
[ "$got" = allow ] || fail "the default temp namespace must stay unprotected scratch, got: $got"
got=$(FM_WORKTREE_GUARD_TEMP_ROOTS="$NO_TEMP" FM_WORKTREE_GUARD_STATE_PREFIX="$STATE/t1." \
  FM_WORKTREE_GUARD_TASKTMP="$TASKTMP" \
  fm_worktree_guard_decide rm "$OWN" "$OWN" -rf /tmp/scratch-file)
case "$got" in
  deny*) ;;
  *) fail "an outside path must be refused once the temp namespace is narrowed, got: $got" ;;
esac
pass "the temp namespace is an explicit, configurable allowance rather than a hole"

# --- 2. end to end, through the real shims, against real files --------------

# Every case below runs the actual bin/shims symlink with the worker's pane
# environment, so it proves the transport, the exit status, the rendered
# refusal, and - the property that matters - that the sibling's files survive.
guarded() { # [VAR=VAL ...] -- <cwd> <cmd> [args...]
  local envs=() cwd
  while [ "$1" != "--" ]; do
    envs[${#envs[@]}]=$1
    shift
  done
  shift
  cwd=$1
  shift
  ( cd "$cwd" && env "PATH=$SHIMS:$PATH" "FM_WORKTREE_GUARD_META=$META" \
    "FM_WORKTREE_GUARD_TEMP_ROOTS=$NO_TEMP" ${envs[@]+"${envs[@]}"} "$@" )
}

: > "$SIBLING/src/unlanded.txt"
: > "$OWN/src/mine.txt"
: > "$STATE/t1.inbox/001.msg"
: > "$STATE/.wake-queue"
: > "$TASKTMP/scratch"

out=$(guarded -- "$OWN" rm -rf ../task-sibling 2>&1)
expect_code 3 $? "a refused removal must exit 3"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-escape-delete]" "the refusal must name its code"
assert_contains "$out" "FM_WORKTREE_GUARD_ALLOW=1" "the refusal must name the escape"
assert_present "$SIBLING/src/unlanded.txt" "the sibling's unlanded work must survive the refused removal"
pass "rm of a sibling worktree is refused end to end and the sibling survives"

out=$(guarded -- "$OWN" mv "$STATE/.wake-queue" "$OWN/stolen" 2>&1)
expect_code 3 $? "a refused move must exit 3"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-escape-move]" "the refusal must name its code"
assert_present "$STATE/.wake-queue" "a fleet-wide record must survive the refused move"
pass "mv out of the home's state directory is refused end to end"

guarded -- "$OWN" rm -f src/mine.txt
expect_code 0 $? "a removal inside the worker's own worktree must run"
assert_absent "$OWN/src/mine.txt" "the worker's own file must actually be removed"
guarded -- "$OWN" mv "$STATE/t1.inbox/001.msg" "$STATE/t1.inbox/handled/"
expect_code 0 $? "the brief's own inbox acknowledgement must run"
assert_present "$STATE/t1.inbox/handled/001.msg" "the inbox acknowledgement must actually land"
guarded -- "$OWN" rm -f "$TASKTMP/scratch"
expect_code 0 $? "a removal inside this task's own temp root must run"
assert_absent "$TASKTMP/scratch" "this task's own scratch must actually be removed"
pass "the worker's own worktree, records, and scratch stay fully usable"

# A real repository with a real linked worktree: the refusal has to hold against
# git itself, not just against a parsed command string.
REPO="$TMP/repo"
REPO_SIBLING="$TMP/repo-sibling"
fm_git_identity
fm_git_worktree "$REPO" "$REPO_SIBLING" fm/worktree-guard-sibling
: > "$REPO_SIBLING/unlanded.txt"
fm_write_meta "$STATE/t2.meta" "worktree=$REPO" "kind=ship"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" -- "$REPO" git worktree remove --force "$REPO_SIBLING" 2>&1)
expect_code 3 $? "a refused worktree removal must exit 3"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-remove]" "the refusal must name its code"
assert_present "$REPO_SIBLING/unlanded.txt" "the sibling worktree must still exist after the refusal"
SIBLING_REAL=$(cd "$REPO_SIBLING" && pwd -P)
git -C "$REPO" worktree list --porcelain | grep -qF "$SIBLING_REAL" \
  || fail "the sibling worktree must still be registered after the refusal"
pass "git worktree remove of a live sibling worktree is refused end to end"

out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" -- "$REPO" git worktree prune 2>&1)
expect_code 3 $? "a refused prune must exit 3"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-prune]" "the refusal must name its code"
guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" -- "$REPO" git worktree prune --dry-run >/dev/null 2>&1
expect_code 0 $? "a prune dry run changes nothing and must run"
pass "worktree pruning is refused while its dry run stays available"

# --- 3. the escape, and firstmate's own authorized removal path -------------

out=$(guarded "FM_WORKTREE_GUARD_ALLOW=1" -- "$OWN" rm -f ../task-sibling/src/unlanded.txt 2>&1)
expect_code 0 $? "the escape must allow an authorized removal: $out"
assert_absent "$SIBLING/src/unlanded.txt" "the authorized removal must actually happen"
pass "FM_WORKTREE_GUARD_ALLOW=1 allows a removal firstmate has authorized"

# Firstmate's own removal path declares itself by exporting the escape for every
# child it runs, which is the mechanism proved here: a parent that exports it
# lifts the guard for the tools it drives, without any in-command prefix.
: > "$SIBLING/src/second.txt"
guarded -- "$OWN" bash -c 'export FM_WORKTREE_GUARD_ALLOW=1; rm -f ../task-sibling/src/second.txt'
expect_code 0 $? "an authorized parent must lift the guard for the commands it runs"
assert_absent "$SIBLING/src/second.txt" "the authorized parent's removal must actually happen"
pass "an authorized firstmate-owned parent process is not refused"

out=$(env "FM_WORKTREE_GUARD_META=$META" "PATH=$SHIMS:$PATH" "$ROOT/bin/fm-teardown.sh" 2>&1)
status=$?
[ "$status" -ne 3 ] || fail "firstmate's own cleanup path must never be refused by the guard: $out"
pass "the cleanup path that owns worktree removal is not itself guarded"

# --- 4. inert whenever the worker's own root cannot be established ----------

: > "$SIBLING/src/inert.txt"
inert_case() { # <label> [VAR=VAL ...]
  local label=$1
  shift
  : > "$SIBLING/src/inert.txt"
  ( cd "$OWN" && env "PATH=$SHIMS:$PATH" "FM_WORKTREE_GUARD_TEMP_ROOTS=$NO_TEMP" "$@" \
    rm -f ../task-sibling/src/inert.txt )
  expect_code 0 $? "$label must allow"
  assert_absent "$SIBLING/src/inert.txt" "$label must reach the real tool"
}

inert_case "an unset durable record" FM_WORKTREE_GUARD_META=
inert_case "a record that does not exist" "FM_WORKTREE_GUARD_META=$STATE/absent.meta"

fm_write_meta "$STATE/rootless.meta" "kind=ship" "harness=claude"
inert_case "a record with no worktree line" "FM_WORKTREE_GUARD_META=$STATE/rootless.meta"

fm_write_secondmate_meta "$STATE/sm1.meta" "$OWN"
inert_case "a secondmate home, which runs a fleet of its own" "FM_WORKTREE_GUARD_META=$STATE/sm1.meta"
pass "the guard is inert wherever the worker's own root cannot be established"

# --- 5. one owner, reached under every fronted name -------------------------

for tool in rm rmdir unlink mv treehouse; do
  [ -L "$SHIMS/$tool" ] || fail "$SHIMS/$tool must be a symlink to the one shim owner"
  [ -x "$SHIMS/$tool" ] || fail "$SHIMS/$tool must be executable"
  [ "$(readlink "$SHIMS/$tool")" = "../fm-worktree-guard-shim.sh" ] \
    || fail "$SHIMS/$tool must resolve to bin/fm-worktree-guard-shim.sh"
done
[ "$(readlink "$SHIMS/git")" = "../fm-nm-guard-shim.sh" ] \
  || fail "bin/shims/git must stay the validation-owner shim, which carries this guard too"
pass "every fronted tool reaches one shim owner"

# A second firstmate home's shims on the same PATH must not make two shims exec
# each other instead of the real tool. A worker pane already carries one shim
# directory, so a task working on a second firstmate checkout hits exactly this.
SECOND="$TMP/second-home/bin"
mkdir -p "$SECOND/shims"
cp "$ROOT/bin/fm-worktree-guard-shim.sh" "$SECOND/fm-worktree-guard-shim.sh"
cp "$ROOT/bin/fm-worktree-guard-lib.sh" "$SECOND/fm-worktree-guard-lib.sh"
cp "$ROOT/bin/fm-nm-guard-shim.sh" "$SECOND/fm-nm-guard-shim.sh"
cp "$ROOT/bin/fm-nm-guard-lib.sh" "$SECOND/fm-nm-guard-lib.sh"
cp "$ROOT/bin/fm-nm-status-lib.sh" "$SECOND/fm-nm-status-lib.sh"
ln -s ../fm-worktree-guard-shim.sh "$SECOND/shims/rm"
ln -s ../fm-nm-guard-shim.sh "$SECOND/shims/git"
: > "$OWN/src/chained.txt"
( cd "$OWN" && env "PATH=$SHIMS:$SECOND/shims:$PATH" "FM_WORKTREE_GUARD_META=$META" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$NO_TEMP" rm -f src/chained.txt )
expect_code 0 $? "two shim directories on one PATH must still reach the real rm"
assert_absent "$OWN/src/chained.txt" "the real rm must have run"
( cd "$OWN" && env "PATH=$SHIMS:$SECOND/shims:$PATH" "FM_WORKTREE_GUARD_META=$META" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$NO_TEMP" git --version >/dev/null )
expect_code 0 $? "two shim directories on one PATH must still reach the real git"
pass "a second firstmate home's shims on PATH cannot loop the transport"

# A fixture wrapper that resolves "the real tool" with a bare `command -v` lands
# back on the shim, and both sides exec, so the pair would swap places inside one
# process forever. tests/lib.sh's fm_real_tool is how a fixture avoids that; the
# shim's own backstop is what turns a wrapper that does not into a diagnosable
# error rather than a hung tool.
WRAPPER="$TMP/wrapper"
mkdir -p "$WRAPPER"
# shellcheck disable=SC2016  # the wrapper's own expansions must reach the file
printf '%s\n%s\n' '#!/usr/bin/env bash' 'exec "${LOOPING_RM:?}" "$@"' > "$WRAPPER/rm"
chmod +x "$WRAPPER/rm"
out=$( cd "$OWN" && env "PATH=$SHIMS:$WRAPPER:$PATH" "LOOPING_RM=$SHIMS/rm" \
  "FM_WORKTREE_GUARD_META=$META" "FM_WORKTREE_GUARD_TEMP_ROOTS=$NO_TEMP" \
  rm -f src/loop-probe 2>&1 )
expect_code 127 $? "an exec loop must stop with a diagnosable error, not hang"
assert_contains "$out" "refusing an exec loop" "the loop backstop must say what happened"
LOOP_REAL=$(fm_real_tool rm)
case "$LOOP_REAL" in
  "$SHIMS/rm") fail "fm_real_tool must resolve past firstmate's own shim" ;;
esac
pass "a wrapper that resolves back to the shim fails fast instead of hanging"

pass "fm-worktree-guard.test.sh"
