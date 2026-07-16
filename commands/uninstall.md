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
     `In Progress`. Read the WHOLE board via the shared paginating reader — `gh project item-list`
     returns only its 30-item first page (and `--limit N` merely moves the ceiling — the same
     truncation bug at a larger N), so a grown board would UNDER-count in-flight work and silently
     orphan items past the cut on uninstall. `idc_gh_board.py` pages to completion and emits
     ASCII-escaped JSON, so the downstream `jq` is control-char-safe (a raw control char U+0000–U+001F
     in any issue body arrives already escaped, never crashing `jq`):
     ```bash
     owner=$(gh repo view --json owner -q .owner.login)
     num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
     # CAPTURE the board first, THEN count — never pipe idc_gh_board.py straight into jq. On a
     # board-read FAILURE the helper exits 2 with EMPTY stdout, and `… | jq … | length` over empty
     # input prints `0` at exit 0 — indistinguishable from a real "0 in progress" on this DESTRUCTIVE
     # command. Capture-then-check (mirrors doctor Row 9) makes the failure detectable so the prose
     # below can require an explicit confirmation instead of silently reading the outage as "0 in flight".
     if board=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" --owner "$owner" --project "$num"); then
       inflight=$(printf '%s\n' "$board" | jq '[.items[] | select(.status=="In Progress")] | length')
     else
       inflight="unknown"   # board read failed (exit ≠ 0) → cannot verify → require confirmation
     fi
     ```
     If `$inflight` is a number ≥1, report plainly ("N issues still in progress — uninstalling
     orphans them on the board") and require an explicit `yes` to proceed. If `$inflight` is
     `unknown` (the board read **failed**), do not skip silently: report "could not verify in-flight
     items (board unreachable)" and require an explicit confirmation to proceed anyway.
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
  `docs/workflow/workflow-machine.yaml`, `docs/workflow/pillar-matrices/`,
  `docs/workflow/code-reviews/`, and the
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

## Phase 3 — Do the work, then close, then remove the anchor (in that order)

Do the destructive uninstall in **three ordered sub-steps**. The closeout runs in the MIDDLE: it
**independently verifies the work already happened** (the footprints are gone, the enablement key is
stripped, the archive exists) before recording `applied` — so the record can never claim `applied`
before the uninstall ran. The one thing left for AFTER the finish is removing the governance anchor
(`docs/workflow/tracker-config.yaml`), because that file is what marks the repo IDC-governed; once it
is gone the session-ledger write is a repo-gated no-op and `finish` can no longer land.

**3a — Remove every footprint EXCEPT the governance anchor.** Delete the manifest files (keep
`docs/workflow/tracker-config.yaml` for now), strip only the enablement key, and remove the
runtime `TRACKER.md`. Do **not** commit yet:
```bash
# delete the manifest files but KEEP the governance anchor (it stays until sub-step 3c)
git -C "$ROOT" rm -r --quiet <manifest footprint paths — everything the receipt lists EXCEPT the anchor>
# strip ONLY the enablement key, preserving every other operator setting (atomic safe-write)
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_settings_json.py" \
  disable .claude/settings.json idc@idc-workflow
git -C "$ROOT" add .claude/settings.json 2>/dev/null || true
# filesystem backend: TRACKER.md (runtime-created, not receipt-listed)
[ -f "$ROOT/TRACKER.md" ] && git -C "$ROOT" rm --quiet TRACKER.md
```

If the operator passed the opt-in GitHub flags (`--close-issues` / `--delete-board`), do that board
work **HERE, before the finish** — ALL destructive operations must precede the closeout; the only step
left for after the finish is the governance-anchor removal (sub-step 3c). See Phase 4 for the flag
mechanics; run those commands at this point, not after 3b.

**3b — Close the command contract (the work is now verifiable).** The validator derives the removal set
from the install receipt and re-checks each footprint is ABSENT, the settings key is stripped, the
archive exists, and the anchor is still present —
a caller cannot assert `applied` without the work having happened:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command uninstall \
  --status <complete|blocked_external> --evidence-json '<envelope>'
```
- **`complete`** — either the footprints were removed, or the run is an explicit no-action. The
  validator **derives the removal set from the install receipt** (never a caller `removed` list): for an
  applied run it confirms EVERY receipt-listed footprint (except the governance anchor) is now ABSENT,
  the settings IDC key is stripped, the archive file exists, and the anchor is still present. Evidence
  refs for an applied run: `outcome:"applied"`, `settings:".claude/settings.json"`, `archive:"<archive
  path>"`. For a no-op run: `outcome:"no-action"` — the validator re-reads the receipt and confirms
  every non-anchor footprint is ALREADY absent (a no-action with any footprint still present, or with no
  receipt to prove it, is refused).
- **`blocked_external`** — a safety refusal (a dirty tree, an unverifiable board, an invalid receipt):
  `blocker:{helper, exit (nonzero), diagnostic}`. Report it as blocked; do not proceed to remove.

**3c — The single POST-finish step: remove the anchor + commit atomically.** Only after `finish`
succeeds, remove the governance anchor and land ALL removals as one revertable commit:
```bash
git -C "$ROOT" rm --quiet docs/workflow/tracker-config.yaml
git -C "$ROOT" commit -m "idc: uninstall — remove IDC footprints (revert this commit to reinstate)"
```
Stage only the removed paths and `.claude/settings.json` — **not** the archive tarball (it must
stay untracked). Capture the commit SHA for the summary. On a re-run with nothing left to remove,
make no commit and report `skipped-absent` across the board.

## Phase 4 — GitHub side (opt-in; default leaves it untouched)

**Ordering:** when these flags are passed, run them in Phase 3a **BEFORE the 3b finish** — every
destructive operation completes before the closeout; only the governance-anchor removal is post-finish.
This section documents the flag mechanics; it is not a later phase.

Default: the board and all issues are left exactly as they are. Only on the flags:

- `--close-issues` — **reversible.** Close (never delete) only issue-backed items proven to be on
  this board, through the GitHub tracker adapter. It pre-reads every issue state and positively
  reads each close back. Report the count closed; they can be reopened:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" close-project-issues \
    --repo "$ROOT" --owner "$owner" --project "$num"
  ```
- `--delete-board` — **permanent.** Require a typed confirmation: the operator must type the board
  number (or exact title) back, then pass that exact value to the adapter. It re-reads the selected
  board before deleting it and verifies the captured project node is absent afterward. If the typed
  value doesn't match, abort the board deletion (the rest of the uninstall still stands):
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" delete-project \
    --repo "$ROOT" --owner "$owner" --project "$num" --confirm "$typed_confirmation"
  ```
  Issue deletion is never offered.

All lifecycle writes go through these validating adapter doors. The mutation interlock has no
Init/Uninstall exception: a raw issue close, project create/delete/link/field write, board-item
delete, or GraphQL mutation is denied while any IDC command is active.

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

## Command lifecycle — verify at entry, close BEFORE ungoverning

The command entry gate opened this command's lifecycle record at expansion; verify it early:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

Uninstall is a **removal** command — no pipeline oracle handoff. Its closeout `finish` is called in
**Phase 3, immediately BEFORE the removal deletes `docs/workflow/tracker-config.yaml`** — because that
deletion ungoverns the repo, after which a `finish` is a repo-gated no-op (exit 2), never a valid
close. Close the record while the repo is still governed, then remove. **Do not re-initialize the
repo** (re-create `tracker-config.yaml`, re-open a record) to make a late `finish` land — that would
undo the uninstall.
