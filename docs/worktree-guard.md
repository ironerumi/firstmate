# Worktree-isolation guard

This document is the authoritative human-readable contract for the worktree-isolation guard.
`bin/fm-worktree-guard-lib.sh` is the single decision owner.
`bin/fm-worktree-guard-shim.sh` is its transport, reached through the `bin/shims/` names it is symlinked as, and `bin/fm-nm-guard-shim.sh` carries the same guard for `git`, which that shim already fronts.

It is a worker-side sibling of the validation-owner guard (`docs/nm-validation-owner-guard.md`) and of the primary-session seatbelts, which share the same shape but not the same mechanism: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard (`docs/cd-guard.md`), the delegation guard (`docs/subagent-guard.md`), and the turn-end supervision guard (`docs/turnend-guard.md`).

## Purpose and boundary

Firstmate hands every task its own disposable worktree, and several of them exist at once under one pool.
A worker that deletes a path outside its own worktree therefore reaches directly into another task's checkout.
That is not a hypothetical: a worker removed a sibling task's worktree and wiped work that had never been landed anywhere, which is unrecoverable in a way a bad commit is not.

Prose did not prevent it and cannot: every brief already told that worker to stay inside its own worktree.
The detection, in contrast, is completely deterministic.
At the moment the command runs, both halves of the question are known - the worker's own worktree root, from the durable `worktree=` line of `state/<id>.meta`, and the path the command is about to destroy, resolved against the process's real working directory.
So this guard is a 0/1 refusal, not a judgment about intent, and it classifies nothing else.

## What is refused, and what is always permitted

The discriminator is the resolved target path, never the command's size or apparent intent.

| Attempt | Code | Why |
| --- | --- | --- |
| `rm`, `rmdir`, `unlink` of a path outside this task's own worktree | `worktree-escape-delete` | The incident's exact shape: `rm -rf ../<sibling>` destroys another task's unlanded work. |
| `mv` with either side outside this task's own worktree | `worktree-escape-move` | A move removes the source from where it is and overwrites the destination; both sides are targets. |
| `git worktree remove` when the selected repository or removal target is outside the allowed set, including removal of its own root | `worktree-remove` | Deletes a checkout whose work no one has landed and its selected repository's shared record, while ending this task's own worktree remains firstmate's cleanup path. |
| `git worktree prune` when the selected repository is outside scratch | `worktree-prune` | Rewrites the selected repository's shared administration, which every linked sibling task depends on. |
| `treehouse return`, `treehouse destroy`, `treehouse prune` | `worktree-pool` | Terminates the checkout holding this task's unlanded work and frees its pool lease. Firstmate's teardown owns the pool. |

Always permitted:

- Every command against a path inside this task's own worktree, including `rm -rf` of its own build output and a `git worktree remove` of a worktree the worker itself nested inside its root.
- This task's exact `state/<id>.status` file and paths under its `state/<id>.inbox/` directory - the brief itself tells a worker to `mv` its inbox messages into `handled/`.
  A sibling's records, including a dotted task ID that begins with this task's ID, and the fleet-wide records beside them stay protected.
- This task's own temp root (`tasktmp=` in the record, `/tmp/fm-<id>`) and the OS temp namespace. Unlanded work never lives in temp - firstmate puts each task's scratch there itself - and refusing an ordinary `rm` of a scratch file would make the guard something workers route around, which costs more than the class it catches.
- `git worktree prune --dry-run`, which changes nothing.
- `treehouse get`, `treehouse enter`, `treehouse status`, every other `git` subcommand, and every command that is not one of the fronted tools.

Deliberate non-goals, called out so nobody reads more into the guard than it does: it does not classify `git -C <sibling> reset --hard`, `git clean`, an editor writing over a sibling's file, or any other way to damage a checkout without removing a path.
Its threat model is a worker's mistake under pressure, the same as firstmate's other seatbelts, so a path handed to a program the guard does not front is an accepted gap rather than a hole to be plugged with a sandbox.

## Where the root comes from

`FM_WORKTREE_GUARD_META` names this task's `state/<id>.meta`, and the guard reads `worktree=` from it on every invocation.
It reads the durable record rather than an exported copy of the path so that a relaunch, which rewrites that line, is followed instead of judged against a stale root.

The absence of that variable is what makes the guard inert everywhere it must be: the firstmate primary session never receives it, and neither does any process outside a spawned worker's pane.
A secondmate is excluded a second time, from `kind=secondmate` in the record itself rather than from the call site that launched it: a secondmate runs a fleet of its own, whose teardown and lease returns are precisely the commands this guard refuses.

## Reach: one mechanism, every runtime and every backend

The guard sits at the tool boundary rather than at any harness's hook surface.
`bin/fm-spawn.sh` sends one line into the worker's pane before the harness launches, through the backend-agnostic `spawn_send_text_line`:

```sh
export FM_NM_GUARD_STATUS='<state>/<id>.status' FM_WORKTREE_GUARD_META='<state>/<id>.meta' PATH='<fm-root>/bin/shims':$PATH
```

- **Worker runtimes.** Every supported harness - `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `muse` - is launched as a command in that pane shell, so each inherits the environment and passes it to the shells its own tool calls run in.
- **Session providers.** `spawn_send_text_line` is the backend-agnostic text path, so the same line reaches a task on `tmux`, `herdr`, `zellij`, `orca`, and `cmux` with no per-backend branch.
- **After expansion.** Arriving at the tool rather than at a hook is what makes the verdict exact: the guard sees the paths the tool will actually operate on, with the process's real working directory, so a glob, a variable, a `..`, or a `cd` earlier in the same command line needs no lexical guesswork.

### Why not a PreToolUse hook

The existing seatbelts in that family (`docs/arm-pretool-check.md`, `docs/cd-guard.md`, `docs/subagent-guard.md`) all guard the firstmate PRIMARY, whose harness hook configuration lives in this repo and points at `bin/` beside it.
A worker has neither: it runs in a project worktree where no firstmate hook file exists, and only some harnesses could be given one at spawn.
Claude and OpenCode accept a worktree-resident hook, Pi accepts an external extension, but Codex's lifecycle hooks do not fire for a firstmate-launched worker, Grok loads project hooks only after a trust grant firstmate cannot establish at launch, Kimi's hook surface is a global Stop hook, Muse's plugin engine is disabled in the default build, and Cursor gets no per-task hook at all (`bin/fm-spawn.sh` records the per-harness evidence).
A PreToolUse implementation would therefore have left five worker runtimes uncovered, which for this class of loss is the same as not shipping it.
The shim line covers all of them, and it is where the paths are already resolved.

## Fail open on uncertainty, closed on the verdict

Uncertainty about the environment always resolves toward running the command: no `FM_WORKTREE_GUARD_META`, an unreadable, root-less, or physically unresolvable record, a `kind=secondmate` record, an unreadable working directory, or an unloadable library all allow.
A refusal comes only from a resolved target that is provably outside the allowed set.

Path resolution first drops `.` and empty components and lets `..` pop one component against an already-physical working directory.
For a target that lexically appears inside an allowed boundary, the guard then resolves its deepest existing parent physically and re-appends any missing components lexically, so an intermediate directory symlink into a sibling worktree is refused.
An existing `mv` destination directory is resolved physically because `mv` writes into that directory, including when the destination is a symlink without a trailing slash.
A final symlink that `rm`, `rmdir`, or `unlink` would remove itself stays unresolved, and `mv -T` or `mv --no-target-directory` keeps the same final-component semantics.
If an existing parent cannot be resolved, the uncertainty allows the command under the fail-open contract.

## The escape

`FM_WORKTREE_GUARD_ALLOW=1` in the environment of the command allows a refused command deliberately.
Firstmate hands that prefix to a worker verbatim when it has authorized the removal, and every refusal names it.
It is an environment prefix rather than a flag or a state file so that an authorized exception stays visible in the command that used it.

`bin/fm-teardown.sh` exports it for itself.
Teardown is firstmate's authorized removal path - it reaches the retired task's checkout, its pool lease, and its state sidecars, all outside any worker's own worktree - and its landed-work test, not this guard, is what makes that safe.
In the ordinary case that export changes nothing, because teardown runs from a firstmate session where the guard is already inert; it is what keeps the authorized path working if teardown is ever run from a guarded pane.

## Reaching the real tool

The shim has to be able to hand off to the tool it fronts under every arrangement of `PATH`, because a guard that made `rm` unreachable would cost more than the class it catches.
Its walk skips its own directory, skips any OTHER firstmate home's shim of the same name - a worker pane already carries one shim directory, so a task working on a second firstmate checkout would otherwise have two shims exec each other - and falls back to the standard system locations when `PATH` yields no usable candidate at all.
That last case is not hypothetical: a fixture that captures `command -v <tool>` inside a worker pane captures the shim, and a closed `PATH` built from those captures contains no real tool.
`fm_real_tool` in `tests/lib.sh` is how a fixture avoids capturing the shim in the first place, and it is the fix for the one arrangement resolution cannot repair: a wrapper that execs its captured "real tool" would trade places with the shim inside a single process forever.
For any wrapper that still does that, each shim carries a pid-marked backstop that stops with a diagnosable error instead of hanging.

## Cost

A guarded tool costs one short Bash process per invocation - about 18ms measured on macOS 15 with Bash 5, of which the decision itself is under 2ms - and it is paid only inside a worker's pane, for `rm`, `rmdir`, `unlink`, `mv`, `treehouse`, and `git`.
That is the same tax the validation-owner guard already pays on `git` and `no-mistakes`.

## Verification

`tests/fm-worktree-guard.test.sh` is the regression suite: the decision matrix, the allowances, the end-to-end refusal through the real shim symlinks with real files on disk, the escape, the inert cases, and the transport-loop case.
`tests/fm-backend-orca.test.sh` proves the wiring line reaches a non-default backend end to end.
[`verification/worktree-guard.md`](verification/worktree-guard.md) holds the dated evidence, including the live crewmate-pane run.
