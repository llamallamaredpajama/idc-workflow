---
description: IDC project upgrade alias — run the receipt-preserving `/idc:update` mechanism
argument-hint: "[--codex] [--dry-run]"
---

You are running `/idc:upgrade`. This command is a compatibility alias for `/idc:update`.
Use the same receipt-aware update mechanism and the same safety posture: preserve operator
customizations, never silently overwrite a fingerprint mismatch, and record the refreshed
scaffold in a single revertable commit.

The receipt writer still uses `written_by: idc:update` so the lifecycle history has one
canonical update identity.

## Execute `/idc:update` semantics

Follow `commands/update.md` exactly:

- Read `docs/workflow/install-receipt.yaml`.
- Treat a missing receipt as pre-receipt graduation and require operator review before
  creating a new receipt.
- Classify paths as `stamped`, `customized`, `new-template`, or `skipped-existing`.
- A fingerprint mismatch requires operator review and no silent overwrite.
- Use `state: customized` for preserved or operator-merged files.
- Refresh stamped files, add new template files, and preserve customized files.
- Write `written_by: idc:update` in the refreshed receipt.
- Mention `CHANGELOG` only for this plugin repo's own lifecycle behavior changes; do not
  edit a target application's changelog unless it is a stamped IDC scaffold file.
- Finish with one single revertable commit, or no commit when every path is
  `skipped-existing`.

Print the same summary table as `/idc:update` and tell the operator that `/idc:update` is
the preferred spelling for future runs.
