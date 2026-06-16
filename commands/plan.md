---
description: IDC Plan — decompose an admitted consideration into goal-contract issues on the board (domain experts, matrix deconfliction); pure decomposition, no requirements authoring
argument-hint: '[--consideration <path>] [--slug <name>] [free-form notes]'
---

You are running `/idc:plan`, the planning stage of the IDC pipeline. Operate as the Plan
orchestrator **in this session**: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` end-to-end,
then execute its phases (Absorb → domain experts → plan chain → goal contracts → matrix →
validate + admit).

Operator input: `$ARGUMENTS` — a consideration path (`--consideration <path>`), an optional
slug, and/or free-form notes naming the scope.

**Zero durable workers.** Plan never uses Claude Teams / durable teammates. Every fan-out —
domain experts, plan-chain drafters, clash pairs — is **bounded read-only fan-out** (the Workflow
tool or Task subagents, per `idc:idc-adapter-claude`; `--ephemeral`/`spawn_agent` per
`idc:idc-adapter-codex`). Drafters write to disk and return digests; you never absorb full
doc bodies.

Plan is **pure decomposition** — it operates on an **admitted** consideration (its PRD + TRD already
authored and gated at the end of Think) and **never authors the PRD/TRD and never gates**. What the
run produces and where it writes (`WORKFLOW.md §4.2`): the plan chain (`docs/plans/` master +
subphases + pillars), the phase matrix (`docs/workflow/pillar-matrices/`), and goal-contract issues
on the board via `idc:idc-tracker-adapter`. Every issue body passes `idc:idc-schema-check` before
admission; the matrix passes `idc:idc-matrix-analysis`'s check; re-sequencing is global but
`In Progress` issues are immutable. All issues flow as `Todo` — there is no gate here. Close by
opening the planning PR (body = audit trail) and automerging when green.

Do not write source or tests; never write the PRD/TRD (Think authors + gates them); do not reorder
`In Progress` issues. Halt only on the conditions in the playbook's §Authority & halt (including a
consideration that is not yet admitted — an open Think PR). The next stage is `/idc:build` (or
`/idc:autorun` to drain the whole pipe).
