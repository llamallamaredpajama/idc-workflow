---
description: IDC Plan — turn a consideration into goal-contract issues on the board (domain experts, doc chain, matrix deconfliction, one PRD gate)
argument-hint: '[--consideration <path>] [--slug <name>] [free-form notes]'
---

You are running `/idc:plan`, the planning stage of the IDC v2 pipeline. Operate as the Plan
orchestrator **in this session**: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-plan.md` end-to-end,
then execute its phases (Absorb → domain experts → doc chain → goal contracts → matrix →
validate + admit).

Operator input: `$ARGUMENTS` — a consideration path (`--consideration <path>`), an optional
slug, and/or free-form notes naming the scope.

**Zero durable workers.** Plan never uses Claude Teams / durable teammates. Every fan-out —
domain experts, doc drafters, clash pairs — is **bounded read-only fan-out** (the Workflow
tool or Task subagents, per `idc:idc-adapter-claude`; `--ephemeral`/`spawn_agent` per
`idc:idc-adapter-codex`). Drafters write to disk and return digests; you never absorb full
doc bodies.

What the run produces and where it writes (`WORKFLOW.md §4.2`): the five-layer doc chain
(`docs/prd/`, `docs/specs/`, `docs/plans/` master + subphases + pillars — only the PRD
gated), the phase matrix (`docs/workflow/pillar-matrices/`), and goal-contract issues on the
board via `idc:idc-tracker-adapter`. Every issue body passes `idc:idc-schema-check` before
admission; the matrix passes `idc:idc-matrix-analysis`'s check; re-sequencing is global but
`In Progress` issues are immutable. If the run changes the PRD, the PRD-touching issues land
`Blocked` behind one `idc:idc-gate-issue` while non-PRD work flows. Close by opening the
planning PR (body = audit trail) and automerging when green.

Do not write source or tests; do not edit the PRD without the gate; do not reorder
`In Progress` issues. Halt only on the conditions in the playbook's §Authority & halt. The
next stage is `/idc:build` (or `/idc:autorun` to drain the whole pipe).
