---
description: IDC janitor — deterministic board↔git reconciler. Report (read-only by default) worktrees, branches (local+remote), and board↔issue↔PR coherence in four verdict tiers (SAFE-FIX / REPORT-ONLY / RISKY / COHERENT); --apply-safe applies ONLY the SAFE-FIX tier.
argument-hint: '[--apply-safe]'
---

`/idc:janitor` is the **netting layer** — the deterministic reconciler that scoops up whatever a dead
or interrupted session leaves outside the guard rail (orphan worktrees, merged-but-surviving
branches, board↔issue drift) and classifies every finding into four verdict tiers. It is
**read-only by default** (a full report). `--apply-safe` applies the **SAFE-FIX tier only**. See
`WORKFLOW.md §A`.

Operator input: `$ARGUMENTS` — pass `--apply-safe` to apply the SAFE-FIX tier; otherwise a full,
read-only report.

The scanner (`scripts/idc_git_janitor.py`) reconciles, from a **single board read + the merged-PR
list**, board state against git reality across four dimensions — **worktrees**, **branches**
(local + remote), **board↔issue↔PR coherence**, and **attribution** — and assigns every finding a tier:

- **SAFE-FIX** — IDC-attributable (`idc-*`, `build*`, `plan/*`, `recirculate/*`, `worktree-*`) **AND**
  merged **AND** clean. The *only* tier `--apply-safe` touches: remove a clean merged worktree, delete
  a merged branch (local + remote), close a Done-but-open issue, set Status=Done on an issue whose
  work merged. Deterministic, no judgment.
- **REPORT-ONLY** — non-IDC artifacts (Codex / Antigravity / team-execute / claude / recovery debris).
  **Always listed, NEVER touched** — the janitor does not clean tooling it did not create.
- **RISKY** — dirty worktree, unmerged branch, or ambiguous attribution. Listed with a suggested
  action; applied **only one-by-one on explicit operator confirmation**, never by `--apply-safe`.
- **COHERENT** — no findings.

Provenance coherence ("Buildable with no `idc-provenance` marker") is **not** this command's job — it
needs per-issue body reads and already has a dedicated detective: the SessionEnd recirc sweep and
**`/idc:doctor` Row 9b**. The janitor reconciles git↔board *state*.

## Run

Read the backend from `docs/workflow/tracker-config.yaml`, then invoke the scanner. Pass
`$ARGUMENTS` straight through so `--apply-safe` reaches it (default = read-only report):

```bash
backend=$(grep -E '^backend:' docs/workflow/tracker-config.yaml | awk '{print $2}')
if [ "$backend" = "github" ]; then
  owner=$(gh repo view --json owner -q .owner.login)
  num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" \
    --repo "$PWD" --backend github --owner "$owner" --project "$num" $ARGUMENTS
else
  # filesystem backend (the default): the board is TRACKER.md's state block.
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" \
    --repo "$PWD" --tracker "$PWD/TRACKER.md" $ARGUMENTS
fi
```

The scanner's exit code is the machine-readable verdict (mirrors `idc_autorun_drain.py`):

- **0** — `COHERENT` (zero findings). A clean repo. This is the e2e post-condition contract: clean → 0.
- **1** — findings present (any tier). Debris to report (and, with `--apply-safe`, the SAFE-FIX ones
  were applied; RISKY + REPORT-ONLY remain, so the re-scan still exits 1).
- **2** — **fail-closed**: ground truth could not be established (not a git repo, unresolved default
  branch, an unreadable board), or the result would be clean but a dimension was indeterminate. Never
  a hollow clean. Surface the stderr diagnostic and stop — do not treat a `2` as `COHERENT`.

## Report the result

Relay the scanner's tiered output verbatim, then:

- **Default (report):** present the four tiers. SAFE-FIX findings can be applied now with
  `/idc:janitor --apply-safe`; RISKY findings need review (act on them one at a time, with the
  suggested action, on the operator's say-so); REPORT-ONLY findings are foreign debris the janitor
  will never touch (route them to their own tooling). Nothing was changed.
- **`--apply-safe`:** the scanner applied the SAFE-FIX tier, re-scanned, and printed the delta (what
  was cleared, what remains). Report which SAFE-FIX items were applied (and any that failed — a failed
  fix is reported, not silently swallowed), then the remaining RISKY + REPORT-ONLY findings for the
  operator to review. **RISKY items are still never auto-applied** — offer to walk them one-by-one.

**This command is safe to re-run** — `--apply-safe` is idempotent (a second pass finds 0 SAFE-FIX),
and the default report mutates nothing.
