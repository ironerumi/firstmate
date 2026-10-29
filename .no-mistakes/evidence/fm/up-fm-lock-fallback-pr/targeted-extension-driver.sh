#!/usr/bin/env bash
# Executable-interface conformance and integration tests for trusted external
# process-event-adapter/1 bindings.
#
# The suite drives only public commands, package executables, and the durable
# records those commands publish. It never asserts implementation-source bytes.
set -u

# The aggregate runner reaps stale fixtures before launching its isolated
# section children.  Repeating that global scan in each child can consume the
# coordinator's bounded startup window before a child publishes readiness.
if [ "${FM_EXTENSION_BINDING_SECTION_CHILD:-0}" = 1 ]; then
  export FM_TEST_SKIP_ORPHAN_REAP=1
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

extension_segment=${FM_EXTENSION_BINDING_SEGMENT:-all}
case "$extension_segment" in
  all|coordinator|early-bind|early-validation|early-handshake|early-integrity|matrix|matrix-runtime|lifecycle-flow|lifecycle-order|lifecycle-lock|lifecycle-runner|lifecycle-state|lifecycle-invocation-cleanup|remote-envelope|remote-activation|remote-lifecycle|remote-retirement|example|coordinator-fail|coordinator-wait|coordinator-stubborn|coordinator-pass|coordinator-late-pass|coordinator-scheduler-block|coordinator-scheduler-late) ;;
  *) printf 'unknown extension-binding segment: %s\n' "$extension_segment" >&2; exit 64 ;;
esac

HOST="$ROOT/bin/fm-extension.mjs"
PROCEVENT="$ROOT/bin/fm-procevent.sh"
TMP_ROOT_RAW=$(fm_test_tmproot fm-extension-binding)
TMP_ROOT=$(cd "$TMP_ROOT_RAW" && pwd -P)
first_bind_pid=
second_bind_pid=
handshake_orphan_pid=
concurrent_release=
race_register_pid=
race_retire_pid=
race_release=
process_race_start_pid=
process_race_retire_pid=
process_race_release=
registry_race_pid=
registry_race_release=
leaf_race_pid=
leaf_race_release=
owner_retire_pid=
owner_worker_pid=
owner_register_pid=
signal_retire_pid=
signal_worker_pid=
active_runner_pid=
active_runner_release=
remote_active_release=
unrelated_daemon_pid=
unrelated_launcher_pid=
signal_cleanup_host_pid=
signal_cleanup_group_pid=
crash_cleanup_host_pid=
crash_cleanup_group_pid=
crash_cleanup_release=
crash_silent_start_pid=
crash_silent_runner_pid=
override_crash_start_pid=
override_crash_runner_pid=
order_register_pid=
order_reconcile_pid=
order_release=
section_coordinator_pid=
extension_test_cleanup() {
  [ -z "$concurrent_release" ] || touch "$concurrent_release" 2>/dev/null || true
  [ -z "$race_release" ] || touch "$race_release" 2>/dev/null || true
  [ -z "$process_race_release" ] || touch "$process_race_release" 2>/dev/null || true
  [ -z "$registry_race_release" ] || touch "$registry_race_release" 2>/dev/null || true
  [ -z "$leaf_race_release" ] || touch "$leaf_race_release" 2>/dev/null || true
  [ -z "$race_register_pid" ] || kill -TERM "$race_register_pid" 2>/dev/null || true
  [ -z "$race_retire_pid" ] || kill -TERM "$race_retire_pid" 2>/dev/null || true
  [ -z "$process_race_start_pid" ] || kill -TERM "$process_race_start_pid" 2>/dev/null || true
  [ -z "$process_race_retire_pid" ] || kill -TERM "$process_race_retire_pid" 2>/dev/null || true
  [ -z "$registry_race_pid" ] || kill -TERM "$registry_race_pid" 2>/dev/null || true
  [ -z "$leaf_race_pid" ] || kill -TERM "$leaf_race_pid" 2>/dev/null || true
  [ -z "$owner_retire_pid" ] || kill -TERM "$owner_retire_pid" 2>/dev/null || true
  [ -z "$owner_worker_pid" ] || kill -CONT "$owner_worker_pid" 2>/dev/null || true
  [ -z "$owner_worker_pid" ] || kill -KILL "$owner_worker_pid" 2>/dev/null || true
  [ -z "$owner_register_pid" ] || kill -TERM "$owner_register_pid" 2>/dev/null || true
  [ -z "$signal_worker_pid" ] || kill -CONT "$signal_worker_pid" 2>/dev/null || true
  [ -z "$signal_worker_pid" ] || kill -KILL "$signal_worker_pid" 2>/dev/null || true
  [ -z "$signal_retire_pid" ] || kill -TERM "$signal_retire_pid" 2>/dev/null || true
  [ -z "$active_runner_release" ] || touch "$active_runner_release" 2>/dev/null || true
  [ -z "$active_runner_pid" ] || kill -TERM "$active_runner_pid" 2>/dev/null || true
  [ -z "$remote_active_release" ] || touch "$remote_active_release" 2>/dev/null || true
  [ -z "$unrelated_daemon_pid" ] || kill -KILL "$unrelated_daemon_pid" 2>/dev/null || true
  [ -z "$unrelated_launcher_pid" ] || kill -KILL "$unrelated_launcher_pid" 2>/dev/null || true
  [ -z "$signal_cleanup_host_pid" ] || kill -KILL "$signal_cleanup_host_pid" 2>/dev/null || true
  [ -z "$signal_cleanup_group_pid" ] || kill -KILL -"$signal_cleanup_group_pid" 2>/dev/null || true
  [ -z "$crash_cleanup_host_pid" ] || kill -KILL "$crash_cleanup_host_pid" 2>/dev/null || true
  [ -z "$crash_cleanup_group_pid" ] || kill -KILL -"$crash_cleanup_group_pid" 2>/dev/null || true
  [ -z "$crash_cleanup_release" ] || touch "$crash_cleanup_release" 2>/dev/null || true
  [ -z "$crash_silent_start_pid" ] || kill -TERM "$crash_silent_start_pid" 2>/dev/null || true
  [ -z "$crash_silent_runner_pid" ] || kill -TERM -"$crash_silent_runner_pid" 2>/dev/null || true
  [ -z "$override_crash_start_pid" ] || kill -TERM "$override_crash_start_pid" 2>/dev/null || true
  [ -z "$override_crash_runner_pid" ] || kill -TERM -"$override_crash_runner_pid" 2>/dev/null || true
  [ -z "$handshake_orphan_pid" ] || kill -KILL "$handshake_orphan_pid" 2>/dev/null || true
  [ -z "$order_release" ] || touch "$order_release" 2>/dev/null || true
  [ -z "$order_register_pid" ] || kill -KILL "$order_register_pid" 2>/dev/null || true
  [ -z "$order_reconcile_pid" ] || kill -TERM "$order_reconcile_pid" 2>/dev/null || true
  if [ -n "$section_coordinator_pid" ]; then
    kill -TERM "$section_coordinator_pid" 2>/dev/null || true
    wait "$section_coordinator_pid" 2>/dev/null || true
  fi
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ] && [ -f "${REMOTE_ROOT:-}/bin/fm-remote-job-lib.sh" ]; then
    (
      # worker.pid names the serving child; the copied remote helper stops its
      # known isolated supervisor tree so it cannot respawn during teardown.
      # Production libraries are linted independently by fm-lint.sh.
      # shellcheck source=/dev/null
      . "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
      fm_remote_job_stop_worker_tree "$(cat "$TMP_ROOT/remote-jobs/worker.pid")"
    ) 2>/dev/null || true
  fi
  if [ -n "$first_bind_pid" ]; then
    kill -CONT "$first_bind_pid" 2>/dev/null || true
    kill -TERM "$first_bind_pid" 2>/dev/null || true
    wait "$first_bind_pid" 2>/dev/null || true
  fi
  if [ -n "$second_bind_pid" ]; then
    kill -TERM "$second_bind_pid" 2>/dev/null || true
    wait "$second_bind_pid" 2>/dev/null || true
  fi
  chmod -R u+w "$TMP_ROOT_RAW" 2>/dev/null || true
  fm_test_cleanup
}
trap extension_test_cleanup EXIT
trap 'extension_test_cleanup; exit 130' INT
trap 'extension_test_cleanup; exit 143' TERM
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
PACKAGES="$TMP_ROOT/packages"
HOMES="$TMP_ROOT/homes"
mkdir -p "$PACKAGES" "$HOMES"

new_home() {
  mkdir -p "$1"
}

make_package() {  # <dir> <id> <adapter> [fixed-scenario] [required-consent]
  local dir=$1 id=$2 adapter=$3 fixed=${4:-good} consent=${5:-} required
  mkdir -p "$dir"
  if [ -n "$consent" ]; then
    required=$(printf '["%s"]' "$consent")
  else
    required='[]'
  fi
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
  "required_consents": $required
}
JSON
  printf '%s\n' "$fixed" > "$dir/scenario"
  printf 'complete-tree helper\n' > "$dir/helper.txt"
  cat > "$dir/entrypoint.py" <<'PY'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time

request = json.load(sys.stdin)
with open("firstmate-extension.json", encoding="utf-8") as source: manifest = json.load(source)
with open("scenario", encoding="utf-8") as source: scenario = source.read().strip().split("\n")
fixed, marker, release = (scenario + ["", ""])[:3]
verb = sys.argv[1] if len(sys.argv) > 1 else ""

def raw(value):
    if isinstance(value, bytes): sys.stdout.buffer.write(value)
    elif isinstance(value, str): sys.stdout.write(value)
    else: sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()

def handshake(**extra):
    return {"schema":"firstmate.extension-handshake-response.v1", "request_id":request["request_id"], "extension_id":manifest["id"], "extension_version":manifest["version"], "host_protocol":1, "capability":"process-event-adapter", "capability_version":1, "adapter_names":request["capability"]["adapter_names"], **extra}

def success(result, **extra):
    return {"schema":"firstmate.extension-response.v1", "request_id":request["request_id"], "ok":True, "result":result, "error":None, **extra}

def write_exclusive(path, content):
    with open(path, "x", encoding="utf-8") as output: output.write(content)

def stubborn_child():
    return subprocess.Popen([sys.executable, "-c", "import signal,time;signal.signal(signal.SIGTERM, signal.SIG_IGN);time.sleep(300)"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if verb == "handshake":
    if fixed == "handshake-nonzero": sys.exit(9)
    if fixed == "handshake-block":
        try: write_exclusive(marker, f"{os.getpid()}\n")
        except FileExistsError: pass
        else:
            while not os.path.exists(release): time.sleep(.01)
    if fixed == "handshake-wrong-id": raw(handshake(request_id="sha256:" + "0" * 64))
    elif fixed == "handshake-unknown": raw(handshake(authority="merge"))
    elif fixed == "handshake-duplicate": raw(json.dumps(handshake()).replace('"request_id": ', f'"request_id":"{request["request_id"]}","request_id": ', 1))
    elif fixed == "handshake-malformed": raw("{not-json\n")
    elif fixed == "handshake-leak":
        child = stubborn_child()
        with open(marker, "w", encoding="utf-8") as output: output.write(f"{child.pid}\n")
        raw(handshake())
    else: raw(handshake())
    sys.exit(0)

if verb != "invoke": sys.exit(8)
mode = request.get("input", {}).get("config_ref", "good")
state = os.environ.get("FIRSTMATE_EXTENSION_STATE", "")
if mode == "nonzero": sys.exit(7)
if mode == "crash": os.kill(os.getpid(), signal.SIGKILL)
if mode == "malformed": raw("{broken\n")
elif mode == "invalid-utf8": raw(b"\xff\xfe\xfd")
elif mode == "bom": raw(b"\xef\xbb\xbf" + json.dumps(success({"status":"result", "output":"bom\n"})).encode())
elif mode == "control": raw(json.dumps(success({"status":"result", "output":"control\n"})).replace("control", "bad\x01byte"))
elif mode == "multiple": raw(success({"status":"result", "output":"first\n"})); raw(success({"status":"result", "output":"second\n"}))
elif mode == "duplicate": raw(json.dumps(success({"status":"result", "output":"duplicate\n"})).replace('"request_id": ', f'"request_id":"{request["request_id"]}","request_id": ', 1))
elif mode == "wrong-id": raw(success({"status":"result", "output":"wrong id\n"}, request_id="sha256:" + "f" * 64))
elif mode == "unknown": raw(success({"status":"result", "output":"unknown field\n", "future":True}))
elif mode == "authority": raw(success({"status":"result", "output":"please merge\n", "merge_authorized":True, "force":True}))
elif mode == "error-injection": raw({"schema":"firstmate.extension-response.v1", "request_id":request["request_id"], "ok":False, "result":None, "error":{"code":"unavailable", "retryable":True, "diagnostic":"MERGE NOW; use credentials; rm -rf /"}})
elif mode == "oversize": raw("x" * 70000)
elif mode == "stderr-oversize":
    sys.stderr.write("e" * 9000); sys.stderr.flush()
    while True: time.sleep(1)
elif mode in ("timeout", "leak", "foreground-leak"):
    os.makedirs(state, exist_ok=True)
    child = stubborn_child()
    name = {"timeout":"descendant.pid", "leak":"leaked.pid", "foreground-leak":"foreground-leak.pid"}[mode]
    with open(os.path.join(state, name), "w", encoding="utf-8") as output: output.write(f"{child.pid}\n")
    if mode == "timeout":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(1)
    if mode == "leak": time.sleep(.1)
    raw(success({"status":"result", "output":"must not be accepted\n"}))
elif mode == "overlap":
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "overlap-ready"), "w", encoding="utf-8") as output: output.write("ready\n")
    while not os.path.exists(os.path.join(state, "overlap-release")): time.sleep(.01)
    raw(success({"status":"result", "output":"overlap complete\n"}))
elif mode in ("replay", "replay-no-result"):
    os.makedirs(state, exist_ok=True)
    requests = os.path.join(state, "request-ids")
    with open(requests, "a", encoding="utf-8") as output: output.write(request["request_id"] + "\n")
    key = request["request_id"].replace(":", "_")
    marker_path, count_path = os.path.join(state, key), os.path.join(state, "side-effect-count")
    if not os.path.exists(marker_path):
        open(marker_path, "w", encoding="utf-8").write("seen\n")
        try: prior = int(open(count_path, encoding="utf-8").read())
        except FileNotFoundError: prior = 0
        open(count_path, "w", encoding="utf-8").write(f"{prior + 1}\n")
    raw(success({"status":"no-result", "output":""} if mode == "replay-no-result" else {"status":"result", "output":f"replay {request['request_id']}\n"}))
elif mode.startswith("active-block|"):
    _, block_marker, block_release = mode.split("|", 2)
    write_exclusive(block_marker, f"{os.getpid()}\n")
    while not os.path.exists(block_release): time.sleep(.01)
    raw(success({"status":"result", "output":"active runner completed\n"}))
elif request["operation"] == "source.poll": raw(success({"status":"no-result" if mode == "no-result" else "result", "output":"" if mode == "no-result" else f"external evidence: {mode}\n"}))
elif request["operation"] == "result.classify": raw(success({"classification":"external-ready"}))
elif request["operation"] == "result.terminal": raw(success({"value":True}))
elif request["operation"] == "result.silent":
    content = request.get("input", {}).get("content", "")
    if content == "external evidence: crash-silent\\n":
        os.kill(os.getpid(), signal.SIGKILL)
    elif content.startswith("external evidence: silent-block|"):
        _, block_marker, block_release = content.rstrip("\n").split("|", 2)
        write_exclusive(block_marker, f"{os.getpid()}\n")
        while not os.path.exists(block_release): time.sleep(.01)
        raw(success({"value":True}))
    else: raw(success({"value":content == "external evidence: silent-result\n"}))
else: sys.exit(6)
PY
  chmod 0755 "$dir/entrypoint.py"
  chmod 0644 "$dir/firstmate-extension.json" "$dir/scenario" "$dir/helper.txt"
}

bind_package() {  # <home> <package> <adapter> [extra args...]
  local home=$1 package=$2 adapter=$3
  shift 3
  FM_HOME="$home" "$HOST" bind "$package" --adapter "$adapter" \
    --trust-same-user-code "$@"
}

binding_value() {  # <home> <id> <field>
  node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const path = process.argv[2].split(".");
    let current = value;
    for (const key of path) current = current[key];
    process.stdout.write(String(current));
  ' "$1/config/extensions.d/$2.json" "$3"
}

expect_failure() {  # <needle> <command...>
  local needle=$1 out rc=0
  shift
  out=$("$@" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "command unexpectedly succeeded: $*"
  assert_contains "$out" "$needle" "failure did not report the expected diagnostic"
}

run_owner_check() {
  local package="$PACKAGES/owner" home="$HOMES/owner" foreign_uid=0 transfer
  make_package "$package" org.example.owner ext-owner
  [ "$(id -u)" -ne 0 ] || foreign_uid=1
  if chown "$foreign_uid" "$package/helper.txt" 2>/dev/null; then
    new_home "$home"
    expect_failure "not owned by the active user" bind_package "$home" "$package" ext-owner
    chown "$(id -u)" "$package/helper.txt"
    pass "foreign-owned package code is rejected"
    transfer="$TMP_ROOT/owner-transfer.json"
    FM_HOME="$home" "$HOST" pack-transfer "$package" > "$transfer"
    mkdir -p "$home/data/extensions/staging"
    chmod 0700 "$home/data" "$home/data/extensions" "$home/data/extensions/staging"
    chown "$foreign_uid" "$home/data/extensions/staging"
    # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
    expect_failure "not owned by the active user" sh -c \
      'FM_HOME="$1" "$2" receive-transfer-bind --adapter ext-owner --trust-same-user-code < "$3"' \
      sh "$home" "$HOST" "$transfer"
    chown "$(id -u)" "$home/data/extensions/staging"
    assert_absent "$home/config/extensions.d/org.example.owner.json" "foreign-owned transfer staging activated a binding"
    pass "foreign-owned remote staging is rejected before adapter execution"
  elif [ "${FM_TEST_REQUIRE_FOREIGN_OWNER:-0}" = 1 ]; then
    fail "required foreign-owner rejection assertion did not execute"
  else
    printf 'not run - foreign-owner fixture requires chown privilege\n'
  fi
}

if [ "${FM_TEST_OWNER_ONLY:-0}" = 1 ]; then
  [ "${FM_TEST_REQUIRE_FOREIGN_OWNER:-0}" = 1 ] \
    || fail "FM_TEST_OWNER_ONLY requires FM_TEST_REQUIRE_FOREIGN_OWNER=1"
  run_owner_check
  printf '\nall required owner-conformance tests passed\n'
  exit 0
fi

wait_for_file() {
  local file=$1
  for _ in $(seq 1 100); do
    [ -s "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

wake_payloads() {
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

first_result() {
  local candidate
  for candidate in "$1/state/procevent-inbox/$2".*.result; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

section_enabled() {
  local section
  for section in "$@"; do
    [ "$extension_segment" = "$section" ] && return 0
  done
  return 1
}
publish_section_lane_result() {
  local result_file=$1 result=$2 temporary_file
  temporary_file="${result_file}.$$.tmp"
  printf '%s\n' "$result" > "$temporary_file"
  mv "$temporary_file" "$result_file"
}

publish_coordinator_marker() {
  local marker_file=$1 temporary_file
  temporary_file="${marker_file}.$$.tmp"
  printf 'ready\n' > "$temporary_file"
  mv "$temporary_file" "$marker_file"
}

terminate_section_lanes() {
  local index section_pid section_child_pid
  for index in "${!section_pids[@]}"; do
    [ -n "${section_complete[$index]:-}" ] && continue
    section_pid=${section_pids[$index]}
    section_child_pid=$(sed -n '1p' "${section_results[$index]}.pid" 2>/dev/null || true)
    case "$section_child_pid" in
      ''|*[!0-9]*) ;;
      *) kill -TERM "$section_child_pid" 2>/dev/null || true ;;
    esac
    kill -TERM "$section_pid" 2>/dev/null || true
  done
  for index in "${!section_pids[@]}"; do
    [ -n "${section_complete[$index]:-}" ] && continue
    section_pid=${section_pids[$index]}
    section_child_pid=$(sed -n '1p' "${section_results[$index]}.pid" 2>/dev/null || true)
    case "$section_child_pid" in
      ''|*[!0-9]*) ;;
      *) terminate_section_lane_child "$section_child_pid" ;;
    esac
    wait "$section_pid" 2>/dev/null || true
  done
}

terminate_section_lane_child() {
  local section_child_pid=$1 cleanup_attempt
  kill -TERM "$section_child_pid" 2>/dev/null || true
  for ((cleanup_attempt = 0; cleanup_attempt < 20; cleanup_attempt++)); do
    kill -0 "$section_child_pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$section_child_pid" 2>/dev/null && kill -KILL "$section_child_pid" 2>/dev/null || true
  wait "$section_child_pid" 2>/dev/null || true
}

run_extension_section_lane() {
  local result_file=$1 section=$2 current_section_pid='' section_rc=0
  # A backgrounded function inherits the aggregate test's cleanup traps.
  # This lane owns only its separately launched child and result publication.
  trap - EXIT HUP INT TERM
  trap 'if [ -n "$current_section_pid" ]; then terminate_section_lane_child "$current_section_pid"; fi; publish_section_lane_result "$result_file" 143; exit 143' TERM
  FM_EXTENSION_BINDING_SECTION_CHILD=1 \
    FM_EXTENSION_BINDING_SEGMENT="$section" bash "$0" &
  current_section_pid=$!
  printf '%s\n' "$current_section_pid" > "${result_file}.pid"
  wait "$current_section_pid" || section_rc=$?
  current_section_pid=
  publish_section_lane_result "$result_file" "$section_rc"
  [ -z "${FM_EXTENSION_BINDING_COORDINATOR_LANE_PUBLISHED:-}" ] \
    || printf '%s\n' "$section" > "$FM_EXTENSION_BINDING_COORDINATOR_LANE_PUBLISHED"
  return "$section_rc"
}

run_extension_section_lanes() {
  local section result_file section_rc timeout_seconds deadline index remaining launched total maximum_sections
  local active maximum_concurrent
  local -a sections=("$@")
  local -a section_pids=()
  local -a section_results=()
  local -a section_complete=()
  local section_result_root
  timeout_seconds=${FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS:-34}
  case "$timeout_seconds" in
    ''|*[!0-9]*) return 64 ;;
  esac
  [ "$timeout_seconds" -gt 0 ] && [ "$timeout_seconds" -lt 35 ] || return 64
  section_result_root=$(mktemp -d "$TMP_ROOT/section-lanes.XXXXXX") || return 1
  total=${#sections[@]}
  # Sixteen selectors are validated here. The bounded aggregate keeps its
  # required end-to-end bind/invoke/capture/retirement, registration lock-order,
  # remote, and shipped example lanes; the other conformance cuts remain
  # independently selectable.
  maximum_sections=16
  maximum_concurrent=12
  [ "$total" -le "$maximum_sections" ] || return 64
  launched=0
  active=0
  while [ "$launched" -lt "$total" ] && [ "$active" -lt "$maximum_concurrent" ]; do
    section=${sections[$launched]}
    result_file="$section_result_root/$launched.result"
    run_extension_section_lane "$result_file" "$section" &
    section_pids+=("$!")
    section_results+=("$result_file")
    section_complete+=("")
    launched=$((launched + 1))
    active=$((active + 1))
  done
  deadline=$((SECONDS + timeout_seconds))
  remaining=$total
  while [ "$remaining" -gt 0 ]; do
    for index in "${!section_pids[@]}"; do
      [ -n "${section_complete[$index]:-}" ] && continue
      result_file=${section_results[$index]}
      [ -f "$result_file" ] || continue
      section_rc=$(cat "$result_file")
      case "$section_rc" in
        0)
          wait "${section_pids[$index]}" || {
            section_rc=$?
            terminate_section_lanes
            return "$section_rc"
          }
          section_complete[index]=1
          remaining=$((remaining - 1))
          active=$((active - 1))
          ;;
        ''|*[!0-9]*)
          terminate_section_lanes
          return 125
          ;;
        *)
          terminate_section_lanes
          return "$section_rc"
          ;;
      esac
    done
    while [ "$launched" -lt "$total" ] && [ "$active" -lt "$maximum_concurrent" ]; do
      section=${sections[$launched]}
      result_file="$section_result_root/$launched.result"
      run_extension_section_lane "$result_file" "$section" &
      section_pids+=("$!")
      section_results+=("$result_file")
      section_complete+=("")
      launched=$((launched + 1))
      active=$((active + 1))
    done
    [ "$remaining" -eq 0 ] && break
    if [ "$SECONDS" -ge "$deadline" ]; then
      terminate_section_lanes
      return 124
    fi
    sleep 0.05
  done
}

if section_enabled coordinator-fail; then
  wait_for_file "${FM_EXTENSION_BINDING_COORDINATOR_READY:?}" || exit 89
  exit 91
fi

if section_enabled coordinator-wait; then
  trap 'publish_coordinator_marker "${FM_EXTENSION_BINDING_COORDINATOR_CLEANUP:?}"; exit 0' TERM
  printf '%s\n' "$$" > "${FM_EXTENSION_BINDING_COORDINATOR_PID:?}"
  publish_coordinator_marker "${FM_EXTENSION_BINDING_COORDINATOR_READY:?}"
  while :; do sleep 0.05; done
fi

if section_enabled coordinator-stubborn; then
  trap '' TERM
  printf '%s\n' "$$" > "${FM_EXTENSION_BINDING_COORDINATOR_PID:?}"
  publish_coordinator_marker "${FM_EXTENSION_BINDING_COORDINATOR_READY:?}"
  while :; do sleep 0.05; done
fi

if section_enabled coordinator-pass; then
  exit 0
fi

if section_enabled coordinator-late-pass; then
  wait_for_file "${FM_EXTENSION_BINDING_COORDINATOR_LANE_PUBLISHED:?}" || exit 90
  exit 0
fi

if section_enabled coordinator-scheduler-block; then
  wait_for_file "${FM_EXTENSION_BINDING_COORDINATOR_SCHEDULER_RELEASE:?}" || exit 92
  exit 0
fi

if section_enabled coordinator-scheduler-late; then
  publish_coordinator_marker "${FM_EXTENSION_BINDING_COORDINATOR_SCHEDULER_STARTED:?}"
  publish_coordinator_marker "${FM_EXTENSION_BINDING_COORDINATOR_SCHEDULER_RELEASE:?}"
  exit 0
fi

if [ "$extension_segment" = all ] || [ "$extension_segment" = coordinator ]; then
  unknown_segment_out=$(FM_EXTENSION_BINDING_SEGMENT=typo bash "$0" 2>&1) && fail "an unknown section selector succeeded"
  assert_contains "$unknown_segment_out" "unknown extension-binding segment: typo" "an unknown section selector was not rejected"
  assert_not_contains "$unknown_segment_out" "all extension-binding tests passed" "an unknown section selector reported success"
  pass "unknown extension conformance section selectors fail before setup"
  if [ "$extension_segment" = all ]; then
    (
      trap - EXIT HUP INT
      trap 'terminate_section_lanes; exit 143' TERM
      run_extension_section_lanes lifecycle-flow lifecycle-order remote-lifecycle example
    ) &
    section_coordinator_pid=$!
  fi
  coordinator_probe="$TMP_ROOT/coordinator-probe"
  mkdir -p "$coordinator_probe"
  coordinator_ready="$coordinator_probe/ready"
  coordinator_cleanup="$coordinator_probe/cleanup"
  coordinator_pid="$coordinator_probe/pid"
  if FM_EXTENSION_BINDING_COORDINATOR_READY="$coordinator_ready" \
    FM_EXTENSION_BINDING_COORDINATOR_CLEANUP="$coordinator_cleanup" \
    FM_EXTENSION_BINDING_COORDINATOR_PID="$coordinator_pid" \
    run_extension_section_lanes "coordinator-fail" "coordinator-wait"; then
    fail "the section coordinator accepted a failing child"
  fi
  assert_present "$coordinator_ready" "the coordinator probe did not start its waiting child"
  assert_present "$coordinator_cleanup" "the coordinator did not terminate and reap its waiting child"
  if kill -0 "$(cat "$coordinator_pid")" 2>/dev/null; then
    fail "the coordinator left its waiting child alive after a first-lane failure"
  fi
  rm -f "$coordinator_ready" "$coordinator_cleanup" "$coordinator_pid"
  if FM_EXTENSION_BINDING_COORDINATOR_READY="$coordinator_ready" \
    FM_EXTENSION_BINDING_COORDINATOR_CLEANUP="$coordinator_cleanup" \
    FM_EXTENSION_BINDING_COORDINATOR_PID="$coordinator_pid" \
    run_extension_section_lanes "coordinator-wait" "coordinator-fail"; then
    fail "the section coordinator accepted a later-lane failure"
  fi
  assert_present "$coordinator_ready" "the coordinator probe did not start its stalled earlier child"
  assert_present "$coordinator_cleanup" "the coordinator did not terminate its stalled earlier child"
  if kill -0 "$(cat "$coordinator_pid")" 2>/dev/null; then
    fail "the coordinator left its stalled earlier child alive after a later-lane failure"
  fi
  rm -f "$coordinator_ready" "$coordinator_cleanup" "$coordinator_pid"
  if ! FM_EXTENSION_BINDING_COORDINATOR_LANE_PUBLISHED="$coordinator_ready" \
    run_extension_section_lanes "coordinator-pass" "coordinator-late-pass"; then
    fail "an early successful lane prevented a later lane from publishing"
  fi
  assert_present "$coordinator_ready" "a successful lane did not publish its result"
  assert_present "$coordinator_probe" "a lane cleanup removed parent coordinator state"
  rm -f "$coordinator_ready"
  coordinator_scheduled="$coordinator_probe/scheduled"
  coordinator_release="$coordinator_probe/release"
  if ! FM_EXTENSION_BINDING_COORDINATOR_SCHEDULER_STARTED="$coordinator_scheduled" \
    FM_EXTENSION_BINDING_COORDINATOR_SCHEDULER_RELEASE="$coordinator_release" \
    run_extension_section_lanes coordinator-scheduler-block coordinator-scheduler-block \
      coordinator-scheduler-block coordinator-scheduler-block coordinator-scheduler-late; then
    fail "the section coordinator held a later lane behind an earlier wave"
  fi
  assert_present "$coordinator_scheduled" "the coordinator did not start a later lane concurrently"
  rm -f "$coordinator_scheduled" "$coordinator_release"
  if run_extension_section_lanes coordinator-pass coordinator-pass coordinator-pass coordinator-pass \
    coordinator-pass coordinator-pass coordinator-pass coordinator-pass coordinator-pass coordinator-pass \
    coordinator-pass coordinator-pass coordinator-pass coordinator-pass coordinator-pass coordinator-pass \
    coordinator-pass; then
    fail "the section coordinator accepted more than its bounded allowlist"
  fi
  if FM_EXTENSION_BINDING_COORDINATOR_TIMEOUT_SECONDS=2 \
    FM_EXTENSION_BINDING_COORDINATOR_READY="$coordinator_ready" \
    FM_EXTENSION_BINDING_COORDINATOR_PID="$coordinator_pid" \
    run_extension_section_lanes "coordinator-stubborn"; then
    fail "the section coordinator accepted a stalled child past its deadline"
  fi
  assert_present "$coordinator_ready" "the deadline probe did not start its stalled child"
  if kill -0 "$(cat "$coordinator_pid")" 2>/dev/null; then
    fail "the coordinator left its deadline child alive"
  fi
  pass "the section coordinator propagates ordered failures and bounded cleanup"
  if [ "$extension_segment" = coordinator ]; then
    printf '\nall coordinator tests passed\n'
    exit 0
  fi
  wait "$section_coordinator_pid" || fail "an isolated extension conformance section failed"
  section_coordinator_pid=
  pass "independent extension conformance sections complete through isolated public homes"
  printf '\nall extension-binding tests passed\n'
  exit 0
fi

# --- permanently inert absent-registry path ---------------------------------
if section_enabled early-bind; then
# Exercise the executable boundary without requiring Windows: this Bash payload
# deliberately has neither a shebang nor execute permission. Direct OS spawning
# must fail; an explicitly selected Bash must preserve argv and failure mapping.
SHELL_ROOT="$TMP_ROOT/lifecycle shell root"
mkdir -p "$SHELL_ROOT/bin"
cp "$HOST" "$SHELL_ROOT/bin/fm-extension.mjs"
cat > "$SHELL_ROOT/bin/fm-procevent.sh" <<'SH'
[[ -n "$BASH_VERSION" ]] || exit 98
if [[ "${*: -1}" = reject ]]; then
  printf 'fixture refused\n' >&2
  exit 23
fi
printf '%s\n' "$@"
SH
chmod 600 "$SHELL_ROOT/bin/fm-procevent.sh"
H_SHELL="$HOMES/shell"; new_home "$H_SHELL"
# The command substitution is intentionally literal to detect shell evaluation.
# shellcheck disable=SC2016
literal_arg='space ; $(exit 97) *'
for shell_command in bind retire-binding retire-transfer process-event; do
  case "$shell_command" in
    bind) expected=$(printf '%s\n' extension-bind bind "$literal_arg"); error_code=binding-failed ;;
    retire-binding) expected=$(printf '%s\n' extension-retirement binding "$literal_arg"); error_code=retirement-failed ;;
    retire-transfer) expected=$(printf '%s\n' extension-retirement transfer "$literal_arg"); error_code=retirement-failed ;;
    process-event) expected=$(printf '%s\n' extension-process-event "$literal_arg"); error_code=process-event-failed ;;
  esac
  out=$(FM_HOME="$H_SHELL" node "$SHELL_ROOT/bin/fm-extension.mjs" "$shell_command" "$literal_arg") \
    || fail "$shell_command did not launch the non-executable Bash payload"
  [ "$out" = "$expected" ] || fail "$shell_command changed literal lifecycle argv: $out"
  shell_rc=0
  out=$(FM_HOME="$H_SHELL" node "$SHELL_ROOT/bin/fm-extension.mjs" "$shell_command" reject 2>&1) || shell_rc=$?
  if [ "$shell_command" = process-event ]; then
    [ "$shell_rc" -eq 23 ] && [ "$out" = 'fixture refused' ] \
      || fail "process-event changed the lifecycle exit status or stderr: $shell_rc $out"
  else
    [ "$shell_rc" -eq 1 ] && [ "$out" = "error[$error_code]: fixture refused" ] \
      || fail "$shell_command changed the lifecycle failure mapping: $shell_rc $out"
  fi
done
pass "lifecycle wrappers use Bash without shell interpolation and preserve failure mapping"
# POSIX resolution stays on the sanitized PATH: an exported BASH is never tried.
exported_bash="$TMP_ROOT/exported bash"
real_bash=$(command -v bash)
printf '#!%s\ntouch "%s.used"\nexec "%s" "$@"\n' "$real_bash" "$exported_bash" "$real_bash" > "$exported_bash"
chmod 700 "$exported_bash"
out=$(BASH="$exported_bash" FM_HOME="$H_SHELL" node "$SHELL_ROOT/bin/fm-extension.mjs" process-event "$literal_arg") \
  || fail "process-event did not launch with an exported BASH present"
[ "$out" = "$(printf '%s\n' extension-process-event "$literal_arg")" ] || fail "process-event changed literal argv with an exported BASH: $out"
[ ! -e "$exported_bash.used" ] || fail "POSIX lifecycle resolution tried the exported BASH"
pass "POSIX lifecycle Bash resolution ignores an exported BASH"

# The host retires an inherited copied-link directory lifecycle lock with the
# generation-addressed steps of fm-wake-lib.sh. These cases enter through a
# direct Bash exec, because the public wrappers build allowlisted
# environments, and drive the host through tests/fixtures/rename-barrier.cjs.
DIRLOCK_NODE_BIN="$TMP_ROOT/dirlock-node-bin"
mkdir -p "$DIRLOCK_NODE_BIN"
# shellcheck disable=SC2016 # The shim expands its own arguments.
printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec %q "$@"\n' \
  "$(command -v ln)" > "$DIRLOCK_NODE_BIN/ln"
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
# shellcheck disable=SC2016 # Expanded by the acquiring shell.
dirlock_out=$(dirlock_node_host "$H_DIRLOCK" "" 'printf "%s\n" 12345 > "$2/pid-start"' 2>&1) || dirlock_rc=$?
dirlock_node_expect "host locked pid=" "N1: shell did not acquire a directory lifecycle lock"
[ "$dirlock_rc" -eq 1 ] && [ "$dirlock_out" = "error[lifecycle-lock-invalid]: extension lifecycle binding command is invalid" ] \
  || fail "N1: host did not admit the inherited lock and run its command: rc=$dirlock_rc $dirlock_out"
[ -z "$(dirlock_node_tree "$H_DIRLOCK")" ] || fail "N1: host left lock residue: $(dirlock_node_tree "$H_DIRLOCK")"
dirlock_node_recover "$H_DIRLOCK" "" "N1: reacquisition after retiring recorded pid-start"
exec 6>&-
pass "N1: the host retires a directory lifecycle lock with recorded pid-start and permits reacquisition"

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

fi
printf "TARGETED_EXTENSION_LOCK_COMPLETE\n"
