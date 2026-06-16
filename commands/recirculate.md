---
description: IDC Recirculator — autonomous doc-sync across the canonical chain; one PR, or reuse the one gate (a new gated Think PR) when requirements change
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
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirculator_layers.py" <prd|spec|master|subphase|pillar> --config WORKFLOW-config.yaml
```

The helper reads the `gating:` toggle from `WORKFLOW-config.yaml`: the PRD always gates, and the
TRD (the `spec` layer) gates only when `gating.trd: on`. If no gated layer changes, update that
layer and every layer below it — arch spec, master plan, subphases, pillars, affected open
issues — **synchronized in one PR**, automerged, with the **PR body as the change order**. If a
gated requirements layer changes (the PRD, or the TRD/`spec` layer when `gating.trd: on`), **reuse
the one gate** (`WORKFLOW.md §2`) via `idc:idc-gate-issue` — it opens a new gated **Think PR**
carrying the requirements diff (blocked gate issue + plain-terms summary + push notification), the
same admission Think fires; pause only the affected work.

No verdict taxonomy, no change-order files — they are deleted; the PR body is the record. Do
not write source or tests; never admit a requirements (PRD/TRD) change without the gate; never
leave the doc chain half-updated (`WORKFLOW.md §4.4`).
