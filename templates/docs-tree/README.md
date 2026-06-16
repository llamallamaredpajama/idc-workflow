# docs/workflow/ — IDC process artifacts

`/idc:init` copies this tree to `docs/workflow/` in your repo. It holds the operational
artifacts the IDC chain produces. It **supports** the canonical chain; it is not authority
by itself. The authority surfaces are `WORKFLOW.md` (role boundaries) and the canonical
documents under `docs/prd/`, `docs/specs/`, and `docs/plans/`.

## Canonical chain

Think authors the **two gated requirements docs** — the **PRD** (`docs/prd/`, the user-facing
*what*) and the **TRD** (`docs/specs/`, the technical *how*) — and gates them at the end of Think on
the Think PR (`docs/considerations/` records the brainstorm that drives them). Plan then **decomposes
the admitted PRD+TRD** down the plan chain into tracker issues — it authors no requirements:

`docs/prd/ + docs/specs/ (PRD + TRD — authored & gated at Think) →
docs/plans/master-implementation-plan.md → docs/plans/subphases/ → docs/plans/pillars/ →
tracker issues`

Decomposed issues cross the glass wall into Build. The Recirculator is the only retrograde path; it
syncs the whole chain in one PR rather than leaving change-order files behind, reusing the Think-PR
gate when a requirements layer (PRD, or the TRD when gated) changes.

## Directories

v2 keeps the process tree lean — only the two artifact stores the guardrails actually
produce. Everything else (audit ledgers, change-order files, planning manifests, clash
files, handoffs) is gone: a PR body is the audit trail, and the matrix YAML is the durable
deconfliction record.

| Directory | Purpose |
|---|---|
| `pillar-matrices/` | Polished phase matrices (`<phase-tag>-matrix.yaml`) — Plan's pairwise-clash deconfliction output: the Dependency-DAG / Parallel-Safety / Wave-Ordering substrate the board's `Wave` field is assigned from. |
| `code-reviews/` | Merged-review-engine reports for build PRs and phase-close deltas (referenced from issues, never inlined). |

`docs/workflow/tracker-config.yaml` (the tracker contract) is also placed here by
`/idc:init`. Each directory ships with an empty `.gitkeep` so the scaffold survives a
fresh clone; delete it once the directory has real content.
