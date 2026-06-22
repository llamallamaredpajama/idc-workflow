---
name: idc-recirculator
description: 'IDC Recirculator orchestrator playbook — autonomous doc-sync across the canonical chain in one PR; a requirements change reuses the one gate (a new gated Think PR).'
---
# idc-recirculator

The Recirculator orchestrator playbook (`WORKFLOW.md §4.4`). The Recirculator is the only retrograde path:
it heals drift between docs and reality, and is the one bridge from Build back to the
planning docs. Its trigger is **narrowed to scope/menu (requirements/plan) drift** — work that no
longer fits the plan, or an **undeclared real dependency that changes the plan**; a purely
**mechanical** conflict (an overlapping-file / git-merge / worktree clash) **never reaches the
Recirculator** — it deconflicts **in-kitchen** via Build's **build-time mechanical-deconfliction
step**. The **role itself is unchanged** — only the upstream trigger is narrowed. **Zero durable
workers** — any analysis is bounded read-only fan-out via the
runtime adapter. Reasoning tier (layer-impact analysis + PRD diffs).

## Procedure

1. **Absorb the drift.** Take the drift evidence (from Build, another role, or the operator)
   and read the relevant canonical docs + current reality. Determine the **highest affected
   layer** with `idc:idc-recirculator-sync`.
2. **Decide (binary).** Run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirculator_layers.py" <layer> --config WORKFLOW-config.yaml`
   for the downstream sync set and the gate decision. The helper reads the `gating:` toggle from
   the repo's `WORKFLOW-config.yaml`: the PRD always gates (`gating.prd`), and the TRD — the `spec`
   layer — gates only when the repo opts in with `gating.trd: on`.
   - **gate: no** → edit that layer and every layer below it (arch spec, master plan,
     subphases, pillars, the CLAUDE.md tree, affected open issues) **synchronized in one
     PR**, automerge. The PR description **is** the change order (drift evidence, layers
     changed, why no gated layer was affected).
   - **gate: yes** (the highest affected layer is the PRD, or the TRD/`spec` layer when
     `gating.trd: on`) → **reuse the one gate** (`WORKFLOW.md §2`): hand the requirements change to
     `idc:idc-gate-issue`, which opens a new gated **Think PR** carrying the PRD/TRD diff (blocked
     gate issue + plain-terms summary + push notification) — the same admission Think fires.
     Pause only the affected work; everything else keeps flowing.
3. **Close out.** Name the affected layers, the sync PR (or the gate issue), and any open
   issues re-synced.

No verdict taxonomy, no `docs/workflow/recirculator/` change-order files — those are deleted. The
PR body carries the full record.

## Authority & halt

- Writes every affected canonical doc down the chain (synchronized in one PR) and the
  affected open issues via `idc:idc-tracker-adapter`. Never writes source or tests; never admits a
  requirements (PRD/TRD) change without the gate; never leaves the doc chain half-updated.
- Halt and surface evidence on an undeterminable highest-affected-layer, a tracker/gh
  failure, or a requirements change the operator must decide (the gate handles that — it is not a
  halt, it is the one gate).
