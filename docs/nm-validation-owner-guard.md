# Validation-owner guard

This document is the authoritative human-readable contract for the validation-owner guard.
`bin/fm-nm-guard-lib.sh` is the single decision owner and the single owner of reading a no-mistakes run from a worktree for this guard; firstmate's own current-state reader reads the pipeline independently through `bin/fm-nm-run-lib.sh`, so the two are deliberately uncoupled.
`bin/fm-nm-guard-shim.sh` is the transport, reached through the `bin/shims/` names it is symlinked as.

It is a worker-side sibling of the primary-session seatbelts, which share the same shape but not the same mechanism: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard (`docs/cd-guard.md`), the delegation guard (`docs/subagent-guard.md`), and the turn-end supervision guard (`docs/turnend-guard.md`).

## Purpose and boundary

One live no-mistakes run owns validation for one branch.
A worker that starts a second run, pushes a superseding commit over a live run, or abandons a run parked at an answerable gate does not merely waste the current attempt: the pipeline restarts from its first step, so every review, test, and documentation step that had already succeeded is discarded and paid for again on a diff that has only grown.

That is not a hypothetical failure mode.
Over one measured twelve-day window, 1,105 minutes of pipeline machine time - 49% of all of it - was spent on runs that never completed, and the three largest mechanical causes were exactly a worker-abandoned run, a worker push during an active run, and a replacement run started after a failure that was never reported.
None of those is a review-quality signal, and none of them is prevented by instructions alone: the rule against them already existed in `AGENTS.md` and in every generated brief, and was violated anyway.

The guard is therefore deterministic where the tool interface makes it safe, and narrow everywhere else.
It classifies what a command would do to a live run and refuses only that; it never inspects intent, never touches unrelated commands, and never blocks a shell.

## What is refused, and what is always permitted

The discriminator is ownership of the live run, never risk, size, or step name.

Refused, and only while a run attributed to this branch is active or parked:

| Attempt | Code | Why |
| --- | --- | --- |
| `no-mistakes axi run` with any flag, `no-mistakes rerun` | `nm-run-active` | Cancels the live run and restarts every completed step. |
| `git push` of the branch's own ref to its own remote | `nm-push-supersedes` | Cancels the live run as superseded; the pipeline pushes the branch itself at its push step. |
| `no-mistakes axi abort` at a gate | `nm-abandon-gate` | Discards completed work at a stage the worker could answer. |
| `no-mistakes axi abort` mid-step | `nm-abandon-run` | Same loss, decided unilaterally; whether to abandon a run is firstmate's call. |

A flagless `no-mistakes axi run` is never refused under a live run: it reattaches to the branch's own run, and only a flag or argument can start or replace one.

Refused after a terminally failed run, until the failure is reported:

| Attempt | Code | Why |
| --- | --- | --- |
| `no-mistakes axi run`, `no-mistakes rerun` | `nm-unreported-failure` | A replacement run starts from the first step and buries the evidence of why the last one failed. |

That refusal is a reporting requirement, not a prohibition.
It clears deterministically: once the task's own status file names the failed run id - which is what the brief already asks for, `blocked:` with the run id and the failing step - the replacement run is permitted.
The refusal text names the run id, the failing step, and the exact `no-mistakes axi logs --step <step> --run <id>` command that preserves the evidence, so the failure is read before it is replaced.

Always permitted, whatever the run state:

- Every inspection path: `no-mistakes axi status`, `no-mistakes axi logs`, `no-mistakes status`, `no-mistakes runs`, `no-mistakes doctor`, and any `--help`.
- Reconnection: `no-mistakes attach`.
- The continuation path: `no-mistakes axi respond` in every form, including `--action fix` on the review step. The review loop's round budget belongs to no-mistakes (`auto_fix.review`), not to this guard.
- `git push --dry-run`, which moves no remote ref.
- Every other push: another ref such as a separate proof branch, a remote other than the branch's own, or a push into another repository such as a temporary test fixture.
  The run is read in the repository the push acts on, honoring `git -C`, and `fm_nm_guard_push_scope` in `bin/fm-nm-guard-lib.sh` owns which destinations count as the branch's own.
- Every git command that is not a push, and every command that is not `no-mistakes` or `git` at all.
- Everything, unconditionally, once the attributed run is terminal and reported, or when no run is attributed to this branch. A genuinely new run after a conclusively terminal one is exactly the authorized recovery path, and the guard does not stand in its way.

## Run attribution

`fm_nm_run_state` reports one of `none`, `active`, `parked`, `failed`, `terminal`, or `unknown` for a worktree.

Attribution is by branch identity: an active run on this branch is precisely the run a second run or a push would supersede, whatever the worktree's current HEAD.
Code identity is applied only to a `failed` run, where the question is whether this worktree's work is the work that failed; a failed run whose head is not on this worktree's line of history does not gate it.

Status words are classified from three explicit lists, and anything outside them is `unknown`.
An `awaiting_approval` or `fix_review` row in the steps table promotes an `active` run to `parked`, because that is where a gate always appears while the run-level word still reads `running`.
It promotes nothing else: a `failed`, `cancelled`, `completed`, or unrecognized run word is the run's own verdict, so a run that was cancelled or that failed at a gate stays terminal, keeps its code-identity attribution, and clears through the reporting path rather than becoming an unclearable live run.

## Fail open, always

Every uncertainty resolves toward running the command:

- No `no-mistakes` on PATH, no timeout runner, a timed-out or empty query, an unreadable git worktree, an unrecognized status word, or an unloadable library: the shim execs the real tool.
- A status file that is absent or does not name the run is only consulted for the reporting requirement, and its absence counts as reported.
- The shim itself never modifies the command; it execs the real tool with the arguments it was given, unchanged.

A guard that refused work because it could not read the pipeline would cost more than the duplicate runs it prevents.

## The escape

`FM_NM_GUARD_ALLOW=1` in the environment of the command allows a refused command deliberately.
Firstmate hands that prefix to a worker verbatim when it has authorized the recovery - it is the mechanism behind "firstmate decides whether to spend a replacement run".
It is deliberately visible in the command that used it rather than hidden in session state, so an authorized exception is legible afterwards.

## Reach: one mechanism, every runtime and every backend

The shims sit at the tool boundary rather than at any harness's hook surface, which is what makes the coverage complete.

`bin/fm-spawn.sh` sends one line into the crewmate's pane before the harness launches, through `spawn_send_text_line`:

```sh
export FM_NM_GUARD_STATUS='<state>/<id>.status' PATH='<fm-root>/bin/shims':$PATH
```

- **Worker runtimes.** Every supported harness - `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `cursor`, `muse` - is launched as a command in that pane shell, so each inherits the environment, and each passes it to the shells its own tool calls run in. There is no per-harness hook to write, no trust dialog to clear, and no harness-specific payload shape to parse. A harness added later is covered on the day it is launched this way.
- **Session providers.** `spawn_send_text_line` is the backend-agnostic text path, so the same line reaches a task on `tmux`, `herdr`, `zellij`, `orca`, and `cmux` without a per-backend branch.
- **Secondmate homes.** A secondmate is launched through the same path and receives the same shims; the guard is inert there because a secondmate does not drive a validation run of its own.
- **The primary session.** Firstmate's own shell never receives the shim PATH, so nothing firstmate runs is affected.

Nothing is written into the worktree, and nothing is written into any project repository: the binding is one environment variable and one PATH entry, so teardown has nothing to clean up and no lane can inherit another lane's guard.

### Accepted non-goals

The threat model is a worker's mistake under pressure, the same as every other firstmate seatbelt:

- An invocation that resolves past the pane's PATH is not intercepted: an absolute path (`/usr/bin/git push`), `command -p`, or `env -i`. Plain `command git push` and `env git push` still search the inherited PATH and are intercepted.
- A login shell that rebuilds PATH from scratch would drop the shim entry; the fleet's harnesses inherit the exported PATH rather than rebuilding it.
- The pipeline's own push, and its own fix agents, run as children of the shared no-mistakes daemon and never inherit this PATH, so the guard cannot interfere with the pipeline doing its own work.

## Exit contract

- Allowed: the shim `exec`s the real tool, so the tool's own exit status, stdout, and stderr are unchanged, and the shim leaves no trace.
- Refused: exit status 3 and one bordered banner on stderr carrying `[<code>] <reason>`; best-effort refusal reporting follows "Refusals report themselves" below.
- Tool missing outside the shim directory: exit status 127 with a message naming the tool.

## Refusals report themselves

Every refusal attempts to append one keyed line to the task's own status record, `FM_NM_GUARD_STATUS`:

```
blocked [at=<epoch>] [key=guard-<code>]: guard refused <tool> [<code>]; check whether the guard or the worker is wrong
```

A worker that routes around a refusal can therefore still tell firstmate when the task record is writable.
Deduplication is best effort per code: while a `guard-<code>` blocker is open a repeated refusal normally writes nothing, so a retry loop cannot flood the record, and a `resolved` line carrying that key lets the next refusal report again.
A concurrent claim, resolution, or status-file reset can produce at most one duplicate blocked line, but those races do not lose the refusal report while the status record remains writable.
It names the tool and code only, never the refusal text, because that text can carry a no-mistakes run id and `bin/fm-nm-guard-lib.sh` counts a status line naming the run id as the worker's own failure report.
`bin/fm-guard-refusal-lib.sh` owns the attempt, and a missing record or a failed write never changes the refusal.
`tests/lib.sh` unbinds `FM_NM_GUARD_STATUS` for every suite, so a suite run from a worker pane never reports its deliberate refusals on that pane's real record.

## Reaching the real tool

The shim has to be able to hand off to the tool it fronts under every arrangement of `PATH`.
Its walk skips its own directory, skips any OTHER firstmate home's shim of the same name - a worker pane already carries one shim directory, so a task working on a second firstmate checkout would otherwise have two shims exec each other - and falls back to the standard system locations when `PATH` yields no usable candidate at all.
The canonical test runner preserves inherited `bin/shims` entries so every test child retains the guard's command interception.
`fm_real_tool` in `tests/lib.sh` is how a fixture reaches an underlying tool without capturing the shim; it also avoids the one arrangement resolution cannot repair, where a wrapper that execs a captured shim as its "real tool" would trade places with the shim inside a single process forever.
For any wrapper that still does that, each shim carries a pid-marked backstop that stops with a diagnosable error instead of hanging.

## Automated validation

`tests/fm-nm-guard.test.sh` owns the acceptance matrix: the permitted continuation and inspection commands under a live run, each refused duplicate-run, own-branch push, and abort path, the pushes to other refs, remotes, and repositories that stay allowed, the terminal-failed recovery sequence in both its unreported and reported forms, a genuinely new run after a terminal run, a review fix response past any round count staying allowed, non-no-mistakes tasks and unrelated commands, the fail-open degradations, and the shim's exec-through behavior including argument fidelity.

Run:

```sh
bash -n bin/fm-nm-guard-shim.sh
shellcheck bin/fm-nm-guard-shim.sh bin/fm-nm-guard-lib.sh
tests/fm-nm-guard.test.sh
```
