---
name: aws-sso-refresh
description: >-
  Agent-only procedure for an expired AWS IAM Identity Center session during already-authorized AWS work.
  Load when an AWS-authorized worker reports an expired SSO session or would otherwise classify browser approval as captain-only.
user-invocable: false
metadata:
  internal: true
---

# aws-sso-refresh

Load this when already-authorized AWS work reaches an expired IAM Identity Center session.
The expired session is not itself a captain decision.
Use the Firstmate-owned command instead of copying a project's browser recipe.

For a repository-local AWS configuration loaded by direnv, run:

```sh
<firstmate-home>/bin/fm-aws-sso-refresh.sh --direnv-root "$PWD"
```

For an ordinary AWS profile, run:

```sh
<firstmate-home>/bin/fm-aws-sso-refresh.sh --profile <profile>
```

The generated task instructions contain the concrete `<firstmate-home>` path.
Read the command's header or `--help` before first use because it owns configuration, browser selection, identity verification, locking, cleanup, and exit meanings.
Do not add its mechanics to project instructions.

Continue the authorized AWS task after exit 0.
Exit 10 means the signed-in Chrome path reached a real human boundary such as credential entry, MFA, an ambiguous saved account, an unexpected page, or missing safe attachment; report the concrete boundary to Firstmate without entering or guessing anything.
Exit 11 is a bounded timeout and exit 12 is a tool or configuration failure; report the concrete outcome rather than reclassifying either as a new AWS approval decision.
Never use Arc, static credentials, an isolated browser profile, or physical cursor and global-keyboard control around the command.

The earlier physical-browser AWS approval recipe remains legacy evidence only, not an automatic fallback.
Use it only after an explicit Firstmate steer for one bounded recovery that has been coordinated against concurrent AWS/browser work, and preserve the command's credential, MFA, account, and origin stop conditions.
