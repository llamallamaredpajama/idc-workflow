---
description: IDC project updater — refresh stamped IDC scaffold while preserving operator customizations
argument-hint: "[--codex] [--dry-run]"
---

You are running `/idc:update`. Update the IDC workflow scaffold in the **current
repository** from the currently installed plugin. The command is idempotent and
receipt-aware: it refreshes files that are still stamped, never silently overwrites an
operator customization, and records the new receipt state in a single revertable commit.

`/idc:upgrade` is a compatibility alias for this same mechanism. The receipt writer uses
`written_by: idc:update` so future runs can tell that the repo graduated from its original
init receipt.

Operator arguments: `$ARGUMENTS` — optional `--codex` to refresh Codex adapters and
optional `--dry-run` to print the plan without writing.

## Phase 0 — Preconditions

1. Confirm cwd is a git repo and tracked files are clean.
2. Confirm the plugin is enabled for the project or can be read from the active plugin
   root.
3. Read `docs/workflow/install-receipt.yaml` if present. If it is absent, enter
   pre-receipt graduation mode: compare known IDC scaffold paths against current templates,
   show every proposed write, and require operator review before writing a new receipt.

## Phase 1 — Classify scaffold paths

For every current template or generated scaffold path, classify it as one of:

- `stamped`: the receipt fingerprint matches current bytes, so the file may be refreshed
  automatically from the plugin template or generated value.
- `customized`: the receipt entry exists but current bytes differ from the fingerprint; the
  command must not silently overwrite it.
- `new-template`: the installed plugin has a new scaffold path that the repo does not yet
  contain; create it unless `--dry-run` is set.
- `skipped-existing`: the repo already contains a path not proven safe to rewrite.

A fingerprint mismatch always triggers operator review. During operator review, print a
unified diff between the current file and the proposed updated file, then ask whether to
keep current, accept update, or accept update while marking `state: customized`. This is a
no silent overwrite rule: no customized file is replaced without an explicit answer.

## Phase 2 — Apply safe updates

Apply updates in this order:

1. Refresh stamped files from `templates/` or generated scaffold logic.
2. Add new template files and missing docs-tree entries.
3. Preserve customized files unless operator review explicitly accepted an update.
4. Re-run the same token substitutions as `/idc:init` for project name, owner, repo, and
   tracker project number.
5. If `--codex` is present, run `scripts/install-codex.sh` exactly as `/idc:init --codex`
   does; otherwise leave machine-local Codex links untouched.

All writes are staged into one single revertable commit. If `--dry-run` is present, do not
write, do not stage, and do not commit.

## Phase 3 — Rewrite the install receipt

Write `docs/workflow/install-receipt.yaml` after successful updates. The receipt format is
identical to `/idc:init` Phase 7, except:

```yaml
receipt_version: 1
fingerprint_method: sha256
written_by: idc:update
written_at: 2026-06-12T14:00:00Z
files:
  - path: WORKFLOW.md
    fingerprint: 3a91c2...64-lowercase-hex-chars
    state: stamped
```

Use `state: stamped` for files updated directly from plugin templates or generated IDC
scaffold. Use `state: customized` for files the operator chose to preserve or accept as a
custom merge. Preserve entries for scaffold files not touched in this run when they still
exist. Remove receipt entries for files that no longer exist only after printing the stale
entry list in the summary.

## Phase 4 — Documentation and CHANGELOG posture

The command itself does not edit project product docs. It may update IDC scaffold docs if
those docs are stamped or accepted during operator review. When this plugin repo changes
lifecycle behavior, the plugin's own `CHANGELOG.md` must record `/idc:update` changes;
when running in a governed target repo, leave that repo's application CHANGELOG alone
unless it is an IDC scaffold file covered by the receipt.

## Phase 5 — Summary

Print a table of every considered path with one of `updated`, `created`,
`skipped-existing`, `customized`, `operator-review-required`, or `dry-run`. Include the
receipt status, commit SHA, and the `git revert <sha>` hint when a commit was created.
If every path was already current, report `skipped-existing` and create no commit.
