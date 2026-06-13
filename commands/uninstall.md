---
description: IDC Uninstall — remove every IDC repo footprint safely in ONE revertable commit (receipt-driven; work products archived; GitHub untouched by default)
argument-hint: "[--close-issues] [--delete-board]"
---

You are running `/idc:uninstall`. Remove IDC's repo footprints — the phased, idempotent
**inverse** of `/idc:init`. The install receipt (`docs/workflow/install-receipt.yaml`, written
by `/idc:init` and refreshed by `idc:update`) is the removal manifest: **only delete what IDC
created.** Work the phases in order, from the target repo root.

**Fail toward asking, never toward silent damage.** Every uncertain state (dirty tree,
unverifiable board, customized files, invalid receipt) stops and asks; nothing is removed until
the manifest is settled. Idempotent: a re-run reports `skipped-absent` for anything already gone.

**GitHub is untouched by default** — the board and its issues survive uninstall unless you pass
`--close-issues` (reversible) or `--delete-board` (permanent, typed confirmation). Issue
*deletion* is never offered. Machine-global surfaces (the installed plugin, the Codex links) are
out of scope — Phase 5 names the separate operator commands for those.

## Phase 0 — Preflight (two layers; both fail toward asking)

1. **Git repo.** `git rev-parse --show-toplevel`; if not a repo, stop and tell the operator to
   `cd` in. Set `ROOT="$(git rev-parse --show-toplevel)"`.
2. **Clean working tree — exempting prior archives.** The removal must land as one revertable
   commit, so the tree must be clean of *other* changes. A previous run's untracked
   `idc-archive-*.tar.gz` is exempt so re-runs don't self-block:
   ```bash
   git -C "$ROOT" status --porcelain | grep -vE '^\?\? idc-archive-.*\.tar\.gz$'
   ```
   Any remaining output → STOP: ask the operator to commit or stash their changes first, then
   re-run. Do not stash on their behalf.
3. **In-flight check (warn-and-confirm).** Read the backend from
   `docs/workflow/tracker-config.yaml`.
   - `github` → probe the board read-only (same shape as `idc:doctor`), count items still in
     `In Progress`:
     ```bash
     owner=$(gh repo view --json owner -q .owner.login)
     num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
     gh project item-list "$num" --owner "$owner" --format json --limit 500
     ```
     If ≥1 in-flight, report plainly ("N issues still in progress — uninstalling orphans them on
     the board") and require an explicit `yes` to proceed. If the board read **fails**, do not
     skip silently: report "could not verify in-flight items (board unreachable)" and require an
     explicit confirmation to proceed anyway.
   - `filesystem` → the same count over `TRACKER.md` (in-progress entries); warn-and-confirm.

## Phase 1 — Build the removal manifest (receipt-driven, hardcoded fallback)

Decide the file set deterministically, then classify it:

- **Receipt present** (`docs/workflow/install-receipt.yaml`): the receipt's `files[]` are the
  removal set. Classify each against on-disk reality with the shipped helper:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" verify --repo "$ROOT"
  ```
  - `unchanged` → remove.
  - `modified` (or an entry the receipt marked `state: customized`) → **operator-customized**:
    surface it ("this IDC file was edited locally") and ask keep-or-remove per file. Default to
    keeping; never silently delete a customization.
  - `missing` → already gone; record `skipped-absent`.
  If the receipt is present but **invalid** (the helper exits non-zero), STOP and report the parse
  error — do not fall back silently to the hardcoded list.
- **No receipt** (pre-receipt install): use the hardcoded fallback footprint — exactly what
  `/idc:init` scaffolds:
  `WORKFLOW.md`, `WORKFLOW-config.yaml`, `docs/workflow/tracker-config.yaml`,
  `docs/workflow/pillar-matrices/`, `docs/workflow/code-reviews/`, and the
  `docs/workflow/` README. Anything absent → `skipped-absent`. (Keep this list in sync with the
  scaffold under `${CLAUDE_PLUGIN_ROOT}/templates/`: a pre-receipt repo can only be cleaned by
  this fallback, so a scaffold file added there must be added here too. Receipt-driven installs
  don't have this drift — they remove whatever the receipt lists.)

Always add two footprints the receipt never lists (see `commands/init.md`): the receipt file
itself, and — **filesystem backend only** — the runtime-created `TRACKER.md`. The operator-owned
`.claude/settings.json` is **not** deleted; only its one enablement key is stripped (Phase 3).

## Phase 2 — Archive work products (always, before any deletion)

Tar the IDC-managed work products to an untracked repo-root archive and **announce the path**:
```bash
ARCHIVE="idc-archive-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$ROOT/$ARCHIVE" -C "$ROOT" docs/workflow $( [ -f "$ROOT/TRACKER.md" ] && echo TRACKER.md )
```
This preserves the operator's matrices, code-reviews, tracker history, and configs even though
the removal commit deletes them — a `git revert` restores the tracked files, and the tarball
covers anything untracked. The archive stays untracked (and is matched by the `idc-archive-*`
preflight exemption); it is never part of the removal commit.

## Phase 3 — Remove footprints in ONE revertable commit

Apply every removal as a single commit so the whole uninstall reverts atomically:
```bash
# 1) delete the manifest files (tracked → git rm; the receipt + scaffold are tracked)
git -C "$ROOT" rm -r --quiet <manifest paths kept for removal>
# 2) strip ONLY the enablement key, preserving every other operator setting (atomic safe-write)
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_settings_json.py" \
  disable .claude/settings.json idc@idc-workflow
git -C "$ROOT" add .claude/settings.json 2>/dev/null || true
# 3) filesystem backend: TRACKER.md (runtime-created, not receipt-listed)
[ -f "$ROOT/TRACKER.md" ] && git -C "$ROOT" rm --quiet TRACKER.md
# 4) one revertable commit (never --no-verify)
git -C "$ROOT" commit -m "idc: uninstall — remove IDC footprints (revert this commit to reinstate)"
```
Stage only the removed paths and `.claude/settings.json` — **not** the archive tarball (it must
stay untracked). Capture the commit SHA for the summary. On a re-run with nothing left to remove,
make no commit and report `skipped-absent` across the board.

## Phase 4 — GitHub side (opt-in; default leaves it untouched)

Default: the board and all issues are left exactly as they are. Only on the flags:

- `--close-issues` — **reversible.** Close (never delete) the IDC issues on the board via the
  `idc:idc-tracker-github` ops / `gh issue close`. Report the count closed; they can be reopened.
- `--delete-board` — **permanent.** Require a typed confirmation: the operator must type the board
  number (or exact title) back before you run `gh project delete <num> --owner <owner>`. If the
  typed value doesn't match, abort the board deletion (the rest of the uninstall still stands).
  Issue deletion is never offered.

For the `filesystem` backend these flags are no-ops (TRACKER.md was already handled in Phase 3);
say so.

## Phase 5 — Summary

Print one table of every footprint (`removed` / `skipped-absent` / `kept (customized)`), then:
- the archive path from Phase 2,
- the single revert command — `git revert <sha>` — to reinstate everything,
- the board disposition (untouched / N issues closed / board deleted),
- and the **machine-global** surfaces that uninstall deliberately does not touch, for the operator
  to run separately if they want a full removal:
  - `claude plugin uninstall idc@idc-workflow` (removes the installed plugin from this machine),
  - `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" --revert` (restores the pre-IDC
    `~/.agents/skills` state, if Codex support was wired).

| Footprint | Status |
|-----------|--------|
