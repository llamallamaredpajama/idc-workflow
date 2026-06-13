---
description: IDC Update — resync a repo's stamped scaffold to the installed plugin after a plugin update (receipt-driven; customized files are diff-and-asked; the board is report-only, never mutated)
argument-hint: (no arguments)
---

You are running `/idc:update`. Bring a governed repo's stamped scaffold up to date with the
installed plugin version, **files only**. The install receipt
(`docs/workflow/install-receipt.yaml`) is the source of truth for what IDC stamped, so update can
tell a pristine file (safe to refresh silently) from one the operator customized (must ask). Work
the phases in order, from the target repo root (`ROOT="$(git rev-parse --show-toplevel)"`).

**The compare is safety-critical and fails toward asking.** A file is silently re-stamped *only*
when the receipt proves it untouched; anything else is shown as a diff and the operator decides.
Update **never mutates the GitHub board** — it reports board drift and stops there. Idempotent: a
re-run with nothing stale reports `skipped-already-current`. The receipt is rewritten **only at the
very end of a fully successful run**, so a half-finished update can never masquerade as complete.

## Phase 0 — Preconditions

1. **Git repo + scaffold present.** `git rev-parse --show-toplevel`; confirm `WORKFLOW.md` and
   `docs/workflow/` exist (else this repo isn't initialized — point at `/idc:init`). A clean tree
   is recommended so the refreshed files are reviewable as a discrete change.
2. **Cache-refresh note.** A plugin update may ship new commands/skills that an already-running
   Claude Code session won't see until the plugin cache refreshes — tell the operator that if a
   newly-shipped `/idc:*` command is missing after updating, they should restart the session (this
   is a client cache quirk, not an update failure).

## Phase 1 — Classify the stamped files against the receipt

- **Receipt present:** classify every stamped file against on-disk reality:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" verify --repo "$ROOT" --json
  ```
  Branch per file on the drift class **and** the recorded `state`:
  - `unchanged` **and** `state: stamped` → pristine. Safe to refresh silently — but only if the
    installed plugin's template for that file actually differs from what's on disk; if identical,
    `skipped-already-current`.
  - `modified`, **or** any entry the receipt marked `state: customized` → operator-customized:
    **show-diff-and-ask** (on-disk vs the installed template's rendered bytes); the operator
    chooses keep or replace. Never silently overwrite a customization.
  - `missing` → was stamped but removed; offer to restore it from the template (default: leave
    removed unless the operator wants it back).
  If the receipt is present but **invalid** (the helper exits non-zero), STOP and report the parse
  error — do not silently treat files as untouched.
- **No receipt (pre-receipt install):** this is the one-time graduation. **Diff-and-ask for every
  scaffold file** (treat them all as possibly-customized), apply what the operator approves, then
  Phase 4 writes the repo's first receipt.

## Phase 2 — Apply the approved refreshes (files only)

For each file approved for refresh (pristine-and-differing, operator-chose-replace, or
restore-missing): render the installed plugin's template and write it, substituting the same tokens
`/idc:init` does — `{{PROJECT_NAME}}` (read from `WORKFLOW-config.yaml`) and, for the github
backend, `{{TRACKER_PROJECT_NUMBER}}` (read from `docs/workflow/tracker-config.yaml`). The templates
live under `${CLAUDE_PLUGIN_ROOT}/templates/`. Record, per file, what changed.

Files the operator chose to keep are left exactly as-is. Update touches **only** stamped scaffold
files — never source, never tests, never the board.

## Phase 3 — Board-drift detection (report-only; NEVER mutate)

Compare the live tracker against the installed version's expectation and **report** — take no
action on the board:
- `github` backend: read the board's fields read-only (`gh project field-list <num> --owner
  <owner> --format json`) and compare against the v2 contract — four fields `Status`
  (`Blocked|Todo|In Progress|Done`), `Wave`, `Phase`, `Domain`. Report any drift explicitly
  (missing field, unexpected `Status` option set, etc.). Do **not** add, rename, or re-option any
  field — board migration is out of scope (it risks live issues and in-flight waves); surface the
  drift and let the operator decide via `idc:idc-tracker-github`.
- If the drift check **cannot run** (board unreachable, or `filesystem` backend), report a distinct
  third outcome — "board drift: could not verify (reason)" — never silently report "no drift".

## Phase 4 — Rewrite the receipt (end of a successful run only)

Once every approved refresh is applied, write a fresh receipt over the stamped set so the next
update and `/idc:uninstall` stay accurate. Pass the files the operator **kept customized** via
`--customized` so the next update asks again instead of silently re-stamping over them:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$ROOT" --out docs/workflow/install-receipt.yaml --written-by idc:update \
  [--customized <kept-file> ...] <stamped-file> <stamped-file> ...
```
This graduates a pre-receipt repo to receipt-driven, and — because it runs only at the very end —
guarantees a partial update never leaves a receipt that claims more than was actually done. The
receipt never lists itself, `TRACKER.md`, or `.claude/settings.json` (the helper drops them).

If a receipt already existed and nothing changed this run, leave it untouched and report
`skipped-already-current`.

## Phase 5 — Summary

Print one table of every stamped file (`refreshed` / `kept (customized)` / `restored` /
`skipped-already-current`), then:
- the board-drift outcome (one of: no drift / drift details / could not verify),
- the receipt status (`rewritten` / `graduated` / `skipped-already-current`),
- and the cache-refresh reminder if any newly-shipped command/skill files arrived with this update.

| File | Status |
|------|--------|
