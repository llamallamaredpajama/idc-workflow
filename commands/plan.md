---
description: IDC Plan — turn a consideration into goal-contract issues on the board (domain experts, doc chain, matrix deconfliction, one PRD gate)
argument-hint: '[--consideration <path>] [--slug <name>] [free-form notes]'
---

`/idc:plan` is the planning stage of the IDC v2 pipeline. In one run it reads a
consideration, fans out read-only domain experts (config-seeded, planner-adjusted domains),
drafts the five-layer doc chain (only the PRD gated), authors a 6-element goal contract per
pillar, runs pairwise clash/matrix deconfliction, re-sequences against the live board
(`In Progress` issues immutable), runs a mechanical schema check, and admits issues to the
tracker — opening a planning PR whose body is the audit trail. **Zero durable workers**
(bounded fan-out only). PRD changes land affected issues `Blocked` behind one gate issue
(`WORKFLOW.md §2`); everything else flows autonomously (`§4.2`).

> v2 rebuild status: the Plan orchestrator playbook + skills (domain dispatch, doc-chain
> drafting, goal-contract authoring, matrix analysis, schema check, board admission, the
> PRD gate) are authored in **Phase 3** of the IDC v2 rebuild — the heart of the rewrite.
> (stub)
