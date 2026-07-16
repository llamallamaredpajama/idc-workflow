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
consideration that is not yet admitted — an open Think PR).

## Command lifecycle — verify at entry, close out through the oracle

The command entry gate opened this command's lifecycle record at expansion; verify it, and **close it
with a validated terminal status** before your final answer (the Stop closeout gate refuses a
walk-away from an open command):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
```

Before the final answer, call the oracle and finish the contract. The final prose **quotes the
oracle's next command/reason**; it never invents a different handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_next_action.py" --repo "$PWD" --json
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command plan \
  --status <complete|no_action|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — every admitted consideration decomposed has a decomposition child; the deconfliction
  matrix re-validates; the consideration pointers are retired; the planning PR is MERGED. Evidence refs:
  `planning_pr`, `planning_pr_state:"MERGED"`, `matrix:"<repo-relative path to the matrix YAML you
  wrote>"` (the validator re-runs `idc_matrix_check` on the referenced file — **never a `"pass"`
  string**), `decompositions:{<consideration>:<child>}`, `pointers_retired:[…]`. (The schema + provenance
  checks still run during decomposition; the durable proof of `complete` is the re-validated matrix
  file + merged planning PR + real decomposition children.)
- **`no_action`** — the **live oracle** reports no admitted consideration to plan (its
  `considerations` count is 0). Never claim `no_action` without that fresh oracle result.
- **`blocked_external`** — a deterministic helper failed: `blocker:{helper, exit (nonzero),
  diagnostic}`.
