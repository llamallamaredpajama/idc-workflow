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

The scanner (`scripts/idc_git_janitor.py`) reconciles board state against git reality and assigns
every finding a tier. The dimensions it scans, the tier criteria (what counts as IDC-attributable,
merged, clean), and the exact fix set `--apply-safe` may touch are computed by the scanner — it is
the source of truth; do not re-derive them here. What each tier means for the operator:

- **SAFE-FIX** — the *only* tier `--apply-safe` touches. Deterministic, no judgment.
- **REPORT-ONLY** — another tool's artifacts. **Always listed, NEVER touched** — the janitor does
  not clean tooling it did not create; route these to their own tooling.
- **RISKY** — needs judgment. Listed with a suggested action; applied **only one-by-one on explicit
  operator confirmation**, never by `--apply-safe`.
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

## Command lifecycle — verify at entry, close out honestly

The command entry gate opened this command's lifecycle record at expansion; verify it, and **close it
with a validated terminal status** before your final answer (the Stop closeout gate refuses a
walk-away from an open command). Janitor is a **reconciler/diagnostic** — no pipeline oracle handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
# … after the scan …
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command janitor \
  --status <complete|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — the scanner recorded a real verdict: exit **0** (COHERENT) or exit **1** (findings,
  **without claiming clean**). Evidence refs: `scanner_exit:<0|1>`, and on exit 1
  `scanner_clean:false` (a findings run may never report clean).
- **`blocked_external`** — the scanner exited **2** (ground truth could not be established): `blocker:{helper,
  exit (nonzero), diagnostic}`. Report it as blocked, never as a coherent repo.
