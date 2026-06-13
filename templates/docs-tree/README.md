# docs/workflow/ — IDC process artifacts

`/idc:init` copies this tree to `docs/workflow/` in your repo. It holds the operational
artifacts the IDC chain produces. It **supports** the canonical chain; it is not authority
by itself. The authority surfaces are `WORKFLOW.md` (role boundaries) and the canonical
documents under `docs/prd/`, `docs/specs/`, and `docs/plans/`.

## Canonical chain

`docs/prd/ → docs/specs/ → docs/plans/master-implementation-plan.md →
docs/plans/subphases/ → docs/plans/pillars/ → tracker issues`

Supporting route: `docs/considerations/` (pre-canonical Think input) → the canonical chain
→ tracker issues (the glass wall) → Build. Ripple is the only retrograde path; it syncs
the whole chain in one PR rather than leaving change-order files behind.

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
