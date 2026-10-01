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
Within the command shapes documented below, detection is deterministic.
At the moment one of those commands runs, both halves of the question are known - the worker's own worktree root, from the durable `worktree=` line of `state/<id>.meta`, and the classified target path resolved against the process's real working directory.
So a classified target receives a 0/1 refusal rather than a judgment about intent, while the known non-goals remain outside that classification.

## What is refused, and what is always permitted

The discriminator is the resolved target path, never the command's size or apparent intent.

| Attempt | Code | Why |
| --- | --- | --- |
| `rm`, `rmdir`, `unlink` of a path outside this task's own worktree | `worktree-escape-delete` | The incident's exact shape: `rm -rf ../<sibling>` destroys another task's unlanded work. |
| `mv` with either side outside this task's own worktree | `worktree-escape-move` | A move removes the source from where it is and overwrites the destination; both sides are targets. |
| `git worktree remove` when the canonical common directory or removal target is outside the allowed set, including removal of its own root | `worktree-remove` | Deletes a checkout whose work no one has landed and its repository's shared record, while ending this task's own worktree remains firstmate's cleanup path. |
| `git worktree prune` when the canonical common directory is outside scratch | `worktree-prune` | Rewrites the repository's shared administration, which every linked sibling task depends on. |
| `treehouse return`, `treehouse destroy`, `treehouse prune` | `worktree-pool` | Terminates the checkout holding this task's unlanded work and frees its pool lease. Firstmate's teardown owns the pool. |
| `--no-verify` on `git commit`, `merge`, `cherry-pick`, `rebase`, `revert`, `am`, or `push`, and `-n` on `git commit` or `git am` | `git-skip-hooks` | The Git hooks are spawn-owned Firstmate setup, not the worker's. A hook that fails is a defect to report, and skipping it hid the 2026-09-28 guard and hook collision for 31.5 hours. `-n` is refused only where it means `--no-verify`; on `merge` and `rebase` it is `--no-stat`, on `cherry-pick` and `revert` it is `--no-commit`, and on `push` it is `--dry-run`. |

Always permitted:

- Ordinary filesystem commands against a path inside this task's own worktree, including `rm -rf` of its own build output.
- A `git worktree remove` is judged by the canonical common directory Git reports, not only by where the named worktree sits, so nesting a worktree inside the worker's own root does not by itself permit its removal.
  A real worker runs from a linked worktree whose common directory lives in the project clone outside its own root, so the guard refuses that nested removal.
  That refusal is intended because the removal rewrites shared repository administration that every sibling task depends on, and firstmate's authorized teardown path carries `FM_WORKTREE_GUARD_ALLOW=1` for that operation.
  A nested removal is permitted only when the canonical common directory is genuinely inside the worker's own root, such as for a standalone repository created there.
- This task's own private git administration directory.
  A linked worktree keeps `COMMIT_EDITMSG`, `MERGE_MSG`, and rebase state under the primary repository's `.git/worktrees/<name>/`, outside its own root, and git hooks rewrite them - the spawn-owned commit-msg hook (`bin/fm-git-strip-ai-trailers.sh`) `mv`s a temp file over `COMMIT_EDITMSG` on every commit, and project hook managers do the same to their own files.
  The guard reads the directory from the `gitdir:` line of the root's `.git` file and accepts it only when it carries a linked worktree's own `commondir` and `gitdir` markers, so a `.git` file that names the shared common directory allows nothing.
  The allowance is that one directory: the common directory beside it (objects, refs, hooks), every sibling's administration directory, and the primary checkout stay protected.
- This task's exact `state/<id>.status` file and paths under its `state/<id>.inbox/` directory - the brief itself tells a worker to `mv` its inbox messages into `handled/`.
  A sibling's records, including a dotted task ID that begins with this task's ID, and the fleet-wide records beside them stay protected.
- This task's exact `state/.keepwarm-<id>` marker and its task-specific `state/.keepwarm-tmp/<id>/` temp directory - the Claude Stop hook arms by `mktemp` there and `mv`s into the marker, then cleans the temp file up, so both sides of that rename and its removal must resolve inside the allowed set.
  The allowance is the exact marker and that task directory, not the `state/` directory: another task's marker or temp directory and the supervisor's `state/.keepwarm-selfwake` stay protected. `selfwake` is reserved and cannot be a task ID.
- The no-mistakes pipeline's own gate push, which carries `--no-verify` by design: `git push --no-verify [-o <option>] no-mistakes <ref>:refs/heads/<branch>`.
  It is allowed only when the remote is named exactly `no-mistakes`, its push URL is a no-mistakes gate repository, there is one refspec without `+`, and the destination is the current branch of the worktree the push runs in.
  `--no-verify` to any other remote, to another branch, with any other push option, or on any other verb stays refused as `git-skip-hooks`.
- This task's busy-tracking publication and lock release, the two operations the spawn-installed hook `bin/fm-busy-event.sh` runs in the supervising home's `state/` on every turn.
  The allowance is exactly `mv [-f] <state>/<id>.busy-state.tmp.<digits> <state>/<id>.busy-state`, where the destination is not a directory or a symlink to one, and `rmdir <state>/<id>.busy-state.lock` when that lock is an empty directory.
  `<state>` is the physical directory of the record, and no glob, `busy-gen`, sibling or dotted id, or `rm -rf` of the lock is covered, so the stale-lock recursive fallback stays refused and reported.
- The lock library's own bookkeeping (`bin/fm-wake-lib.sh`: owner dirs, lock links, steal mutexes, tombstones) and the process-event claim files under `bin/fm-procevent-lib.sh`'s claim root.
  Those are firstmate-owned records wherever they live, for example under a home's `state/` or `~/.local/state/firstmate/procevent-claims`, so the lock functions run their `rm`, `rmdir`, and `mv` with `FM_WORKTREE_GUARD_ALLOW=1` and nothing a worker types gains that allowance.
  Without it a guarded process could neither release nor reap a lock outside its worktree, and every failed acquisition attempt leaked an owner dir (about 207k in the 2026-09-30 incident).
  A failed attempt on a held lock now creates no owner dir at all.
- This task's own temp root (`tasktmp=` in the record, `/tmp/fm-<id>`) and the OS temp namespace. Unlanded work never lives in temp - firstmate puts each task's scratch there itself - and refusing an ordinary `rm` of a scratch file would make the guard something workers route around, which costs more than the class it catches.
- `git worktree prune --dry-run`, which changes nothing.
- `treehouse get`, `treehouse enter`, `treehouse status`, every other `git` subcommand or flag, and every command that is not one of the fronted tools.

## Proven denial boundary

The proven boundary for the command shapes it classifies includes the following cases.

- It denies `rm`, `rmdir`, `unlink`, and either side of an `mv` when the classified target resolves outside the worker's own worktree root.
- It denies a `..` path that reaches the pool directory holding sibling worktrees.
- It denies an intermediate directory symlink that leaves the root because parent components are resolved physically.
- It physically judges an `mv` destination that is an existing directory or a symlink to one, and an `mv` source written with a trailing slash.
- It physically judges `rm` and `rmdir` operands written with a trailing slash because those tools dereference the final component.
- It denies `git worktree remove` and `git worktree prune` against a protected repository by judging the canonical common directory that Git itself reports, so `-C`, `--git-dir`, `--work-tree`, `--shallow-file`, and a linked worktree whose `.git` file points elsewhere resolve correctly.
- It denies `treehouse return`, `treehouse destroy`, and `treehouse prune`.

## Known non-goals

The guard does not classify `git -C <sibling> reset --hard`, `git clean`, an editor writing over a sibling's file, or any other way to damage a checkout without removing a path.

The guard scans command strings and paths but does not share Git's or coreutils' own argument parser, so a deliberately contrived spelling that makes their interpretations disagree can evade classification.
Representative disagreements include a file literally named `-C` passed as a `--shallow-file` value, a GNU long-option abbreviation such as `mv --target=../sibling`, a dash-prefixed operand such as `git worktree remove -- -sibling`, a `..` traversal that re-enters a symlinked path, and a Git config alias that expands to `worktree remove`.
Except for the symlink re-entry case described below, these spellings require deliberate construction rather than a mistake under pressure and therefore sit outside the guard's threat model.
Several parser disagreements fail open, so the guard does not refuse a legitimate command when it cannot establish a shared interpretation.

The `..` traversal that re-enters a symlinked path is the one member of this class that can be reached accidentally rather than only by deliberate construction.
With `own/link` pointing to `sibling/subdir`, normalization judges `rm -rf own/link/../unlanded` as `own/unlanded` because it collapses `..` before resolving parent components physically, while the operating system resolves the path to `sibling/unlanded`; `mv` shares this escape.
A worker can plausibly type `..` after a symlinked path, but this remains an accepted non-goal because closing it requires resolving components in order rather than collapsing first, and successive review rounds kept surfacing further variants of the same class.

A Git alias expands inside Git after the guard has already seen and allowed the command line, including `git -c alias.destroy='worktree remove' destroy <sibling>` and an equivalent alias committed in the shared repository.

The threat model is a worker's mistake under pressure, the same as firstmate's other seatbelts, rather than an adversary composing unusual command spellings, so these documented gaps and paths handed to programs the guard does not front are not expanded into a sandbox.

## Where the root comes from

`FM_WORKTREE_GUARD_META` names this task's `state/<id>.meta`, and the guard reads `worktree=` from it on every invocation.
It reads the durable record rather than an exported copy of the path so that a relaunch, which rewrites that line, is followed instead of judged against a stale root.
The task's own git administration directory is derived from that root's `.git` file on the same read, so it follows a relaunch too.

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
- **After expansion.** Arriving at the tool rather than at a hook lets the guard see expanded globs and variables with the process's real working directory, while `..` handling follows the proven and known boundaries above.

### Why not a PreToolUse hook

The existing seatbelts in that family (`docs/arm-pretool-check.md`, `docs/cd-guard.md`, `docs/subagent-guard.md`) all guard the firstmate PRIMARY, whose harness hook configuration lives in this repo and points at `bin/` beside it.
A worker has neither: it runs in a project worktree where no firstmate hook file exists, and only some harnesses could be given one at spawn.
Claude and OpenCode accept a worktree-resident hook, Pi accepts an external extension, but Codex's lifecycle hooks do not fire for a firstmate-launched worker, Grok loads project hooks only after a trust grant firstmate cannot establish at launch, Kimi's hook surface is a global Stop hook, Muse's plugin engine is disabled in the default build, and Cursor gets no per-task hook at all (`bin/fm-spawn.sh` records the per-harness evidence).
A PreToolUse implementation would therefore have left five worker runtimes uncovered, which for this class of loss is the same as not shipping it.
The shim line covers all of them, and it is where the paths are already resolved.

## Fail open on uncertainty, closed on the verdict

Uncertainty about the environment always resolves toward running the command: no `FM_WORKTREE_GUARD_META`, an unreadable, root-less, or physically unresolvable record, a `kind=secondmate` record, an unreadable working directory, an unloadable library, or a missing, failed, timed-out, empty, or unresolvable Git repository identity read all allow.
A refusal comes only from a resolved target that is provably outside the allowed set.

For `git worktree remove` and `git worktree prune`, repository identity comes from the resolved real Git binary running the worker's original global-option prefix followed only by the read-only `rev-parse --path-format=absolute --git-common-dir` query.
The guard does not infer repository identity from the working directory, `--work-tree`, or its own command-line option model.

Path resolution first drops `.` and empty components and lets `..` pop one component against an already-physical working directory.
For a target that lexically appears inside an allowed boundary, the guard then resolves its deepest existing parent physically and re-appends any missing components lexically, so an intermediate directory symlink into a sibling worktree is refused.
An existing `mv` destination directory is resolved physically because `mv` writes into that directory, including when the destination is a symlink without a trailing slash.
A trailing slash on an `mv` source resolves that source physically because the move dereferences it, while `--strip-trailing-slashes` restores ordinary unresolved final-component treatment.
Without a trailing slash, a final symlink that `rm`, `rmdir`, or `unlink` would remove itself stays unresolved.
With a trailing slash, `rm` and `rmdir` dereference the final symlink, so the guard judges it physically and refuses it when it leaves the root.
`mv -T` or `mv --no-target-directory` keeps the unresolved final-component semantics for the destination.
If an existing parent cannot be resolved, the uncertainty allows the command under the fail-open contract.

## The escape

`FM_WORKTREE_GUARD_ALLOW=1` in the environment of the command allows a refused command deliberately.
Firstmate hands that prefix to a worker verbatim when it has authorized the removal, and every refusal names it.
It is an environment prefix rather than a flag or a state file so that an authorized exception stays visible in the command that used it.

`bin/fm-teardown.sh` exports it for itself.
Teardown is firstmate's authorized removal path - it reaches the retired task's checkout, its pool lease, and its state sidecars, all outside any worker's own worktree - and its landed-work test, not this guard, is what makes that safe.
In the ordinary case that export changes nothing, because teardown runs from a firstmate session where the guard is already inert; it is what keeps the authorized path working if teardown is ever run from a guarded pane.

## Refusals report themselves

Every refusal, from this guard and from the validation-owner guard alike, attempts to append one keyed line to the task's own status record, `FM_NM_GUARD_STATUS` or the `state/<id>.status` derived from the record:

```
blocked [at=<epoch>] [key=guard-<code>]: guard refused <tool> [<code>]; check whether the guard or the worker is wrong
```

A worker that routes around a refusal, as two workers did with `--no-verify` on 2026-09-28, can therefore still tell firstmate when the task record is writable.
Deduplication is best effort per code: while a `guard-<code>` blocker is open a repeated refusal normally writes nothing, so a retry loop cannot flood the record, and a `resolved` line carrying that key lets the next refusal report again.
A concurrent claim, resolution, or status-file reset can produce at most one duplicate blocked line, but those races do not lose the refusal report while the status record remains writable.
It names the tool and code only, never the refusal text, because that text can carry a no-mistakes run id and `bin/fm-nm-guard-lib.sh` counts a status line naming the run id as the worker's own failure report.
`bin/fm-guard-refusal-lib.sh` owns the attempt, and a missing record or a failed write never changes the refusal.
`tests/lib.sh` unbinds `FM_NM_GUARD_STATUS` and `FM_WORKTREE_GUARD_META` for every suite, so a suite run from a worker pane never reports its deliberate refusals on that pane's real record.

## Reaching the real tool

The shim has to be able to hand off to the tool it fronts under every arrangement of `PATH`, because a guard that made `rm` unreachable would cost more than the class it catches.
Its walk skips its own directory, skips any OTHER firstmate home's shim of the same name - a worker pane already carries one shim directory, so a task working on a second firstmate checkout would otherwise have two shims exec each other - and falls back to the standard system locations when `PATH` yields no usable candidate at all.
The canonical test runner preserves inherited `bin/shims` entries so every test child retains the worktree guard's command interception.
`fm_real_tool` in `tests/lib.sh` is how a fixture reaches an underlying tool without capturing the shim; it also avoids the one arrangement resolution cannot repair, where a wrapper that execs a captured shim as its "real tool" would trade places with the shim inside a single process forever.
For any wrapper that still does that, each shim carries a pid-marked backstop that stops with a diagnosable error instead of hanging.

## Cost

A guarded tool costs one short Bash process per invocation - about 18ms measured on macOS 15 with Bash 5, of which the decision itself is under 2ms - and it is paid only inside a worker's pane, for `rm`, `rmdir`, `unlink`, `mv`, `treehouse`, and `git`.
That is the same tax the validation-owner guard already pays on `git` and `no-mistakes`.

## Verification

`tests/fm-worktree-guard.test.sh` is the regression suite: the decision matrix, the allowances, the end-to-end refusal through the real shim symlinks with real files on disk, the escape, the inert cases, and the transport-loop case.
`tests/fm-worker-env-composition.test.sh` builds the worker environment from `bin/fm-worker-env-lib.sh`, the code `bin/fm-spawn.sh` sends, in a linked worktree with the temp-namespace exemption disabled, and runs every commit verb workers use, an escaping command, hook skipping, and the lock paths; it is the check that a new collision between the shims, the record, and the spawn-installed hooks fails CI instead of the fleet.
`tests/fm-backend-orca.test.sh` proves the wiring line reaches a non-default backend end to end.
[`verification/worktree-guard.md`](verification/worktree-guard.md) holds the dated evidence, including the live crewmate-pane run.
