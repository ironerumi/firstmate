#!/usr/bin/env bash
# Node/Bash directory lifecycle-lock ownership and retirement regressions.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HOST="$ROOT/bin/fm-extension.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
TMP_ROOT_RAW=$(fm_test_tmproot fm-directory-lock-node)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
trap 'chmod -R u+w "$TMP_ROOT_RAW" 2>/dev/null || true; fm_test_cleanup' EXIT
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
PACKAGES="$TMP_ROOT/packages"
HOMES="$TMP_ROOT/homes"
mkdir -p "$PACKAGES" "$HOMES"
new_home() { mkdir -p "$1"; }

make_package() {
  local dir=$1 id=$2 adapter=$3
  mkdir -p "$dir"
  cat > "$dir/firstmate-extension.json" <<JSON
{
  "schema": "firstmate.extension-manifest.v1",
  "id": "$id",
  "version": "1.2.3",
  "host_protocols": [2, 1],
  "entrypoint": "entrypoint.py",
  "capabilities": [
    {"name": "process-event-adapter", "versions": [2, 1], "adapter_names": ["$adapter"]}
  ],
  "required_consents": []
}
JSON
  cat > "$dir/entrypoint.py" <<'PY'
#!/usr/bin/env python3
import json, sys

request = json.load(sys.stdin)
with open("firstmate-extension.json", encoding="utf-8") as source:
    manifest = json.load(source)
if sys.argv[1:] != ["handshake"]:
    sys.exit(8)
print(json.dumps({
    "schema": "firstmate.extension-handshake-response.v1",
    "request_id": request["request_id"],
    "extension_id": manifest["id"],
    "extension_version": manifest["version"],
    "host_protocol": 1,
    "capability": "process-event-adapter",
    "capability_version": 1,
    "adapter_names": request["capability"]["adapter_names"]
}))
PY
  chmod 0755 "$dir/entrypoint.py"
  chmod 0644 "$dir/firstmate-extension.json"
}


# The host retires an inherited copied-link directory lifecycle lock with the
# generation-addressed steps of fm-wake-lib.sh. These cases enter through a
# direct Bash exec, because the public wrappers build allowlisted
# environments, and drive the host through tests/fixtures/rename-barrier.cjs.
DIRLOCK_NODE_BIN="$TMP_ROOT/dirlock-node-bin"
mkdir -p "$DIRLOCK_NODE_BIN"
# shellcheck disable=SC2016 # The shim expands its own arguments.
printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec %q "$@"\n' \
  "$(fm_real_tool ln)" > "$DIRLOCK_NODE_BIN/ln"
chmod +x "$DIRLOCK_NODE_BIN/ln"

dirlock_node_case() {  # <name>; sets H_DIRLOCK and DIRLOCK_NODE_LOCK
  H_DIRLOCK="$HOMES/dirlock-$1"
  new_home "$H_DIRLOCK"
  mkdir -p "$H_DIRLOCK/state/procevent" "$H_DIRLOCK/barrier"
  mkfifo "$H_DIRLOCK/events" "$H_DIRLOCK/resume"
  DIRLOCK_NODE_LOCK="$H_DIRLOCK/state/procevent/.extension-binding-lifecycle.lock"
}

# Acquire the lifecycle lock in Bash, run <prepare> in that shell, then exec the
# host with an invalid lifecycle command under the inherited lock.
dirlock_node_host() {  # <home> <barriers> [prepare]
  local home=$1
  PATH="$DIRLOCK_NODE_BIN:$PATH" FM_HOME="$home" FM_TEST_SUBJECT=host FM_TEST_BARRIERS="$2" \
    FM_TEST_BARRIER_DIR="$home/barrier" FM_TEST_EVENTS="$home/events" FM_TEST_RESUME="$home/resume" \
    NODE_OPTIONS="--require=$ROOT/tests/fixtures/rename-barrier.cjs" bash -c '
      . "$1"
      fm_lock_try_acquire "$2" || exit 90
      [ -d "$2" ] && [ ! -L "$2" ] || exit 91
      printf "host locked pid=%s\n" "$(cat "$2/pid")" >> "$FM_TEST_EVENTS"
      eval "$4"
      FM_EXTENSION_RETIREMENT_MODE=bind FM_EXTENSION_LIFECYCLE_LOCK="$2" \
        FM_EXTENSION_LIFECYCLE_OWNER="$FM_LOCK_OWNER_DIR" exec "$3" not-a-lifecycle-command
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$DIRLOCK_NODE_LOCK" "$HOST" "${3:-}"
}

dirlock_node_expect() {  # <prefix> <failure>
  DIRLOCK_NODE_EVENT=
  IFS= read -r -t 30 DIRLOCK_NODE_EVENT <&6 || fail "$2 (no event, expected '$1')"
  case "$DIRLOCK_NODE_EVENT" in "$1"*) ;; *) fail "$2 (event '$DIRLOCK_NODE_EVENT', expected '$1')" ;; esac
}

dirlock_node_tree() {  # <home>
  (cd "$1/state/procevent" && find . -mindepth 1 -print | LC_ALL=C sort)
}

# Recover the lock from the shell and require nothing left behind.
dirlock_node_recover() {  # <home> <expected-recovered-pid> <failure>
  local out
  # shellcheck disable=SC2016 # Expanded by the recovering shell.
  out=$(PATH="$DIRLOCK_NODE_BIN:$PATH" FM_HOME="$1" FM_LOCK_STALE_AFTER=0 bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || { echo refused; exit 0; }
    echo "recovered=$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$DIRLOCK_NODE_LOCK")
  [ "$out" = "recovered=$2" ] || fail "$3: shell recovery returned $out"
  [ -z "$(dirlock_node_tree "$1")" ] || fail "$3: residue $(dirlock_node_tree "$1")"
}

# N1: the host admits the record Bash wrote, then retires it completely.
dirlock_node_case n1
exec 6<> "$H_DIRLOCK/events"
dirlock_rc=0
dirlock_out=$(dirlock_node_host "$H_DIRLOCK" "" 2>&1) || dirlock_rc=$?
dirlock_node_expect "host locked pid=" "N1: shell did not acquire a directory lifecycle lock"
[ "$dirlock_rc" -eq 1 ] && [ "$dirlock_out" = "error[lifecycle-lock-invalid]: extension lifecycle binding command is invalid" ] \
  || fail "N1: host did not admit the inherited lock and run its command: rc=$dirlock_rc $dirlock_out"
[ -z "$(dirlock_node_tree "$H_DIRLOCK")" ] || fail "N1: host left lock residue: $(dirlock_node_tree "$H_DIRLOCK")"
exec 6>&-
pass "N1: the host admits an inherited directory lifecycle lock and retires it without residue"

# N2 and N3: a host killed before its first rename, after committing, or in the
# middle of deleting its generation leaves a state the shell finishes.
for dirlock_spec in retire:pre retire:post discard:partial; do
  dirlock_node_case "n-${dirlock_spec%%:*}-${dirlock_spec##*:}"
  exec 6<> "$H_DIRLOCK/events"
  dirlock_rc=0
  dirlock_node_host "$H_DIRLOCK" "$dirlock_spec:kill:$DIRLOCK_NODE_LOCK" > /dev/null 2>&1 || dirlock_rc=$?
  dirlock_node_expect "host locked pid=" "N2/N3: shell did not acquire a directory lifecycle lock"
  dirlock_host_pid=${DIRLOCK_NODE_EVENT##*pid=}
  dirlock_node_expect "host $dirlock_spec:$DIRLOCK_NODE_LOCK pid=$dirlock_host_pid" \
    "N2/N3: the releasing host did not reach $dirlock_spec"
  if [ "$dirlock_rc" -ne 137 ] || kill -0 "$dirlock_host_pid" 2>/dev/null; then
    fail "N2/N3: host was not killed at $dirlock_spec (rc=$dirlock_rc)"
  fi
  dirlock_generation=$(cd "$DIRLOCK_NODE_LOCK" && echo .owner.*)
  case "$dirlock_spec" in
    retire:pre)
      [ "$(cat "$DIRLOCK_NODE_LOCK/pid")" = "$dirlock_host_pid" ] && [ -f "$DIRLOCK_NODE_LOCK/$dirlock_generation/pid" ] \
        || fail "N2: host changed the record before its commit: $(dirlock_node_tree "$H_DIRLOCK")" ;;
    retire:post)
      [ ! -e "$DIRLOCK_NODE_LOCK/pid" ] && [ -f "$DIRLOCK_NODE_LOCK/$dirlock_generation/pid.retired" ] \
        || fail "N3: host kill after commit is not a committed retirement: $(dirlock_node_tree "$H_DIRLOCK")" ;;
    discard:partial)
      [ ! -e "$DIRLOCK_NODE_LOCK/pid" ] && [ -f "$DIRLOCK_NODE_LOCK/$dirlock_generation/pid" ] \
        && [ ! -e "$DIRLOCK_NODE_LOCK/$dirlock_generation/pid.retired" ] \
        || fail "N3: host kill mid-delete is not a partly deleted generation: $(dirlock_node_tree "$H_DIRLOCK")" ;;
  esac
  dirlock_node_recover "$H_DIRLOCK" "$dirlock_host_pid" "N2/N3 $dirlock_spec"
  exec 6>&-
done
pass "N2/N3: a host killed before, after or during its retirement leaves a lock the shell recovers"

# N4: a paused host's retirement is addressed only to its own generation.
dirlock_node_case n4
exec 6<> "$H_DIRLOCK/events" 7<> "$H_DIRLOCK/resume"
dirlock_node_host "$H_DIRLOCK" "retire:pre:wait:$DIRLOCK_NODE_LOCK" > "$H_DIRLOCK/host.out" 2>&1 &
dirlock_host_job=$!
dirlock_node_expect "host locked pid=" "N4: shell did not acquire a directory lifecycle lock"
dirlock_host_pid=${DIRLOCK_NODE_EVENT##*pid=}
dirlock_node_expect "host retire:pre:$DIRLOCK_NODE_LOCK pid=$dirlock_host_pid" "N4: the releasing host did not reach its rename"
FM_HOME="$H_DIRLOCK" bash -c '. "$1"; fm_lock_remove_path "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$DIRLOCK_NODE_LOCK" \
  || fail "N4: could not retire the host's generation"
sleep 300 &
dirlock_live=$!
mkdir -p "$DIRLOCK_NODE_LOCK.owner.live04/.owner.live04"
printf '%s\n' "$dirlock_live" > "$DIRLOCK_NODE_LOCK.owner.live04/pid"
printf '%s\n' "$dirlock_live" > "$DIRLOCK_NODE_LOCK.owner.live04/.owner.live04/pid"
mv "$DIRLOCK_NODE_LOCK.owner.live04" "$DIRLOCK_NODE_LOCK"
printf 'go\n' >&7
dirlock_rc=0
wait "$dirlock_host_job" || dirlock_rc=$?
[ "$dirlock_rc" -eq 1 ] || fail "N4: host did not fail after losing its generation: rc=$dirlock_rc"
assert_contains "$(cat "$H_DIRLOCK/host.out")" "error[lifecycle-lock-lost]" "N4: host did not report the lost lifecycle lock"
[ "$(cat "$DIRLOCK_NODE_LOCK/pid")" = "$dirlock_live" ] && [ -f "$DIRLOCK_NODE_LOCK/.owner.live04/pid" ] \
  || fail "N4: host retirement touched the live successor: $(dirlock_node_tree "$H_DIRLOCK")"
kill "$dirlock_live"
wait "$dirlock_live" 2>/dev/null || true
exec 6>&- 7>&-
pass "N4: a paused host cannot retire a successor's directory lifecycle lock"

# N5: an unknown entry in the lock wedges only the final rmdir, as on main; the
# host still reports its command's own result and leaves just the junk husk,
# which keeps the lock refused to the next acquirer until the entry is removed.
dirlock_node_case n5
exec 6<> "$H_DIRLOCK/events"
dirlock_rc=0
# shellcheck disable=SC2016 # Expanded by the acquiring shell.
dirlock_out=$(dirlock_node_host "$H_DIRLOCK" "" ': > "$2/.pid.interrupted"' 2>&1) || dirlock_rc=$?
dirlock_node_expect "host locked pid=" "N5: shell did not acquire a directory lifecycle lock"
[ "$dirlock_rc" -eq 1 ] && [ "$dirlock_out" = "error[lifecycle-lock-invalid]: extension lifecycle binding command is invalid" ] \
  || fail "N5: host did not report its own command result over a junk husk: rc=$dirlock_rc $dirlock_out"
[ "$(dirlock_node_tree "$H_DIRLOCK")" = "./.extension-binding-lifecycle.lock
./.extension-binding-lifecycle.lock/.pid.interrupted" ] \
  || fail "N5: host did not leave exactly the junk husk: $(dirlock_node_tree "$H_DIRLOCK")"
exec 6>&-
pass "N5: a junk entry leaves only a husk after the host deletes its generation"

# N6: an ambiguous directory record is rejected before retirement.
dirlock_node_case n6
mkdir -p "$DIRLOCK_NODE_LOCK/.owner.a" "$DIRLOCK_NODE_LOCK/.owner.b"
dirlock_rc=0
dirlock_out=$(FM_HOME="$H_DIRLOCK" bash -c '
  printf "%s\n" "$$" > "$2/pid"
  printf "%s\n" "$$" > "$2/.owner.a/pid"
  printf "%s\n" "$$" > "$2/.owner.b/pid"
  FM_EXTENSION_RETIREMENT_MODE=bind FM_EXTENSION_LIFECYCLE_LOCK="$2" \
    FM_EXTENSION_LIFECYCLE_OWNER="$2/.owner.a" exec "$3" not-a-lifecycle-command
' _ "$ROOT/bin/fm-wake-lib.sh" "$DIRLOCK_NODE_LOCK" "$HOST" 2>&1) || dirlock_rc=$?
if [ "$dirlock_rc" -eq 1 ]; then
  assert_contains "$dirlock_out" "error[lifecycle-lock-invalid]" \
    "N6: ambiguous directory record was not rejected"
else
  fail "N6: ambiguous directory record returned an unexpected result: rc=$dirlock_rc $dirlock_out"
fi
[ "$(dirlock_node_tree "$H_DIRLOCK")" = "./.extension-binding-lifecycle.lock
./.extension-binding-lifecycle.lock/.owner.a
./.extension-binding-lifecycle.lock/.owner.a/pid
./.extension-binding-lifecycle.lock/.owner.b
./.extension-binding-lifecycle.lock/.owner.b/pid
./.extension-binding-lifecycle.lock/pid" ] \
  || fail "N6: ambiguous directory record was mutated: $(dirlock_node_tree "$H_DIRLOCK")"
pass "N6: an ambiguous directory record is rejected without retirement"

P_GOOD="$PACKAGES/good"
make_package "$P_GOOD" org.example.good ext-good

# The host inherits a lock from the shell wrapper. A copied-link capability
# result must preserve that ownership across exec and release both directories.
H_DIRECTORY_LOCK="$HOMES/directory-lock"
new_home "$H_DIRECTORY_LOCK"
mkdir -p "$TMP_ROOT/copy-ln-bin"
cat > "$TMP_ROOT/copy-ln-bin/ln" <<'SH'
#!/usr/bin/env bash
printf 'copied\n' >> "$FM_TEST_COPY_LOG"
exec cp -R "$2" "$3"
SH
chmod +x "$TMP_ROOT/copy-ln-bin/ln"
# Enter through the public shell wrapper: the Node convenience wrapper
# intentionally sanitizes PATH before invoking it and would drop this shim.
out=$(PATH="$TMP_ROOT/copy-ln-bin:$PATH" FM_TEST_COPY_LOG="$TMP_ROOT/copied-ln.log" \
  FM_HOME="$H_DIRECTORY_LOCK" "$PROCEVENT" extension-bind bind "$P_GOOD" \
  --adapter ext-good --trust-same-user-code --timeout-ms 1000) \
  || fail "extension binding rejected an inherited directory lifecycle lock"
assert_present "$TMP_ROOT/copied-ln.log" "copying ln shim must actually force directory acquisition"
assert_contains "$out" "verified: process-event-adapter/1" "directory lifecycle lock must authorize a real binding"
assert_contains "$(FM_HOME="$H_DIRECTORY_LOCK" "$HOST" list)" "org.example.good" "directory lifecycle lock must publish the binding"
assert_absent "$H_DIRECTORY_LOCK/state/procevent/.extension-binding-lifecycle.lock" "host did not release its directory lifecycle lock"
[ -z "$(find "$H_DIRECTORY_LOCK/state/procevent" -name '*.owner.*' -print)" ] \
  || fail "host did not release its directory lock owner token"
pass "extension binding inherits, validates and releases a copied-link directory lock"
