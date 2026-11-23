# Fork main is green upstream plus one commit per carried item

## Context

This repository is a fork of `kunchenguid/firstmate`.
Every fork change has to be judged on its own: keep it as a fork patch, move it to another owner, contribute it upstream, or drop it.
A merge-shaped history cannot show that, because one feature's lines end up spread across many commits, fix rounds, and merge resolutions.
Homes follow the `release` branch (`config/self-update-source`), and `bin/fm-update.sh` skips a primary home whose history has diverged, so whatever homes follow must only move forward.

## Decision

`main` is the newest green upstream commit plus exactly one commit per carried item, linear, with no merge commits.
`git log --oneline reference/main..origin/main` is the fork's inventory: each title names one feature or fix, and each body says what it does, why the fork carries it, and where upstream stands.
Titles starting `fork:` are items the fork keeps; `fix:` and `test:` items are carried until upstream lands an equivalent, then dropped.
A change is placed at the first owner that can carry it: dotfiles, harness-tools, a process-event extension, the Home repo, and only then a fork item.

A fork change lands as one squash-merged PR into `main` (the repository allows squash merges only).
A change to an existing item is titled `fixup! <exact item title>`; a new feature or fix gets its own title.
Between syncs `main` is the stack plus those commits; the next sync folds them.

Each sync:

1. Target the newest upstream `main` commit whose own push run concluded success, and name its SHA and run URL.
2. On a branch at `origin/main`, drop GitHub's ` (#N)` suffix from every stack subject so each `fixup!` matches its item: `git rebase <old-base> --exec 'git log -1 --format=%B | sed -E "1s/ \(#[0-9]+\)$//" | git commit --amend -q -F -'`.
3. Rebase onto the target and fold: `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --onto <green> <old-base>`, with `rerere.enabled=true`; resolve each conflict by that item's intent.
4. Remove the commit of any item whose upstream equivalent has landed.
5. Review with `git range-diff <old-base>..<old-main> <green>..<new-main>`, then run `bin/fm-lint.sh`, `bash bin/fm-test-run.sh --check-coverage`, and the manual full run in `.github/workflows/fork-ci.yml` on the sync branch.
6. Publish with `git push --force-with-lease=main:<old-main> origin <sync-branch>:main`, only after the captain's explicit word for that push.
7. Cut `release` with an adoption commit, `git commit-tree <new-main>^{tree} -p <current release head> -p <new-main>`, pushed as a fast-forward of `release`, so every home fast-forwards to the stack's exact tree.
8. Rebase any open fork branch with `git rebase --onto origin/main <old-main> <branch>`.

## Rejected

- Merging upstream into `main` through a PR: it keeps `main` a fast-forward, but leaves each item spread across merge commits and fix rounds.
- Publishing the clean stack on a separate `patches` branch next to a merge-shaped `main`: two histories to keep equal, and `main` stays unreadable.
- A numeric budget for edits to upstream-owned files: it was raised by the same changes that exceeded it, while the per-item inventory and `git range-diff` show the same surface directly.

## Consequences

`main` is rewritten at every sync, so each sync needs a force-push and that push needs the captain's word.
Homes never follow `main` directly; they fast-forward along `release`'s adoption commits.
A fork branch or clone based on an old `main` must be rebased after each sync.
Dropping an item is dropping its commit, so each item commit carries its own registration lines, including its suites' lines in `bin/fm-test-run-fork.sh`.
