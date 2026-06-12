---
description: IDC project uninstaller — archive and remove repo-local IDC scaffold in one revertable commit
argument-hint: "[--close-issues] [--delete-board]"
---

You are running `/idc:uninstall`. Remove the IDC workflow from the **current repository**
without touching machine-global plugin installation by default. The command is idempotent,
receipt-driven when possible, guarded against silent data loss, and finishes by creating a
single revertable commit.

Operator arguments: `$ARGUMENTS` — optional `--close-issues` and `--delete-board` flags.
Issue deletion is never offered.

## Phase 0 — Preconditions and idempotency posture

1. Confirm cwd is a git repo (`git rev-parse --show-toplevel`).
2. Confirm tracked files are clean before removal: `git status --porcelain` filtered to
   tracked entries must be empty. Prior untracked `idc-archive-*.tar.gz` files are
   explicitly exempt so a re-run does not block on its own archive.
3. Read `docs/workflow/tracker-config.yaml` if present. If the GitHub tracker cannot be
   read, print `could not verify in-flight items` and require explicit operator
   confirmation before continuing. Never silently skip this check.
4. In-flight tracker items are any items with `Status` in `Active` or `Blocked`, or
   `ClaimState` in `Claimed`, `Running`, or `RetryQueued`. If any exist, warn that
   uninstalling may orphan them and require explicit confirmation.

## Phase 1 — Build the removal manifest

Start from `docs/workflow/install-receipt.yaml` when present and valid. Each receipt entry
uses `path`, `fingerprint`, and `state`; compare current SHA-256 bytes against the receipt
fingerprint. Any fingerprint mismatch or unprovable receipt entry is shown to the operator
and requires confirmation before that path is removed.

If the receipt is missing or corrupt, announce the fallback and require confirmation before
continuing. The fallback is the hardcoded footprint list below; this hardcoded footprint
list is intentionally conservative and covers runtime-created files that init cannot have
fingerprinted:

- `WORKFLOW.md`
- `WORKFLOW-config.yaml`
- `docs/workflow/`
- `TRACKER.md` when the filesystem backend is in use
- `.claude/settings.json` only for removal of `.enabledPlugins["idc@idc-workflow"]`; never
  delete the settings file itself

Do not include role-authored canonical docs such as `docs/prd/`, `docs/specs/`,
`docs/plans/`, or `docs/considerations/`; uninstall only deletes what IDC scaffolding
created or what the runtime footprint list permanently owns.

## Phase 2 — Archive before removal

Before deleting or editing anything, tar every manifest path that exists into an untracked
repo-root archive named `idc-archive-<YYYYmmdd-HHMMSS>.tar.gz`. Preserve repo-relative
paths inside the tarball and always announce the archive path. The archive is created
before any removal so the uninstall is recoverable even before the git revert hint.

## Phase 3 — Remove repo-local footprint

Remove every existing manifest path, reporting `removed` for deleted paths and
`skipped-absent` for paths already gone. For `.claude/settings.json`, strip only the
`enabledPlugins["idc@idc-workflow"]` key with `jq 'del(.enabledPlugins["idc@idc-workflow"])'`,
preserving every other setting; if the key is already absent, report `skipped-absent`.

Create exactly one commit for the uninstall, with every repo-local removal and settings
edit in that commit. Print the revert command as `git revert <sha>` in the final summary.
A re-run after a completed uninstall should create no second commit and should report
`skipped-absent` for every target.

## Phase 4 — Optional GitHub cleanup flags

By default, GitHub is untouched.

- `--close-issues` closes board-linked issues with a comment that the repo-local IDC
  scaffold was uninstalled. Closing is reversible; issue deletion is never offered.
- `--delete-board` is permanent and requires typed confirmation: the operator must type
  the exact board title back before deletion proceeds. Without that typed confirmation,
  leave the board intact and report it as skipped.

## Phase 5 — Summary

Print one table with each target and status (`archived`, `removed`, `skipped-absent`,
`confirmed-customized`, or `blocked-confirmation-required`), the archive path, the commit
SHA if a commit was created, and the `git revert <sha>` hint. End by naming machine-global
follow-ups the operator may run separately:

- `claude plugin uninstall idc@idc-workflow`
- `bash "<plugin-root>/scripts/install-codex.sh" --revert` (`install-codex.sh --revert`)

Never run those machine-global commands automatically from `/idc:uninstall`.
