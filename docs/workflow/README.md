# docs/workflow/ — IDC process artifacts

`/idc:init` copies this tree to `docs/workflow/` in your repo. It holds operational
artifacts for the IDC chain. It **supports** the canonical chain; it is not authority by
itself. The authority surfaces are `WORKFLOW.md` (role boundaries) and the canonical
documents under `docs/prd/`, `docs/specs/`, and `docs/plans/`.

## Canonical chain

`docs/prd/ → docs/specs/ → docs/plans/master-implementation-plan.md →
docs/plans/subphases/ → docs/plans/pillars/ → TRACKER`

Supporting route: `docs/considerations/` (pre-canonical Think input) → the canonical
chain → Build → `docs/workflow/ripple/` (proposed change orders, not accepted truth
until a gated Ripple PR lands).

## Directories

| Directory | Purpose |
|---|---|
| `audits/` | Audits, deviation ledgers, plan reviews, and program-level review reports. |
| `code-reviews/` | PR / commit / phase-close adversarial review reports (referenced from TRACKER, never inlined). |
| `diagrams/` | Architecture and flow diagrams referenced by the canonical docs. |
| `handoffs/` | End-of-session handoff artifacts. Split by kind into subdirs as needed (e.g. `phases/`, `waves/`, `considerations/`, `subphases/`, `pillars/`, `builds/`, `ripples/`); the `§Verification` stanza in a handoff is non-negotiable. |
| `ledgers/` | Run ledgers and program-level execution journals (multi-batch programs, ripple chains). |
| `operator-todos/` | Per-build operator-deferred actions discovered mid-flight (BLOCKING items + side-jobs). |
| `phase-planning/` | Plan-authored phase-wide planning manifests (`<phase-tag>-planning-manifest.yaml`) listing every expected subphase and whether it is `drafted`, `parked-ripple`, or `intentionally-deferred` before Sequence admits tracker work. |
| `pillar-conflicts/` | Pair-wise clash-detection evidence that informs Plan's clash analysis and Ripple. |
| `pillar-matrices/` | Polished phase matrices (`<phase-tag>-matrix.yaml`) — the substrate for Dependency-DAG / Parallel-Safety / Wave-Ordering views Build reads on dispatch. |
| `plans/` | Workflow / governance plans (new IDC roles, governance-rule changes). **Not** codebase plans — those live at `docs/plans/`. |
| `ripple/` | Proposed change orders and drift-resolution packets (`<change-order-slug>-ripple.md`). |

## Reserved paths

`docs/workflow/pi-idc-governance-contract.yaml` is reserved for externally-compiled
governance contracts/lockfiles. It is not created by `/idc:init`; it is owned by an
external harness's compile step (e.g. `pi-idc-collab`'s governance compile/check).

## Plan split (codebase vs. workflow)

- **Codebase plans** (work against your source surfaces, e.g. `services/`, `web/`, `ml/`)
  live under `docs/plans/`.
- **Workflow / governance plans** (new IDC roles, governance-rule changes) live under
  `docs/workflow/plans/`.

Each directory ships with an empty `.gitkeep` so the scaffold survives a fresh clone;
delete it once the directory has real content.
