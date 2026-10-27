# Targeted lock-fallback validation

Validated target cd2d58e1604ad46a85023be42b89c6c0e2413e74 on macOS. Native Windows/MSYS was not available; the real product executables were driven with native ln, copying ln, and failing ln at the external filesystem boundary. No harness executable or login was faked. Session-lock commands identified the actual running agent's harness ancestry. No Herdr or production fleet operations were performed.

## Product evidence

- `round2-baseline-session-cli.log`: the real upstream fm-lock CLI succeeds natively, times out after six seconds with copying ln, and the target succeeds with that same copying-ln boundary.
- `round2-session-cli.log`: acquire, inspect, same-session confirmation, waiting behind a live claim holder, and reclaiming an exited claim holder in native/copying/denied modes. Public claim locks and owner generations disappear after release.
- `round2-session-husk-cli.log`: four crash/interleaving scenarios through real fm-lock invocations. A releasing CLI dies after deleting its generation; another CLI's cleanup child is orphaned; a successor CLI acquires; the resumed orphan refuses without changing the successor's public pid, private generation pid, or state tree. Exercises both claim and steal locks, pausing both at the external cleanup child and before entering the shared removal function. The latter uses a Bash DEBUG breakpoint, not a replacement product implementation.
- `round2-extension-cli.log`: actual Node lifecycle commands, crash recovery, invalid-generation rejection, and public extension bind/list/verify in native and copied-link modes. A real fixture adapter completes its protocol handshake; the binding persists; lifecycle locks fully retire.
- `round2-queue-cli.log` and `round2-queue-cli-repeat.log`: the actual drain CLI reports bounded queue/presentation waits, retains retriable decisions, and emits acknowledgement instructions only under the tested atomicity contract. Each focused native/copied-link set passed twice serially.

## Supplemental targeted process tests

`round2-lock-protocol.log` records selected lock-only cases from tests/fm-watcher-lock.test.sh, not the complete suite: contention, raw-directory compatibility, native layout parity, generation publication/retirement races, bounded handoff, invalid-generation refusal, staging litter, and Bash 5.3/3.2 identity cases. These are supporting real-process primitive tests, not independently claimed as end-user live validation.

`round2-husk-before-fix.log` uses the removal function from commit 77fb52af against the current D4c regression. The earlier child-boundary cases pass, but the newly covered pre-removal boundary fails because the live successor's pid/generation changes. The current implementation passes all four cases.

## Setup issues resolved during this turn

The stock `FM_EXTENSION_BINDING_SEGMENT=early-bind` section was first run with TMPDIR inside the worktree. The product correctly rejected the fixture package source under a Git project. Retrying with the test harness's normal self-cleaning temporary root reached an unrelated host limitation: this macOS filesystem rejects rename of a read-only directory with EACCES. A minimal disposable rename probe confirmed that restriction.

For the changed lock behavior, the focused extension driver instead prepared a legitimate immutable managed-package dataset using the real product's `pack-transfer` digest, then exercised the unmodified bind, handshake, list, verify and lock-retirement consumers. An initial fixture attempt needed its private parent directories corrected from 0755 to 0700. The final driver passes without product changes. New-package installation on this host was not validated; it is outside this lock change.

## Reproduction

`round2-live-drivers.tar.gz` preserves the disposable drivers at their original tests/.gate-* paths. Extract them into this worktree, create `.gate-test-tmp`, and run from the worktree root:

```sh
python3 tests/.gate-baseline-live.py
bash tests/.gate-session-live.sh
TMPDIR="$PWD/.gate-test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/.gate-session-husk-live.sh
TMPDIR="$PWD/.gate-test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/.gate-lock-targeted.sh
TMPDIR="$PWD/.gate-test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash tests/.gate-queue-targeted.sh
# Run the preceding queue command twice, serially.
env -u TMPDIR FM_TEST_SKIP_ORPHAN_REAP=1 FM_EXTENSION_BINDING_SECTION_CHILD=1 FM_EXTENSION_BINDING_SEGMENT=early-bind bash tests/.gate-extension-targeted.sh
```

To reproduce the expected pre-fix failure, export GATE_WORKTREE="$PWD" and GATE_OLD_REMOVE containing fm_lock_remove_path from 77fb52af, then run the targeted lock driver with GATE_REGRESSION=1. The shell wrapper tests/.gate-prefixed-lib.sh loads current production code and overrides only that historical function.

No linters, formatters, static analysis, full repository suite, pipeline controls, push, PR or CI phases were run. All disposable worktree drivers and fixture data were removed after evidence collection; no source changes remain. This is a CLI-only change, so screenshots are not applicable.
