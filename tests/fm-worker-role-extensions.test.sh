#!/usr/bin/env bash
# Fork worker-role regressions moved from the upstream Pi extension suites.
# Keep the SDK fixtures local so the upstream hosts remain unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-role-extensions)
export NODE_NO_WARNINGS=1
trap fm_test_cleanup EXIT

install_pi_branch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-ai" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$repo/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export const VERSION = "0.99.0";
export function getAgentDir() {}
export function getMarkdownTheme() {}
export class UserMessageComponent {}
export function keyHint() {}
export function createAgentSession() {}
export function createBashToolDefinition() {}
export class DefaultResourceLoader {}
export class DynamicBorder {}
export class ModelRuntime {}
export class SessionManager {}
export class ToolExecutionComponent {}
JS
  cat > "$repo/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export function getSupportedThinkingLevels() {}
export function clampThinkingLevel() {}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Text {}
export class Container {}
export class Box {}
export class Input {}
export class SelectList {}
export function fuzzyFilter() {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {};
JS
}

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() {}
export class UserMessageComponent {}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {};
JS
}

test_worker_pane_registers_nothing() {
  local repo home out status
  repo="$TMP_ROOT/worker-root"
  home="$TMP_ROOT/worker-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  out=$(PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_TASK_ID=some-task node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const calls = [];
const record = (name) => () => { calls.push(name); };
const pi = new Proxy({}, { get: (_target, name) => record(String(name)) });
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (calls.length !== 0) throw new Error(`worker pane registered Pi branch surfaces: ${calls.join(",")}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi branch extension must load without registering anything for a worker: $out"
  pass "a Pi worker pane (FM_TASK_ID) loads the branch extension inert"
}

test_pi_extension_is_inert_for_worker() {
  local repo home out status
  repo="$TMP_ROOT/pi-worker-root"
  home="$TMP_ROOT/pi-worker-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  out=$(PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_TASK_ID=some-task node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const calls = [];
const record = (name) => () => { calls.push(name); };
const pi = {
  on: record("on"),
  registerCommand: record("registerCommand"),
  registerTool: record("registerTool"),
  sendUserMessage: record("sendUserMessage"),
  events: { on: record("events.on") },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (calls.length !== 0) throw new Error(`worker pane registered Pi watch surfaces: ${calls.join(",")}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watch extension must load without registering anything for a worker"
  [ -z "$out" ] || fail "Pi watch worker stand-down printed output: $out"
  pass ".pi primary watch extension: registers nothing in a worker pane (FM_TASK_ID)"
}

fm_test_run \
  test_worker_pane_registers_nothing \
  test_pi_extension_is_inert_for_worker
