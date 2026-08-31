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
REAL_GIT=$(fm_real_tool git)
fm_git_identity
"$REAL_GIT" init -q "$OWN"

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
    FM_WORKTREE_GUARD_REAL_GIT="$REAL_GIT" \
    FM_WORKTREE_GUARD_STATE_STATUS="$STATE/t1.status" \
    FM_WORKTREE_GUARD_STATE_INBOX="$STATE/t1.inbox" \
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
check_decision worktree-escape-delete "rm of a dotted sibling task record" rm "$OWN" -f "$STATE/t1.other.meta"
check_decision worktree-escape-delete "rmdir outside the root" rmdir "$OWN" ../task-sibling/src
check_decision worktree-escape-delete "unlink outside the root" unlink "$OWN" "$SIBLING/src/x"
check_decision worktree-escape-delete "an outside target hidden after -- " rm "$OWN" -rf -- ../task-sibling
check_decision worktree-escape-move "mv whose source is outside" mv "$OWN" ../task-sibling/src/x .
check_decision worktree-escape-move "mv whose destination is outside" mv "$OWN" src/x ../task-sibling/
check_decision worktree-escape-move "mv -t naming an outside destination" mv "$OWN" -t "$SIBLING" src/x
check_decision worktree-escape-move "mv with an attached -t destination" mv "$OWN" "-t$SIBLING" src/x
check_decision worktree-escape-move "mv with a clustered -t destination" mv "$OWN" -ft "$SIBLING" src/x
check_decision allow "mv -T preserves final-component semantics" mv "$OWN" -T src/x "$OWN/outside-link"
check_decision worktree-remove "git worktree remove of a sibling" git "$OWN" worktree remove ../task-sibling
check_decision worktree-remove "git worktree remove of this task's own root" git "$OWN" worktree remove "$OWN"
check_decision worktree-remove "git -C rebasing a relative worktree removal" git "$OWN" \
  "--git-dir=$OWN/.git" -C "$POOL" worktree remove task-sibling
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
check_decision allow "git worktree prune --dry-run changes nothing" git "$OWN" worktree prune --dry-run
check_decision allow "git worktree add" git "$OWN" worktree add ../elsewhere
check_decision allow "an ordinary git command" git "$OWN" status --porcelain
check_decision allow "a git push is the other guard's business" git "$OWN" push origin HEAD
check_decision allow "treehouse get" treehouse "$OWN" get
check_decision allow "an unfronted tool" cp "$OWN" ../task-sibling/x .
pass "the decision matrix matches the documented contract"

# The OS temp namespace is unprotected by contract, and only by contract.
got=$(FM_WORKTREE_GUARD_STATE_STATUS="$STATE/t1.status" \
  FM_WORKTREE_GUARD_STATE_INBOX="$STATE/t1.inbox" FM_WORKTREE_GUARD_TASKTMP="$TASKTMP" \
  fm_worktree_guard_decide rm "$OWN" "$OWN" -rf /tmp/scratch-file)
[ "$got" = allow ] || fail "the default temp namespace must stay unprotected scratch, got: $got"
got=$(FM_WORKTREE_GUARD_TEMP_ROOTS="$NO_TEMP" FM_WORKTREE_GUARD_STATE_STATUS="$STATE/t1.status" \
  FM_WORKTREE_GUARD_STATE_INBOX="$STATE/t1.inbox" \
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
: > "$STATE/t1.status"
: > "$STATE/t1.other.meta"

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

out=$(guarded -- "$OWN" rm -f "$STATE/t1.other.meta" 2>&1)
expect_code 3 $? "a dotted sibling task record removal must exit 3"
assert_present "$STATE/t1.other.meta" "a dotted sibling task record must survive"
pass "a dotted sibling task id cannot collide with this task's allowances"

ln -s "$SIBLING" "$OWN/outside-link"
out=$(guarded -- "$OWN" rm -f outside-link/src/unlanded.txt 2>&1)
expect_code 3 $? "an intermediate symlink to a sibling must be refused"
assert_present "$SIBLING/src/unlanded.txt" "rm through an escaping symlink must leave sibling work intact"
: > "$OWN/src/symlink-move.txt"
out=$(guarded -- "$OWN" mv src/symlink-move.txt outside-link/ 2>&1)
expect_code 3 $? "an mv destination through an escaping symlink must be refused"
assert_present "$OWN/src/symlink-move.txt" "a refused symlink move must leave its source intact"
assert_absent "$SIBLING/symlink-move.txt" "a refused symlink move must not reach the sibling"
pass "intermediate symlinks cannot escape the worker's root"

mkdir -p "$OWN/inside-target"
ln -s "$OWN/inside-target" "$OWN/inside-link"
: > "$OWN/inside-target/removable.txt"
guarded -- "$OWN" rm -f inside-link/removable.txt
expect_code 0 $? "an intermediate symlink staying inside the root must run"
assert_absent "$OWN/inside-target/removable.txt" "an in-root symlink removal must reach the real file"
ln -s "$SIBLING/src/unlanded.txt" "$OWN/final-link"
guarded -- "$OWN" rm -f final-link
expect_code 0 $? "removing an in-root final symlink must run"
assert_absent "$OWN/final-link" "the in-root final symlink must be removed"
assert_present "$SIBLING/src/unlanded.txt" "the final symlink's outside target must survive"
pass "in-root symlinks preserve the fronted tool's final-component semantics"

out=$(guarded -- "$OWN" rm -rf outside-link/ 2>&1)
expect_code 3 $? "rm of an outside final symlink with a trailing slash must be refused"
assert_present "$SIBLING/src/unlanded.txt" "the sibling must survive a trailing-slash rm refusal"
mkdir -p "$SIBLING/empty-outside"
ln -s "$SIBLING/empty-outside" "$OWN/empty-outside-link"
out=$(guarded -- "$OWN" rmdir empty-outside-link/ 2>&1)
expect_code 3 $? "rmdir of an outside final symlink with a trailing slash must be refused"
assert_present "$SIBLING/empty-outside" "the sibling directory must survive a trailing-slash rmdir refusal"
mkdir -p "$OWN/inside-removal-target"
: > "$OWN/inside-removal-target/removable.txt"
ln -s "$OWN/inside-removal-target" "$OWN/inside-removal-link"
guarded -- "$OWN" rm -rf inside-removal-link/
expect_code 0 $? "a trailing-slash removal resolving inside the root must run"
assert_absent "$OWN/inside-removal-target/removable.txt" "the in-root trailing-slash removal must reach its target"
pass "remove tools judge trailing-slash symlink targets physically"

: > "$OWN/src/final-destination.txt"
out=$(guarded -- "$OWN" mv src/final-destination.txt outside-link 2>&1)
expect_code 3 $? "a final symlink destination to a sibling must be refused"
assert_present "$OWN/src/final-destination.txt" "a refused final destination move must keep its source"
assert_absent "$SIBLING/final-destination.txt" "a refused final destination move must not reach the sibling"
: > "$OWN/src/target-directory.txt"
out=$(guarded -- "$OWN" mv "-t$OWN/outside-link" src/target-directory.txt 2>&1)
expect_code 3 $? "an attached target-directory symlink to a sibling must be refused"
assert_present "$OWN/src/target-directory.txt" "a refused target-directory move must keep its source"
assert_absent "$SIBLING/target-directory.txt" "a refused target-directory move must not reach the sibling"
: > "$OWN/src/inside-destination.txt"
guarded -- "$OWN" mv src/inside-destination.txt inside-link
expect_code 0 $? "a final symlink destination inside the root must run"
assert_present "$OWN/inside-target/inside-destination.txt" "an in-root destination symlink must receive the file"
pass "move destinations follow directory symlinks without widening source semantics"

ln -s "$SIBLING" "$OWN/outside-source-link"
: > "$SIBLING/trailing-source-marker"
out=$(guarded -- "$OWN" mv outside-source-link/ "$OWN/renamed-sibling" 2>&1)
expect_code 3 $? "a trailing-slash source symlink to a sibling must be refused"
assert_present "$OWN/outside-source-link" "the refused trailing source link must remain"
assert_present "$SIBLING/trailing-source-marker" "the sibling directory must remain intact"
assert_absent "$OWN/renamed-sibling" "a refused trailing source must not be renamed"

TRAILING_MV_BIN="$TMP/trailing-mv-bin"
mkdir -p "$TRAILING_MV_BIN"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'mode=${MV_TRAILING_MODE:-}' \
  'if [ "$mode" = strip ]; then shift; exec /bin/mv "${1%/}" "$2"; fi' \
  'if [ "$mode" = follow ]; then source=${1%/}; exec /bin/mv "$(readlink "$source")" "$2"; fi' \
  'exit 64' > "$TRAILING_MV_BIN/mv"
chmod +x "$TRAILING_MV_BIN/mv"
guarded "PATH=$SHIMS:$TRAILING_MV_BIN:$PATH" "MV_TRAILING_MODE=strip" -- "$OWN" \
  mv --strip-trailing-slashes outside-source-link/ "$OWN/stripped-source-link"
expect_code 0 $? "--strip-trailing-slashes must keep unresolved source semantics"
assert_present "$OWN/stripped-source-link" "the stripped final symlink must be moved"
assert_present "$SIBLING/trailing-source-marker" "moving the link must not move its sibling target"
mkdir -p "$OWN/inside-source-target"
: > "$OWN/inside-source-target/trailing-source-marker"
ln -s "$OWN/inside-source-target" "$OWN/inside-source-link"
guarded "PATH=$SHIMS:$TRAILING_MV_BIN:$PATH" "MV_TRAILING_MODE=follow" -- "$OWN" \
  mv inside-source-link/ "$OWN/inside-source-renamed"
expect_code 0 $? "a trailing-slash source resolving inside the root must run"
assert_present "$OWN/inside-source-renamed/trailing-source-marker" \
  "the in-root trailing source directory must actually move"
pass "move sources preserve trailing-slash dereference semantics"

: > "$OWN/src/attached-target.txt"
out=$(guarded -- "$OWN" mv "-t$SIBLING" src/attached-target.txt 2>&1)
expect_code 3 $? "an attached -t outside destination must be refused"
assert_present "$OWN/src/attached-target.txt" "a refused attached -t move must keep its source"
: > "$OWN/src/clustered-target.txt"
out=$(guarded -- "$OWN" mv -ft "$SIBLING" src/clustered-target.txt 2>&1)
expect_code 3 $? "a clustered -t outside destination must be refused"
assert_present "$OWN/src/clustered-target.txt" "a refused clustered -t move must keep its source"
MV_BIN="$TMP/mv-bin"
MV_LOG="$TMP/mv.log"
mkdir -p "$MV_BIN"
: > "$MV_LOG"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${MV_LOG:?}"' > "$MV_BIN/mv"
chmod +x "$MV_BIN/mv"
guarded "PATH=$SHIMS:$MV_BIN:$PATH" "MV_LOG=$MV_LOG" -- "$OWN" \
  mv -b -S.keep src/suffix-source.txt src/suffix-destination.txt
expect_code 0 $? "an attached -S suffix on an in-root move must reach the real tool"
assert_contains "$(< "$MV_LOG")" "-S.keep" "the backup suffix must be passed through as an option value"
: > "$MV_LOG"
guarded "PATH=$SHIMS:$MV_BIN:$PATH" "MV_LOG=$MV_LOG" -- "$OWN" \
  mv -T src/no-target-source.txt outside-link
expect_code 0 $? "mv -T must preserve the final destination component"
assert_contains "$(< "$MV_LOG")" "-T" "mv -T must reach the real tool"
pass "mv attached option arguments are classified by their option semantics"

guarded -- "$OWN" rm -f src/mine.txt
expect_code 0 $? "a removal inside the worker's own worktree must run"
assert_absent "$OWN/src/mine.txt" "the worker's own file must actually be removed"
guarded -- "$OWN" rm -f "$STATE/t1.status"
expect_code 0 $? "this task's exact status file must remain usable"
assert_absent "$STATE/t1.status" "this task's exact status file must actually be removed"
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

LINKED_WORKER_NESTED="$REPO_SIBLING/nested-linked-worktree"
"$REAL_GIT" -C "$REPO" worktree add -q -b fm/worktree-guard-nested-linked "$LINKED_WORKER_NESTED"
: > "$LINKED_WORKER_NESTED/unlanded.txt"
fm_write_meta "$STATE/linked-worker.meta" "worktree=$REPO_SIBLING" "kind=ship"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/linked-worker.meta" -- "$REPO_SIBLING" \
  git worktree remove --force "$LINKED_WORKER_NESTED" 2>&1)
expect_code 3 $? "a linked worker must refuse a nested removal through its external common directory"
assert_present "$LINKED_WORKER_NESTED/unlanded.txt" \
  "the linked worker's nested worktree must survive the refused removal"
LINKED_WORKER_NESTED_REAL=$(cd "$LINKED_WORKER_NESTED" && pwd -P)
"$REAL_GIT" -C "$REPO" worktree list --porcelain | grep -qF "$LINKED_WORKER_NESTED_REAL" \
  || fail "the linked worker's nested worktree must remain registered after refusal"
pass "an external canonical common directory refuses a linked worker's nested removal"

STANDALONE_REPO="$REPO_SIBLING/standalone-repo"
STANDALONE_NESTED="$REPO_SIBLING/standalone-nested-worktree"
fm_git_worktree "$STANDALONE_REPO" "$STANDALONE_NESTED" fm/worktree-guard-standalone-nested
: > "$STANDALONE_NESTED/removable.txt"
STANDALONE_NESTED_REAL=$(cd "$STANDALONE_NESTED" && pwd -P)
guarded "FM_WORKTREE_GUARD_META=$STATE/linked-worker.meta" -- "$REPO_SIBLING" \
  git -C "$STANDALONE_REPO" worktree remove --force "$STANDALONE_NESTED"
expect_code 0 $? "an in-root standalone common directory must permit its nested removal"
assert_absent "$STANDALONE_NESTED" "the permitted standalone nested worktree must be removed"
"$REAL_GIT" -C "$STANDALONE_REPO" worktree list --porcelain | grep -qF "$STANDALONE_NESTED_REAL" \
  && fail "the permitted standalone nested worktree must be unregistered"
pass "an in-root canonical common directory permits a standalone nested removal"

out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" -- "$REPO" git worktree prune 2>&1)
expect_code 3 $? "a refused prune must exit 3"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-prune]" "the refusal must name its code"
guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" -- "$REPO" git worktree prune --dry-run >/dev/null 2>&1
expect_code 0 $? "a prune dry run changes nothing and must run"
pass "worktree pruning is refused while its dry run stays available"

NO_TIMEOUT_BIN="$TMP/no-timeout-bin"
mkdir -p "$NO_TIMEOUT_BIN"
for tool in bash basename dirname readlink mktemp sleep cat rm; do
  ln -s "$(fm_real_tool "$tool")" "$NO_TIMEOUT_BIN/$tool"
done
ln -s "$REAL_GIT" "$NO_TIMEOUT_BIN/git"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "PATH=$SHIMS:$NO_TIMEOUT_BIN" -- "$REPO" git worktree prune 2>&1)
expect_code 3 $? "git worktree prune must stay refused without timeout or gtimeout on PATH"
git -C "$REPO" worktree list --porcelain | grep -qF "$SIBLING_REAL" \
  || fail "the sibling worktree must stay registered through the portable timeout fallback"
pass "git worktree refusal uses the portable bounded-execution owner"

OTHER_REPO="$TMP/other-repo"
OTHER_WORKTREE="$TMP/other-worktree"
SCRATCH_ROOT="$TMP/scratch-space"
SCRATCH_REPO="$SCRATCH_ROOT/repo"
SCRATCH_PRUNABLE="$SCRATCH_ROOT/prunable"
SCRATCH_EXTERNAL_LINK="$SCRATCH_ROOT/external-linked"
fm_git_worktree "$OTHER_REPO" "$OTHER_WORKTREE" fm/worktree-guard-other
fm_git_worktree "$SCRATCH_REPO" "$SCRATCH_PRUNABLE" fm/worktree-guard-scratch
"$REAL_GIT" -C "$OTHER_REPO" worktree add -q -b fm/worktree-guard-external "$SCRATCH_EXTERNAL_LINK"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git "--git-dir=$OTHER_REPO/.git" -C "$SCRATCH_REPO" worktree prune 2>&1)
expect_code 3 $? "an external --git-dir prune must be refused"
assert_contains "$out" "REFUSED BY FIRSTMATE [worktree-prune]" "the selected repository refusal must name prune"
git -C "$OTHER_REPO" worktree list --porcelain | grep -qF "$(cd "$OTHER_WORKTREE" && pwd -P)" \
  || fail "the external repository's linked worktree must remain registered"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" "GIT_DIR=$OTHER_REPO/.git" -- "$REPO" \
  git -C "$SCRATCH_REPO" worktree prune 2>&1)
expect_code 3 $? "an external GIT_DIR prune must be refused"
git -C "$OTHER_REPO" worktree list --porcelain | grep -qF "$(cd "$OTHER_WORKTREE" && pwd -P)" \
  || fail "the external repository must stay registered after a GIT_DIR refusal"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git -C "$OTHER_REPO" "--work-tree=$SCRATCH_ROOT" worktree prune 2>&1)
expect_code 3 $? "--work-tree must not replace the selected repository"
git -C "$OTHER_REPO" worktree list --porcelain | grep -qF "$(cd "$OTHER_WORKTREE" && pwd -P)" \
  || fail "the repository selected alongside --work-tree must stay registered"
SHALLOW_FILE="$SCRATCH_ROOT/shallow-file"
: > "$SHALLOW_FILE"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git --shallow-file "$SHALLOW_FILE" worktree prune 2>&1)
expect_code 3 $? "a value-taking global option must not hide worktree prune"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$SCRATCH_EXTERNAL_LINK" \
  git worktree prune 2>&1)
expect_code 3 $? "a scratch linked worktree with an external common directory must be refused"
git -C "$OTHER_REPO" worktree list --porcelain | grep -qF "$(cd "$SCRATCH_EXTERNAL_LINK" && pwd -P)" \
  || fail "the scratch linked worktree must stay registered after refusal"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git "--git-dir=$OTHER_REPO/.git" -C "$SCRATCH_REPO" worktree remove absent 2>&1)
expect_code 3 $? "an external selected repository removal must be refused"
ln -s "$OTHER_REPO/.git" "$REPO/foreign-git"
out=$(guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git "--git-dir=$REPO/foreign-git" -C "$SCRATCH_REPO" worktree remove absent 2>&1)
expect_code 3 $? "a selected repository symlink outside the root must be refused"
SCRATCH_PRUNABLE_REAL=$(cd "$SCRATCH_PRUNABLE" && pwd -P)
/bin/rm -rf "$SCRATCH_PRUNABLE"
git -C "$SCRATCH_REPO" worktree list --porcelain | grep -qF "$SCRATCH_PRUNABLE_REAL" \
  || fail "the scratch repository must begin with a stale worktree registration"
guarded "FM_WORKTREE_GUARD_META=$STATE/t2.meta" \
  "FM_WORKTREE_GUARD_TEMP_ROOTS=$SCRATCH_ROOT" -- "$REPO" \
  git -C "$SCRATCH_REPO" worktree prune
expect_code 0 $? "a repository selected inside scratch must allow prune"
git -C "$SCRATCH_REPO" worktree list --porcelain | grep -qF "$SCRATCH_PRUNABLE_REAL" \
  && fail "the allowed scratch prune must actually remove the stale registration"
pass "git worktree commands judge the selected repository"

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

fm_write_meta "$STATE/unresolved.meta" "worktree=$TMP/missing-worktree" "kind=ship"
inert_case "a record whose worktree cannot be resolved" "FM_WORKTREE_GUARD_META=$STATE/unresolved.meta"

fm_write_secondmate_meta "$STATE/sm1.meta" "$OWN"
inert_case "a secondmate home, which runs a fleet of its own" "FM_WORKTREE_GUARD_META=$STATE/sm1.meta"
pass "the guard is inert wherever the worker's own root cannot be established"

# --- 5. every public shim name enforces the guard --------------------------

mkdir -p "$SIBLING/outside-empty" "$OWN/inside-empty"
out=$(guarded -- "$OWN" rmdir "$SIBLING/outside-empty" 2>&1)
expect_code 3 $? "rmdir outside the root must be refused"
assert_present "$SIBLING/outside-empty" "the outside directory must survive rmdir"
guarded -- "$OWN" rmdir "$OWN/inside-empty"
expect_code 0 $? "rmdir inside the root must run"
assert_absent "$OWN/inside-empty" "the inside directory must be removed"
: > "$SIBLING/outside-unlink"
: > "$OWN/inside-unlink"
out=$(guarded -- "$OWN" unlink "$SIBLING/outside-unlink" 2>&1)
expect_code 3 $? "unlink outside the root must be refused"
assert_present "$SIBLING/outside-unlink" "the outside file must survive unlink"
guarded -- "$OWN" unlink "$OWN/inside-unlink"
expect_code 0 $? "unlink inside the root must run"
assert_absent "$OWN/inside-unlink" "the inside file must be removed"

TREEHOUSE_BIN="$TMP/treehouse-bin"
TREEHOUSE_LOG="$TMP/treehouse.log"
mkdir -p "$TREEHOUSE_BIN"
: > "$TREEHOUSE_LOG"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${TREEHOUSE_LOG:?}"' > "$TREEHOUSE_BIN/treehouse"
chmod +x "$TREEHOUSE_BIN/treehouse"
for action in return destroy prune; do
  out=$(guarded "PATH=$SHIMS:$TREEHOUSE_BIN:$PATH" "TREEHOUSE_LOG=$TREEHOUSE_LOG" -- "$OWN" treehouse "$action" 2>&1)
  expect_code 3 $? "treehouse $action must be refused"
done
[ ! -s "$TREEHOUSE_LOG" ] || fail "refused treehouse pool commands must not reach the real tool"
guarded "PATH=$SHIMS:$TREEHOUSE_BIN:$PATH" "TREEHOUSE_LOG=$TREEHOUSE_LOG" -- "$OWN" treehouse get
expect_code 0 $? "treehouse get must pass through"
assert_contains "$(< "$TREEHOUSE_LOG")" "get" "treehouse get must reach the real tool"
pass "every public filesystem and pool shim enforces observable behavior"

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
