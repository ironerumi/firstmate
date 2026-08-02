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
The maintainer verification step is to enable Chrome's own remote-debugging attachment, establish a healthy named browser-harness connection, confirm no concurrent AWS/browser login work, and run the command against an already-expired non-production SSO profile while observing that the active tab and macOS pointer do not move.
Stop that verification immediately for a credential form, MFA prompt, unexpected origin, ambiguous account, or any focus/cursor takeover.

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

Result on 2026-08-02: all cases passed for refresh success, still-valid credentials, saved-account request data, approval, wrong origin, ambiguity, credential and MFA stops, missing attachment, timeout, same-session serialization, distinct-session concurrency, child cleanup, output redaction, repository-local direnv configuration, ordinary profiles, and static-credential refusal.

All generated ship, scout, and skill-led task instructions are covered by `tests/fm-brief.test.sh`.
`bin/fm-spawn.sh` sends the selected instruction file through one backend-agnostic launch path after resolving all verified worker runtimes, and every supported session provider uses that same launch content.
No harness-specific or session-provider-specific AWS branch exists.
