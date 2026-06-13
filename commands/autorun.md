---
description: IDC Autorun — one-shot full-pipe drainer (plan unplanned considerations, heal the board, build eligible waves)
argument-hint: '[--consideration <path>...] [free-form notes]'
---

`/idc:autorun` traverses the whole pipe end-to-end in one shot. It plans every consideration
not yet planned (one plan-run worker per consideration, with board admission **serialized**
through the autorun parent), heals board hygiene as it passes, and activates Build to claim
eligible waves as they land — including ones unblocked mid-run from the operator's phone. On
a quiet repo it just fixes the board and drains stragglers. It exits with a report when
nothing actionable remains (only PRD-gated items waiting on the operator). Loopable via
`/loop /idc:autorun` for standing operation. This is the janitor — `/idc:doctor` stays
read-only (`WORKFLOW.md §4.5`).

> v2 rebuild status: the Autorun two-lane orchestrator playbook is authored in **Phase 6**
> of the IDC v2 rebuild. (stub)
