---
name: idc-plan
description: 'IDC Plan orchestrator playbook — consideration → goal-contract issues on the board, in one zero-teammate run.'
---
# idc-plan

The Plan orchestrator playbook (`WORKFLOW.md §4.2`). One run turns a consideration into
goal-contract issues on the board. **Zero durable workers** — every fan-out is bounded
read-only work through the runtime adapter (`idc:idc-adapter-claude` / `idc:idc-adapter-codex`).
Plan authors contracts; Build only executes them. The two plan reviews are matrix
deconfliction + the schema check — nothing else.

Run the phases in order; each phase's evidence gates the next.

## Phase 0 — Absorb

- Read the consideration; validate its shape with `idc:idc-consideration-schema`.
- Read the canonical chain (PRD, spec, master plan) and the live board through
  `idc:idc-tracker-adapter` (`query`). Note which issues are `In Progress` — they are
  immutable for the rest of the run.
- Resolve the repo's standing domains from `WORKFLOW-config.yaml::domains`; prune to the
  domains this consideration touches, adding ad-hoc ones as needed.

## Phase 1 — Horizontal slice (domain experts)

Bounded fan-out of one read-only domain-expert per touched domain (reasoning tier). Each
returns, for its slice: what the consideration requires, what already exists, the gap,
risks, and goal-shaped work items. The orchestrator absorbs the digests, not full reasoning.

## Phase 2 — Draft the doc chain

Draft the five-layer chain — PRD diff (only if user-facing function changes), arch-spec
updates, the master-plan section, subphase plans, pillar plans. Parallel drafting fan-out
**writes to disk and returns digests**; the orchestrator never absorbs full doc bodies. All
five layers survive as files for traceability; **only the PRD is gated** (Phase 5).

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
   `idc:idc-tracker-adapter`.
3. **PRD gate:** if the run changes the PRD, hand the PRD-touching issues to
   `idc:idc-gate-issue` — they land `Blocked` behind one gate issue (plain-terms summary +
   PRD diff + push notification). Non-PRD issues from the same run flow as `Todo`.
4. Archive the consideration; open the planning PR whose **body is the audit trail** (what
   was planned, the matrix, the trace); automerge when green (the PRD gate is the only human
   touchpoint).

## Model tiers (resolved by the runtime adapter)

- `reasoning`: domain-expert synthesis, goal-contract authoring, clash/matrix judgment,
  sequencing decisions, the PRD diff.
- `utility`: repo recon, research digestion, templated emission (issue bodies from
  contracts, matrix siblings, the PR description), board mechanics, the two checks.

## Authority & halt

- Writes `docs/prd/`, `docs/specs/`, `docs/plans/` (master + subphases + pillars), pillar
  matrices, and tracker issues. **Never** source/tests, never reorders `In Progress`, never
  edits the PRD without the gate.
- Halt and surface evidence on: a consideration that fails the schema check; an
  undeconflictable clash / upstream contradiction (park + recirculation); a tracker/gh failure the
  adapter surfaces; or missing input.
