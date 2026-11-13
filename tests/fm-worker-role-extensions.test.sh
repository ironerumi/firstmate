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
import { writeFileSync } from "node:fs";

export const VERSION = process.env.FM_STUB_PI_VERSION || "0.99.0";

export function getAgentDir() {
  return "/stub-agent-dir";
}

export function getMarkdownTheme() {
  return {};
}

export function keyHint(_keybinding, description) {
  return `ctrl+o ${description}`;
}

export class ToolExecutionComponent {
  updateResult(result) {
    this.result = result;
  }
  render() {
    return (this.result?.content ?? [])
      .filter((item) => item.type === "text")
      .flatMap((item) => item.text.split("\n"));
  }
}

export class UserMessageComponent {}

export class DynamicBorder {
  constructor(color) {
    this.color = color;
  }
  invalidate() {}
  render() {
    return ["--"];
  }
}

export class ModelRuntime {
  constructor() {
    this.models = (globalThis.__fmBranchStaticModels?.() ?? []).map((model) => ({ ...model }));
    this.authenticated = new Set(this.models.filter((model) => model.storedAuth !== false).map((model) => model.provider));
    this.registeredProviderConfigs = new Map();
    // Like the real runtime, a registered provider's credentials are only
    // known once refresh() has run for it; registration alone is provisional.
    this.pendingAuth = new Set();
  }
  static async create() {
    const queuedError = globalThis.__fmModelRuntimeErrors?.shift();
    if (queuedError) throw new Error(queuedError);
    if (globalThis.__fmModelRuntimeError) throw new Error(globalThis.__fmModelRuntimeError);
    const runtime = new ModelRuntime();
    (globalThis.__fmModelRuntimes ??= []).push(runtime);
    return runtime;
  }
  registerProvider(providerId, config) {
    this.registeredProviderConfigs.set(providerId, config);
    for (const model of config.models ?? []) {
      this.models.push({ ...model, provider: providerId });
    }
    if (config.oauth || config.apiKey) this.pendingAuth.add(providerId);
  }
  async refresh(options) {
    for (const providerId of options?.providers ?? this.pendingAuth) {
      if (this.pendingAuth.delete(providerId)) this.authenticated.add(providerId);
    }
  }
  getModel(provider, id) {
    return this.models.find((model) => model.provider === provider && model.id === id);
  }
  hasConfiguredAuth(provider) {
    return this.authenticated.has(provider);
  }
}
export class DefaultResourceLoader {
  constructor(options) {
    this.options = options;
    (globalThis.__fmLoaders ??= []).push(this);
  }
  async reload() {
    this.reloaded = true;
  }
}

export class SessionManager {
  constructor(file) {
    this.file = file;
    this.entries = [];
  }
  static create(cwd, dir) {
    globalThis.__fmCreateCount = (globalThis.__fmCreateCount ?? 0) + 1;
    const sm = new SessionManager(`${dir}/created-${process.pid}-${globalThis.__fmCreateCount}.jsonl`);
    sm.created = true;
    writeFileSync(sm.file, "");
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  static open(path) {
    const sm = new SessionManager(path);
    sm.opened = true;
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  getSessionFile() {
    return this.file;
  }
  getEntries() {
    return this.entries;
  }
  buildSessionContext() {
    const model = globalThis.__fmRecordedModels?.get(this.file) ?? null;
    return { messages: model ? [{ role: "assistant", content: [], provider: model.provider, model: model.modelId }] : [], thinkingLevel: "medium", model };
  }
}

export function createBashToolDefinition(cwd, options) {
  return {
    name: "bash",
    label: "stub bash",
    description: "stub bash",
    parameters: { type: "object" },
    __cwd: cwd,
    __options: options,
    execute: async (_toolCallId, params) => {
      if (!globalThis.__fmExecuteBranchBash) return { content: [], details: undefined };
      const initial = { command: String(params.command ?? ""), cwd, env: { ...process.env } };
      const context = options.spawnHook ? options.spawnHook(initial) : initial;
      return globalThis.__fmExecuteBranchBash(context);
    },
  };
}

export async function createAgentSession(options) {
  if (globalThis.__fmCreateSessionError) throw new Error(globalThis.__fmCreateSessionError);
  globalThis.__fmCreateStarted = (globalThis.__fmCreateStarted ?? 0) + 1;
  if (globalThis.__fmCreateGate) await globalThis.__fmCreateGate;
  if (options.model && (!options.modelRuntime || !options.modelRuntime.getModel(options.model.provider, options.model.id))) {
    throw new Error(`branch runtime cannot use ${options.model.provider}/${options.model.id}`);
  }
  const persistMessages = (messages) => {
    const tracked = [...messages];
    tracked.push = (...items) => {
      for (const message of items) options.sessionManager.getEntries().push({ type: "message", message });
      return Array.prototype.push.apply(tracked, items);
    };
    return tracked;
  };
  let branchMessages = persistMessages(globalThis.__fmInitialBranchMessages ?? []);
  for (const message of branchMessages) options.sessionManager.getEntries().push({ type: "message", message });
  const session = {
    options,
    ops: [],
    get messages() {
      return branchMessages;
    },
    set messages(messages) {
      branchMessages = persistMessages(messages);
    },
    disposed: false,
    async prompt(text) {
      if (globalThis.__fmPromptGate) {
        globalThis.__fmPromptStarted = true;
        await globalThis.__fmPromptGate;
      }
      session.ops.push({ kind: "prompt", text });
      (globalThis.__fmPrompts ??= []).push(text);
      session.messages.push({ role: "user", content: text });
      await globalThis.__fmOnBranchPrompt?.({ session, text });
    },
    async sendCustomMessage(message, opts) {
      if (globalThis.__fmMirrorGate) {
        globalThis.__fmMirrorStarted = true;
        await globalThis.__fmMirrorGate;
      }
      session.ops.push({ kind: "custom", message, opts });
      (globalThis.__fmMirrors ??= []).push(message);
    },
    dispose() {
      session.disposed = true;
    },
  };
  const restoredModel = options.model
    ? { provider: options.model.provider, modelId: options.model.id }
    : globalThis.__fmRecordedModels?.get(options.sessionManager.getSessionFile());
  if (restoredModel) (globalThis.__fmRecordedModels ??= new Map()).set(options.sessionManager.getSessionFile(), restoredModel);
  (globalThis.__fmSessions ??= []).push(session);
  return { session, extensionsResult: {} };
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
// Pi's own thinking-level rules, reproduced from the installed package so the
// portable regression can drive models with different effort ceilings. The
// live guard (tests/fm-pi-branch-live-e2e.test.sh) is what proves the real
// vendor surface still behaves this way.
const EXTENDED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

export function getSupportedThinkingLevels(model) {
  if (!model.reasoning) return ["off"];
  return EXTENDED_THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}

export function clampThinkingLevel(model, level) {
  const available = getSupportedThinkingLevels(model);
  if (available.includes(level)) return level;
  const requested = EXTENDED_THINKING_LEVELS.indexOf(level);
  if (requested === -1) return available[0] ?? "off";
  for (let i = requested; i < EXTENDED_THINKING_LEVELS.length; i += 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  for (let i = requested - 1; i >= 0; i -= 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  return available[0] ?? "off";
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Text {
  constructor(text, paddingX, paddingY) {
    this.text = text;
    this.paddingX = paddingX;
    this.paddingY = paddingY;
  }
}

export class Container {
  constructor() {
    this.children = [];
  }
  addChild(child) {
    this.children.push(child);
  }
  clear() {
    this.children = [];
  }
  render() {
    return this.children.flatMap((child) => child.render?.() ?? []);
  }
}

export class Box extends Container {
  constructor(paddingX, paddingY, bgFn) {
    super();
    this.paddingX = paddingX;
    this.paddingY = paddingY;
    this.bgFn = bgFn;
  }
  setBgFn(bgFn) {
    this.bgFn = bgFn;
  }
}

export class Input {
  constructor() {
    this.value = "";
    this.focused = false;
  }
  getValue() {
    return this.value;
  }
  setValue(value) {
    this.value = value;
  }
  handleInput(data) {
    this.value = data === "\u007f" ? this.value.slice(0, -1) : this.value + data;
  }
  invalidate() {}
  render() {
    return [this.value];
  }
}

// Records every construction so a driver can assert the rows and the visible
// bound the extension asked Pi's real SelectList for. Navigation keys arrive
// as their keybinding ids because the driver's fake keybindings manager
// matches an id against the raw key data.
export class SelectList {
  constructor(items, maxVisible, theme) {
    this.items = items;
    this.maxVisible = maxVisible;
    this.theme = theme;
    this.selectedIndex = 0;
    (globalThis.__fmPickerLists ??= []).push({ items: items.map((item) => ({ ...item })), maxVisible });
  }
  handleInput(data) {
    if (data === "tui.select.down") {
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.items.length - 1);
    } else if (data === "tui.select.up") {
      this.selectedIndex = Math.max(0, this.selectedIndex - 1);
    } else if (data === "tui.select.confirm") {
      const item = this.items[this.selectedIndex];
      if (item) this.onSelect?.(item);
    } else if (data === "tui.select.cancel") {
      this.onCancel?.();
    }
  }
  getSelectedItem() {
    return this.items[this.selectedIndex] ?? null;
  }
  invalidate() {}
  render() {
    return this.items.slice(0, this.maxVisible).map((item) => item.label);
  }
}

export function fuzzyFilter(items, query, getText) {
  const needle = query.toLowerCase();
  return items.filter((item) => getText(item).toLowerCase().includes(needle));
}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties, options) {
    return { type: "object", properties, ...(options ?? {}) };
  },
  String(options) {
    return { type: "string", ...(options ?? {}) };
  },
  Number(options) {
    return { type: "number", ...(options ?? {}) };
  },
  Boolean(options) {
    return { type: "boolean", ...(options ?? {}) };
  },
  Optional(schema) {
    return { ...schema, optional: true };
  },
  Literal(value) {
    return { const: value };
  },
  Union(schemas, options) {
    return { anyOf: schemas, ...(options ?? {}) };
  },
};
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
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
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
