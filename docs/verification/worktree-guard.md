# Worktree-isolation guard verification

Repeatable evidence that the worktree-isolation guard refuses a real worker's destructive command outside its own worktree.
Current behavior, scope, and rationale are owned by [`../worktree-guard.md`](../worktree-guard.md); this page records evidence only.

Date: 2026-08-31.
Host: macOS 15.7.7 (arm64), GNU bash 5.3.9, git 2.52.0.

## Portable regression

`tests/fm-worktree-guard.test.sh` is the reusable suite and runs anywhere the rest of the portable tests run.
It drives the decision matrix through `fm_worktree_guard_decide` (every refusal code and every documented allowance, including a `cwd` already outside the root, `..` reaching the pool, an outside target after `--`, `mv -t`, `git -C`, an unknown `git` option before `worktree remove`, and the operand-versus-option shapes of `rm` and `mv`), then re-drives every refusal through the real `bin/shims` symlinks against real files: the sibling's file is asserted to survive each refusal, a real linked git worktree is asserted to still exist and still be registered after `git worktree remove --force` is refused, and the escape, the authorized-parent path, the five inert cases, the two-shim-directories-on-one-PATH case, and the wrapper-loop backstop are all asserted end to end.

```
$ bash tests/fm-worktree-guard.test.sh
ok - the decision matrix matches the documented contract
ok - the temp namespace is an explicit, configurable allowance rather than a hole
ok - rm of a sibling worktree is refused end to end and the sibling survives
ok - mv out of the home's state directory is refused end to end
ok - a dotted sibling task id cannot collide with this task's allowances
ok - intermediate symlinks cannot escape the worker's root
ok - in-root symlinks preserve the fronted tool's final-component semantics
ok - remove tools judge trailing-slash symlink targets physically
ok - move destinations follow directory symlinks without widening source semantics
ok - ordinary long options preserve move destination classification
ok - move sources preserve trailing-slash dereference semantics
ok - mv attached option arguments are classified by their option semantics
ok - the worker's own worktree, records, and scratch stay fully usable
ok - git worktree remove of a live sibling worktree is refused end to end
ok - an external canonical common directory refuses a linked worker's nested removal
ok - an in-root canonical common directory permits a standalone nested removal
ok - worktree pruning is refused while its dry run stays available
ok - git worktree refusal uses the portable bounded-execution owner
ok - git worktree commands judge the selected repository
ok - FM_WORKTREE_GUARD_ALLOW=1 allows a removal firstmate has authorized
ok - an authorized firstmate-owned parent process is not refused
ok - the cleanup path that owns worktree removal is not itself guarded
ok - the guard is inert wherever the worker's own root cannot be established
ok - every public filesystem and pool shim enforces observable behavior
ok - a second firstmate home's shims on PATH cannot loop the transport
ok - a wrapper that resolves back to the shim fails fast instead of hanging
ok - fm-worktree-guard.test.sh
```

`tests/fm-backend-orca.test.sh` proves the spawn wiring line carries `FM_WORKTREE_GUARD_META` and the shim PATH through a non-default backend's own send path.

`tests/fm-test-run.test.sh` proves the canonical runner removes every inherited `bin/shims` entry while preserving empty and newline-terminated `PATH` components.
Fixtures that deliberately construct a guarded `PATH` continue to use `fm_real_tool` where they need to reach the underlying tool.

## Live worker evidence

Run inside a genuine crewmate pane - Claude Code 2.1.251 on the tmux backend, in a Treehouse pool worktree, driven through the harness's own shell tool - with the guard armed exactly as `bin/fm-spawn.sh` arms it.
Both refused targets are deliberately paths that do not exist, so a guard that failed to fire would have been harmless rather than destructive.

```
$ env "PATH=<worktree>/bin/shims:$PATH" "FM_WORKTREE_GUARD_META=<home>/state/<id>.meta" \
    rm -f /Users/.../.treehouse/firstmate-f9ea88/8/firstmate/.fm-guard-probe-nonexistent
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  REFUSED BY FIRSTMATE [worktree-escape-delete]
●  deleting ".../8/firstmate/.fm-guard-probe-nonexistent" would destroy a path OUTSIDE this task's own
●  worktree, which is exactly how a sibling task loses unlanded work. ...
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exit=3

$ env ... git worktree remove /Users/.../.treehouse/firstmate-f9ea88/999/firstmate
●  REFUSED BY FIRSTMATE [worktree-remove]
exit=3

$ env ... rm -f <own worktree>/.fm-guard-probe
exit=0 removed=yes
```

The pane's own `PATH` already carried its home's shim directory, so this run also exercised two firstmate shim directories at once, which is the case the transport-loop assertion pins.

## Per-harness reach

The guard reads no harness output and parses no harness payload, so its verdict cannot vary by harness.
What varies is only whether a harness's shell tool inherits the pane environment, which is the same property the validation-owner guard already depends on for `git` and `no-mistakes` across `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, and `muse`.
Claude is verified live above; the rest inherit through the identical mechanism and the identical `bin/fm-spawn.sh` line.
