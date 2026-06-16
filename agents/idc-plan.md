---
name: idc-plan
description: 'IDC Plan orchestrator playbook — consideration → goal-contract issues on the board, in one zero-teammate run.'
---
# idc-plan

The Plan orchestrator playbook (`WORKFLOW.md §4.2`). Plan is **pure decomposition**: one run turns
an **admitted** consideration — its PRD + TRD already authored and gated at the end of Think — into
goal-contract issues on the board. Plan **never authors the PRD/TRD and never gates**; that happened
on the Think PR. **Zero durable workers** — every fan-out is bounded read-only work through the
runtime adapter (`idc:idc-adapter-claude` / `idc:idc-adapter-codex`). Plan authors contracts (issue
bodies); Build only executes them. The two plan reviews are matrix deconfliction + the schema check
— nothing else.

Run the phases in order; each phase's evidence gates the next.

## Phase 0 — Absorb

- Read the consideration; validate its shape with `idc:idc-consideration-schema`. Confirm it is
  **admitted** (its Think PR merged); an un-admitted consideration is not yet Plan's to decompose.
- Read the admitted requirements (the PRD + TRD) and the master plan, plus the live board through
  `idc:idc-tracker-adapter` (`query`). Note which issues are `In Progress` — they are
  immutable for the rest of the run.
- Resolve the repo's standing domains from `WORKFLOW-config.yaml::domains`; prune to the
  domains this consideration touches, adding ad-hoc ones as needed.

## Phase 1 — Horizontal slice (domain experts)

Bounded fan-out of one read-only domain-expert per touched domain (reasoning tier). Each
returns, for its slice: what the consideration requires, what already exists, the gap,
risks, and goal-shaped work items. The orchestrator absorbs the digests, not full reasoning.

## Phase 2 — Draft the plan chain (decomposition)

The PRD + TRD are already authored and admitted (the merged Think PR) — Plan does **not** touch
them. Draft only the **plan layers** below the requirements: the master-plan section, subphase
plans, and pillar plans, each tracing back to the admitted PRD/TRD. Parallel drafting fan-out
**writes to disk and returns digests**; the orchestrator never absorbs full doc bodies. These
plan-chain layers are autonomous (no gate) and survive as files for traceability.

## Phase 3 — Author the goal contracts

Distill each pillar into a complete contract with `idc:idc-goal-contract`
(complexity-adaptive; real-functional-test verification surfaces). Templated emission of the
issue body from the authored contract is utility-tier; the contract authoring itself is
reasoning-tier.

## Phase 4 — Vertical slice (matrix)

Run `idc:idc-matrix-analysis`: pairwise clash fan-out → synthesize the phase matrix at
`docs/workflow/pillar-matrices/<phase-tag>-matrix.yaml` → re-sequence the board **globally**
against it (all not-`In Progress` items), assigning parallel-safe waves. Validate with
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_matrix_check.py" <matrix>`. A genuine upstream
contradiction that can't be deconflicted is parked and surfaced for a recirculation — never papered.

## Phase 5 — Validate + admit

1. Run `idc:idc-schema-check` on every issue body
   (`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_schema_check.py" <body>`); fix until PASS.
2. Create issues and set `Status`/`Wave`/`Phase`/`Domain` + native blocked-by through
   `idc:idc-tracker-adapter`. All issues flow as `Todo` — **there is no gate in Plan**; the
   requirements were already admitted at the end of Think.
3. Advance the consideration pointer (`Consideration → Planning`, retired as buildable issues
   land); open the planning PR whose **body is the audit trail** (what was planned, the matrix,
   the trace) and **automerge when green** (no human touchpoint here).

## Model tiers (resolved by the runtime adapter)

- `reasoning`: domain-expert synthesis, goal-contract authoring, clash/matrix judgment,
  sequencing decisions.
- `utility`: repo recon, research digestion, templated emission (issue bodies from
  contracts, matrix siblings, the PR description), board mechanics, the two checks.

## Authority & halt

- Writes `docs/plans/` (master + subphases + pillars), pillar matrices, and tracker issues.
  **Never** writes the PRD/TRD (Think authors + gates them), never source/tests, never reorders
  `In Progress`, never gates.
- Halt and surface evidence on: a consideration that fails the schema check or is not yet
  admitted (an open Think PR); an
  undeconflictable clash / upstream contradiction (park + recirculation); a tracker/gh failure the
  adapter surfaces; or missing input.
