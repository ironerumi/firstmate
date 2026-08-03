# AWS SSO refresh verification

This record supports the active safety and portability guarantees of `bin/fm-aws-sso-refresh.sh`.
The script header and `--help` remain the behavior and configuration owner.

## Diagnosis boundary

The initiating trigger is an AWS-authorized operation encountering an IAM Identity Center refresh token beyond its SSO session lifetime.
The masking condition in the failing path is `aws sso login --no-browser` paired with an isolated automation profile that has no portal cookie, so no useful page appears in the operator's signed-in Chrome.
The visible symptom is a worker reporting the refresh as captain-only and stalling on a credential form even though the operator's normal Chrome session may already be authenticated.

The earliest meaningful divergence from the proven path is the browser session selected for device approval, not the AWS profile, account, role, or credential source.
Both paths use interactive IAM Identity Center login after silent refresh has expired.
The proven path reached the already-authenticated Chrome session, while the failing path reached an isolated profile.
The common command preserves `--no-browser` only to prevent AWS CLI from activating an operator tab, drains the CLI through a PTY, and sends the captured verification URL to one owned background CDP target.
It also passes `--use-device-code`, because awscli 2.33.16 `customizations/sso/utils.py:97` routes any profile with a named `sso_session` through `SSOTokenFetcherAuth` (PKCE) unless that flag is set, and `botocore/utils.py:3673-3677` then emits a single `/authorize` URL with `userCode: None`.
That PKCE page has no device request to confirm and allow, so it is outside the approved autonomous action set; an announced `/authorize` URL is reported as human-action-required instead of being driven, and the exact confirm-then-allow gate is unchanged.

The smallest safe counterfactuals are deterministic stubs in `tests/fm-aws-sso-refresh.test.sh`.
A still-valid identity skips login and browser work, an expired identity proceeds through saved-account approval and identity verification, and an unexpected origin or credential/MFA state stops before further page action.
Disconfirming evidence would be an expired-path `aws sso login` that succeeds without a verification URL, a browser driver that proves background no-focus attachment on its current help surface, or a live signed-in Chrome attachment that completes the bounded flow without any credential/MFA page.
The command accepts the first case but still verifies account and role, and its adapter selection can be extended for the second only after version-matched empirical proof.

## Installed browser-tool evaluation

Evaluation date: 2026-08-02.

`browser-harness --version` reported `0.1.0` in git install mode, while `browser-harness doctor` reported release `0.1.8` available.
The installed skill documents local Chrome CDP attachment and raw `cdp` calls.
Source inspection at local browser-harness commit `34e942f` showed that `cdp` accepts an explicit `session_id`, `Target.createTarget` is available, and the convenience `switch_tab` and `new_tab` helpers call `Target.activateTarget`.
The common adapter therefore uses raw target-scoped CDP with `background=true` and never calls those activating helpers.
After the read-only doctor proves an existing connection, it invokes the installed Browser Harness Python helpers directly instead of the CLI's auto-start path, so a connection race cannot open or focus Chrome.
The adapter also rejects a connected Chrome process with `--user-data-dir`, which prevents an isolated automation profile from masquerading as the operator's ordinary Chrome.

`browser-harness doctor` reported Chrome running but no active browser connection.
The operator's ordinary Chrome process was running without a reachable endpoint on ports 9222 or 9223.
A separate Chrome endpoint on port 9333 belonged to an isolated test profile used by concurrent project work, so it was deliberately not attached or reused.
This means the live signed-in-Chrome path was not verified on this date.

Re-checked on 2026-08-04 against the operator's ordinary signed-in Chrome, with `browser-harness` 0.1.0 (git).
That Chrome records `user-enabled` remote debugging in its own `Local State` and writes `DevToolsActivePort` for port 9222, so no browser start, restart, or reconfiguration is needed to attach.
`/json/version` on that port returns HTTP 404 because current Chrome disables HTTP discovery on the default user-data-dir, and the daemon connects through the WebSocket path recorded alongside the port instead.
A named connection was established read-only, and `SystemInfo.getProcessInfo` resolved the attached browser to the ordinary Chrome process with no `--user-data-dir`.

That attachment established one fact the deterministic suite could not: the harness daemon attaches a page session at startup and routes every non-`Target.*` call to it, so Chrome answers `SystemInfo.getProcessInfo is only supported on the browser target`.
The adapter therefore clears the daemon's default session for its browser-identity checks alone and restores it immediately, which is what makes the process-identity check reachable rather than assumed.
`tests/fm-aws-sso-refresh.test.sh` reproduces that refusal and asserts the restore, so a regression to an unroutable identity check fails deterministically.

Bounded end-to-end runs on 2026-08-04 used an isolated `HOME` holding only a copy of the non-secret profile shape, so the working AWS token cache was never written by the command; the first run left it byte-identical across all ten files.
The command recognized this tenant's portal-hosted verification URL, opened one owned background target, navigated it to the portal device page, selected nothing it was not configured to select, confirmed the request, granted access, and verified the expected account and an `AdministratorAccess`-derived role.
No credential or MFA page was reached, no credential was entered, and the operator's active tab and pointer did not move.

Two facts about this portal's device flow were established from its live pages and are now fixture-backed.
The device view renders blank-but-complete for about one second before its content appears, which is well inside the driver's four-second unrecognized-page budget, so that budget needed no change.
After the confirm step the portal routes to its own client-authorization view whose grant control is labeled `アクセスを許可`, beside a `アクセスを拒否` control, so a driver matching only `許可` stopped there with the ambiguous-request outcome.
The exact-label set now covers `allow`, `許可`, `allow access`, and `アクセスを許可`; matching stays exact rather than substring precisely because the deny control shares a substring with the grant control.

One shared-cache behavior was observed directly and is worth recording, because it looks alarming and is not.
During the successful run, the shared token for this session was refreshed in place by a concurrent consumer running under the ordinary home.
That refresh carried the ordinary home's own client registration, which the isolated home never held, while the isolated run wrote its own token under its own registration in the isolated path.
Concurrent workers therefore refresh a shared IAM Identity Center token rather than invalidating each other, and an isolated-home verification run cannot overwrite the working cache.

The installed `agent-browser` package reported version `0.5.0` from `package.json`.
Its executable rejected the version-matched discovery command `agent-browser skills get core`, and current `agent-browser --help` exposed `--cdp <port>` plus activating tab commands but no background-tab or no-focus primitive.
It therefore did not satisfy the mandatory independent browser-local channel and remains a deterministic human-action-required result rather than a fallback.
That refusal is unconditional in the command: this recorded version evidence gates it, not a runtime help probe, because a new help flag alone could not prove a background no-focus target path.

The established physical-browser route was not run.
It remains bounded legacy evidence only because physical application control cannot prove the command's no-pointer, no-global-keyboard, no-focus guarantee.
Arc was not opened or used.

## Deterministic verification

The focused suite uses stubbed AWS, direnv, browser-harness, agent-browser, and browser adapters.
It performs no network call, real login, AWS action, or browser control.

```sh
bin/fm-test-run.sh tests/fm-aws-sso-refresh.test.sh
```

Result on 2026-08-04: all cases passed for refresh success, still-valid credentials, saved-account request data, approval, unrecognized login output, ambiguity, credential and MFA stops, missing attachment, timeout, same-session serialization, distinct-session concurrency, child cleanup, output redaction, repository-local direnv configuration, ordinary profiles, and static-credential refusal.

Both device-verification URL families are covered from named fixtures rather than one hardcoded shape.
A regional `device.sso` URL and a portal-hosted `/start/#/device?user_code=...` URL each reach the adapter and refresh, while a portal device page carrying no code, and a device URL on a different Identity Center portal, both stop before the adapter.
Acceptance of the portal family is derived from the validated `expectedStartUrl` origin alone, and a mutation that neutralizes that derivation in both the login-output parser and the adapter turns the portal case red, which is the evidence that the case tests the derivation rather than passing incidentally.
A login that printed an unrecognized verification URL reports that the login printed an unrecognized verification page, distinct from the browser-side unexpected-origin outcome, so a parse failure can no longer name a subsystem that was never reached.

The embedded browser driver is executed, not merely compiled.
One case replaces `browser_harness.helpers` with an in-process CDP double that serves a scripted page sequence and records every method the driver issues, so the real driver body runs with no Chrome, no attachment, and no daemon.
It covers the approved path (saved-account selection, then `Confirm and continue`, then `Allow`, in that order), unexpected page origin, ambiguous saved accounts, an ambiguous device-request state, a credential form, and a non-Chrome (Arc) attachment.
A further scenario transcribes this Identity Center portal's own device flow from its live pages, including the blank-but-complete first render, the absence of a saved-account step on an already signed-in portal session, and the `アクセスを許可` grant beside its `アクセスを拒否` neighbor, and asserts that the driver confirms and grants without ever clicking the deny control.
It also asserts the safety invariants from inside that code path: an owned `Target.createTarget` with `background: true`, no `Input.*` pointer or keyboard injection, no `Target.activateTarget` or `Page.bringToFront`, no physical-control tool on `PATH` (`osascript`, `cliclick`, `open` tripwires), close of only the owned target, and a mode-0600 request file that is unlinked afterwards.
A mutation of the driver's confirm-button match was rejected by this case alone, which is the evidence that it exercises the driver rather than a stub.
The remaining unverified surface is the binding between the real `browser_harness.helpers.cdp` and a live Chrome, which no deterministic test can cover.

All generated ship, scout, and skill-led task instructions are covered by `tests/fm-brief.test.sh`.
`bin/fm-spawn.sh` sends the selected instruction file through one backend-agnostic launch path after resolving all verified worker runtimes, and every supported session provider uses that same launch content.
No harness-specific or session-provider-specific AWS branch exists.
