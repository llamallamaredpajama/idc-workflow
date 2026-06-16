---
description: IDC Recirculator — autonomous doc-sync across the canonical chain; one PR, PRD-only gate
argument-hint: '<drift-description | "scope summary">'
---

You are running `/idc:recirculate`, the only retrograde path from Build back to the planning docs.
Operate as the Recirculator orchestrator **in this session**: read
`${CLAUDE_PLUGIN_ROOT}/agents/idc-recirculator.md` end-to-end, then execute its procedure (absorb
the drift → decide → sync or gate → close out).

Operator input: `$ARGUMENTS` — a drift description or scope summary (from Build, another
role, or the operator).

**Zero durable workers** — any analysis is bounded read-only fan-out per the runtime adapter.
Use `idc:idc-recirculator-sync` to determine the highest affected canonical layer, the downstream
sync set, and the gate decision:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirculator_layers.py" <prd|spec|master|subphase|pillar>
```

If user-facing product function does **not** change, update that layer and every layer below
it — arch spec, master plan, subphases, pillars, affected open issues — **synchronized in one
PR**, automerged, with the **PR body as the change order**. If it **does** (the highest
affected layer is the PRD), take the same gate as Plan via `idc:idc-gate-issue` (blocked gate
issue + plain-terms summary + PRD diff + push notification); pause only the affected work.

No verdict taxonomy, no change-order files — they are deleted; the PR body is the record. Do
not write source or tests; do not edit the PRD without the gate; never leave the doc chain
half-updated (`WORKFLOW.md §4.4`).
