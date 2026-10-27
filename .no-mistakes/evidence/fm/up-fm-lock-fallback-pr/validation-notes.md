# Targeted lock-fallback validation

Target: 183f3190104d313503ad851adf14526558c8c045. Host: macOS; Bash 5.3 and stock Bash 3.2.

## Independent behavioral oracles

- A session acquire must finish and identify the actual running harness; a competing live claim holder must prevent publication until release. A dead holder must be reclaimable. `session-live.log` records real `bin/fm-lock.sh` output and persisted directory records with `ln -s` copying. `session-native.log` exercises the same public commands with real symlinks. The current real pi harness (not an impersonated CLI) supplies session ancestry; only marked disposable FM_HOME state was used.
- Mutual exclusion forbids a delayed cleanup from changing a live successor. `husk-cli-live.log` records the real public CLI releaser dying after deleting its generation, a subsequent acquirer's orphaned rmdir, successor acquisition, and unchanged pid/generation after the orphan resumes. `husk-cli-boundary-live.log` pauses at the public CLI's captured-husk removal invocation using a Bash DEBUG barrier, hands its captured arguments to a delayed continuation, kills that acquirer, and checks the successor survives the resumed production removal function. All test labs were removed.
- `test_dirlock_d4c_orphan_husk_cleanup_preserves_successor` fails against commit 77fb52af with “orphaned acquire-boundary cleanup changed the live successor's pid or generation”, and passes against the target, including acquire/reap and pre-removal boundary variants. The pre-fix library was materialized only in a disposable fixture; target files were not replaced.
- A valid directory lifecycle lock must authorize a real extension handshake and be released completely; ambiguous records must be rejected without mutation; interrupted retirement and delayed cleanup must preserve recovery and successor ownership. `extension-focused.log` shows the real shell/Node commands, successful binding, listing, and inspection. `extension-focused.trace` records N1–N6 protocol events and observed persisted state.
- `queue-cli-transcript.log` contains real drain output under held queue/presentation locks, retry output and acknowledgement tokens. Targeted assertions also verify acknowledgement waits for the independent queue lock and replay remains possible until acknowledgement succeeds.

## Focused checks executed

Generated temporary selection drivers loaded the existing test definitions and invoked only:

- `tests/fm-watcher-lock.test.sh`: raw-directory reaper/release, real-symlink layout, copied-link portability, 10 rounds of 8 directory contenders, D1/D2/D3/D7/D17 on Bash 5.3 and 3.2, D1b, D4/D4b/D4c, D5/D5b/D5c, D6, D7b, D8/D8b, D9, D10, D11/D11b, D12.
- `tests/fm-wake-queue.test.sh`: bounded handoff in native/copied modes and `with_copied_link_locks test_live_presentation_holder_is_deadlined_without_weakening_ack`.
- `tests/fm-extension-binding.test.sh`: attempted `FM_EXTENSION_BINDING_SEGMENT=early-bind`; then selected N1–N6 and a real public copied-link bind/list/inspect flow with a preinstalled disposable package.

No full suite, linter, formatter, static analysis, push, PR or CI phase was run. No source changes remain.

## Setup limitations and reruns

The initial parallel queue check observed 7 seconds against its existing 4-second assertion. Three subsequent runs passed, including two serial runs; retain as a load-sensitive timing warning rather than hiding the original result.

The extension aggregate first rejected package fixtures inside Git, as designed. Moving temporary fixture/evidence output into this evidence directory cleared that guard. The host then rejected rename of a 0555 directory with EACCES. A separate Python filesystem probe reproduced this without Firstmate. Docker is on PATH, but `docker info --format '{{.OSType}}'` failed because `/var/run/docker.sock` has no daemon. The lock-specific live bind was therefore driven using a valid preinstalled disposable package, identified by the real `pack-transfer` command and validated by the unmodified product. Package installation itself is outside this change.

An initial diagnostic `bash -x` attempt contaminated captured stderr; it was corrected by separating tracing onto `BASH_XTRACEFD=19`. Later evidence runs use that separation.

No Windows runtime was available: this run proves forced-copy publication behavior and real macOS CLI integration, not native Git Bash execution. The surface is CLI/protocol-only, so no screenshot is applicable.
