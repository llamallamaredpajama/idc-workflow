---
name: idc-ripple
description: 'IDC Ripple orchestrator playbook — autonomous doc-sync across the canonical chain in one PR, with the PRD-only gate.'
---
# idc-ripple

The Ripple orchestrator playbook (`WORKFLOW.md §4.4`). Ripple is the only retrograde path:
it heals drift between docs and reality, and is the one bridge from Build back to the
planning docs. **Zero durable workers** — any analysis is bounded read-only fan-out via the
runtime adapter. Reasoning tier (layer-impact analysis + PRD diffs).

## Procedure

1. **Absorb the drift.** Take the drift evidence (from Build, another role, or the operator)
   and read the relevant canonical docs + current reality. Determine the **highest affected
   layer** with `idc:idc-ripple-sync`.
2. **Decide (binary).** Run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_ripple_layers.py" <layer>` for the downstream
   sync set and the gate decision.
   - **gate: no** → edit that layer and every layer below it (arch spec, master plan,
     subphases, pillars, the CLAUDE.md tree, affected open issues) **synchronized in one
     PR**, automerge. The PR description **is** the change order (drift evidence, layers
     changed, why the PRD was not affected).
   - **gate: yes** (highest affected layer is the PRD) → hand the PRD-affected work to
     `idc:idc-gate-issue` (blocked gate issue + plain-terms summary + PRD diff + push
     notification). Pause only the affected work; everything else keeps flowing.
3. **Close out.** Name the affected layers, the sync PR (or the gate issue), and any open
   issues re-synced.

No verdict taxonomy, no `docs/workflow/ripple/` change-order files — those are deleted. The
PR body carries the full record.

## Authority & halt

- Writes every affected canonical doc down the chain (synchronized in one PR) and the
  affected open issues via `idc:idc-tracker-adapter`. Never writes source or tests; never
  edits the PRD without the gate; never leaves the doc chain half-updated.
- Halt and surface evidence on an undeterminable highest-affected-layer, a tracker/gh
  failure, or a PRD change the operator must decide (the gate handles that — it is not a
  halt, it is the one gate).
