---
name: idc-ripple-sync
description: 'Use in Ripple to determine the highest affected canonical layer, the downstream sync set, and whether the change is autonomous (one PR) or PRD-gated.'
---
# idc-ripple-sync

Ripple's doc-sync core (`WORKFLOW.md §4.4`). Ripple is the only retrograde path from Build
back to the planning docs; it heals drift between docs and reality. v2 deleted the old
four-value verdict taxonomy, the 4-condition autonomous test, the change-order files, and the
change-order author/reviewer/fixer roles. The decision is now binary and the PR body is the
change order.

## The one question

Determine the **highest affected canonical layer** and answer: does user-facing product
function change?

- **No** → update that layer and **every layer below it** down the chain in **one PR**
  (synchronized together), automerge. The doc chain never half-updates.
- **Yes** → the highest affected layer is the PRD; take the same gate as Plan via
  `idc:idc-gate-issue` (blocked operator-todo gate + plain-terms summary + PRD diff + push
  notification). Only the PRD gates.

## Downstream sync set

The chain is `prd → spec → master → subphase → pillar`. Changing layer N requires syncing N
plus everything downstream of it, in one PR, plus any affected open issues. Compute the set
and the gate decision deterministically:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_ripple_layers.py" <prd|spec|master|subphase|pillar>
# -> sync: <layer> ... pillar
#    gate: yes|no   (yes iff the highest affected layer is the PRD)
```

## The PR is the change order

The ripple PR's description **is** the change order: the drift evidence, the layers changed
and why, and why the PRD was or wasn't affected. No `docs/workflow/ripple/` files are
written.

## Authority boundaries

- Determines the affected layers, the sync set, and the gate decision; the Ripple
  orchestrator (`idc:idc-ripple`) performs the doc edits and opens the PR. Tracker mutation
  (the gate path, affected open issues) routes through `idc:idc-tracker-adapter`. Never
  writes source or tests; never edits the PRD without the gate.
