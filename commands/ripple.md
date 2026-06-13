---
description: IDC Ripple — autonomous doc-sync across the canonical chain; one PR, PRD-only gate
argument-hint: '<drift-description | "scope summary">'
---

`/idc:ripple` is the only retrograde path from Build back to the planning docs. It
determines the highest affected layer and answers one question — does user-facing product
function change? **No** → it updates every affected doc down the chain in **one PR**
(arch spec, master plan, subphases, pillars, affected open issues), automerged, with the PR
body as the change order. **Yes** → the same gate mechanism as Plan (a blocked operator-todo
gate issue + plain-terms summary + PRD diff + push notification). **Zero durable workers.**
No verdict taxonomy, no change-order files — the PR body is the record (`WORKFLOW.md §2`,
`§4.4`).

> v2 rebuild status: the Ripple playbook + doc-sync skill are authored in **Phase 5** of
> the IDC v2 rebuild. (stub)
