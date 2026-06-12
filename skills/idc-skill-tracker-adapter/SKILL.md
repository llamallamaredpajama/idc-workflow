---
name: idc-skill-tracker-adapter
description: 'Use when an IDC role needs tracker operations routed through the repo-configured backend.'
---
# idc:idc-skill-tracker-adapter

Dispatch surface for the portable Tracker interface defined at `WORKFLOW.md §6 Tracker substrate`. Resolves the active backend from `docs/workflow/tracker-config.yaml::backend` and routes calls to the matching implementation skill so callers never hard-code `filesystem` or `github` semantics.

This skill is the surface that root `CLAUDE.md §Canonical Document Hierarchy` resolves through when the canonical-chain terminates at the Tracker. Per-repo backend selection is owned by `docs/workflow/tracker-config.yaml`; this skill reads that file and dispatches.

## When to invoke

- Inside `idc-sequence` Wave-admission edits (TRACKER ordering writes route through `createTicket` / `setField` / `move`).
- Inside `idc-build` matrix dispatch-check + bookend-open / bookend-close mutations.
- Inside `idc-build` §Phase 4.5 next-wave rollover (`promote_wave_status` op — the only Status write Build is admitted for; see operational ops below).
- Inside `idc-engineer` §Phase 1 bootstrap (initial GitHub Project provisioning) and §Phase 5 cutover (filesystem→github backend flip).
- Inside `idc-ripple` when drift detection requires reading active Tracker state (`query` + `export-state`).
- NOT for direct edits of `docs/workflow/tracker-config.yaml::backend` — that mutation is operator-gated and runs through the explicit `flip-to-filesystem` op (gh-outage fallback) or Engineer's §Phase 5 cutover.
- NOT for direct edits of `TRACKER.md` (filesystem) or GitHub Projects items (github) — always go through this adapter so backend swaps remain transparent.

## Input contract

| Field | Shape |
|-------|-------|
| `repo_root` | absolute path to the IDC-governed repo root (must contain `docs/workflow/tracker-config.yaml`) |
| `operation` | one of the six core ops or three operational ops (see below) |
| `args` | per-operation argument bag (see signatures below) |
| `output_path` | optional — present for `export-state` (state.json target) and `flip-to-filesystem` (audit-log target) |

### Backend resolution

The skill loads `<repo_root>/docs/workflow/tracker-config.yaml` via the project's stdlib YAML reader (`docs/workflow/scripts/pillar_matrix.py::parse_matrix_yaml`) and reads the `backend` key. Valid values:

| `backend` value | Implementation skill dispatched |
|-----------------|----------------------------------|
| `filesystem` | `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-filesystem-tracker-implementation/SKILL.md` |
| `github` | `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-github-tracker-implementation/SKILL.md` |

Any other value → halt with structured error `unknown_backend: <value>`. The adapter does NOT default-fallback to `filesystem` — explicit YAML mismatches are programmer errors that must surface, not silently degrade.

## Six core operations

Per `WORKFLOW.md §6.2 Six core operations` — the contract is identical here; the adapter routes without reshaping signatures.

| Operation | Signature | Routed to |
|-----------|-----------|-----------|
| `createTicket` | `(title, body, type, labels) → ticket_id` | active backend implementation |
| `setField` | `(ticket_id, field, value)` | active backend implementation |
| `link` | `(parent_id, child_id, kind ∈ {sub, blocks})` | active backend implementation |
| `move` | `(ticket_id, status ∈ {Pending, Active, Blocked, Complete})` | active backend implementation |
| `query` | `(filter) → [ticket_id, ...]` | active backend implementation |
| `comment` | `(ticket_id, body)` | active backend implementation |

The github backend enforces a 50-item dependency cap on `link(kind=sub|blocks)` per GitHub Projects V2 limits; the adapter surfaces the structured error from the implementation without translation.

## Operational ops

Per `WORKFLOW.md §6.2 Operational ops` — these surround the six core ops and ride the same dispatch:

- **`export-state(--output <state.json>)`** — emits `{pillar_id: status}` JSON for downstream tooling (Build's matrix dispatch-check chain consumes this via `pillar_matrix.py::_load_tracker_state`).
- **`acquire-lane-lock(--lane=<lane>, --ticket=<id>, --idempotency-key=<sha>)`** — atomic lane-lock primitive backing bookend-open transactions; algorithm details admitted at Engineer's §Phase 1.
- **`flip-to-filesystem(--reason=<text>, --audit-log=<path>)`** — explicit operator-gated fallback for gh-outage; mutates `tracker-config.yaml::backend` from `github` to `filesystem` and writes an audit-log entry.
- **`promote_wave_status(wave=<wave-id>, phase=<phase-tag>)`** — flip every item in the named wave from `Status=Pending` to `Status=Active`. Single caller — `idc-build` §Phase 4.5 next-wave rollover. Admitted as Build's only Status write surface per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out`. The op refuses to fire if any item in the candidate wave has an unsatisfied `blocks_on` upstream (precondition is the adapter's contract, not the caller's). The matrix YAML for the target phase is resolved through the same 3-step contract documented at `promote_next_eligible_wave` below — canonical home `docs/workflow/pillar-matrices/`, canonical filename template `phase-<slug>-matrix.yaml`; never a hard-coded legacy path. Returns one of `promoted: wave=<N>, items=[#<a>,#<b>,...]` on success, `no_candidate` when nothing is promotable, or a structured fail-closed error envelope on backend failure. Deprecated in favor of `promote_next_eligible_wave` (universal scope; discovers the target wave itself). Kept as a named alias for callers that have already identified the target wave; new callers should prefer the universal op.
- **`promote_next_eligible_wave()`** — universal-scope wave-discovery-and-promote. Discovers the lowest-numbered Pending wave (across all phases and subphases) whose items have fully satisfied `blocks_on` upstream AND whose target phase has a matrix YAML present under the canonical home `docs/workflow/pillar-matrices/`; flips every item in that wave from `Status=Pending` to `Status=Active`. Single caller — `idc-build` §Phase 7 autowave loop driver (and §Phase 4.5 next-wave rollover when invoked from autowave-aware Phase 4.5). Admitted as Build's only universal Status write surface per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out`. Preconditions enforced by the implementation: candidate wave's items all have closed `blocks_on` upstream; the wave's matrix YAML resolves through the 3-step contract below.

  Eligibility resolves the matrix YAML via this contract:

  1. **Issue-body metadata** — if the candidate's GitHub issue body carries a `Matrix YAML:` line, that path is load-bearing.
  2. **Pillar-trace-key scan** — else, scan `docs/workflow/pillar-matrices/*-matrix.yaml`; the matching matrix is the one whose `pillars[]` array contains the candidate's `pillar_trace_key`.
  3. **Filename-template fallback** — else, derive from the `Phase` field via the canonical template `docs/workflow/pillar-matrices/phase-<slug>-matrix.yaml` (where `<slug>` is the phase NAME, not the `Phase` field value — e.g., `phase-12-platform-rebuild`, not `phase-12-1`).

  Returns one of `promoted: wave=<N>, phase=<P>, items=[#<a>,#<b>,...]` on success, `no_candidate (eligible-blocked)` when one or more Pending waves exist but every one has unsatisfied upstream, `no_candidate (substrate-missing)` when the only candidate wave's matrix YAML is missing, `no_candidate (tracker-exhausted)` when no Pending waves remain at all, or a structured fail-closed error envelope on backend failure.
- **`apply_dispatch_labels(issue_numbers: list[int], wave: str, phase: str)`** — apply `wave:<wave>` and `phase:<phase>` labels to each issue in `issue_numbers`. Single caller — `idc:idc-role-bootstrap-researcher` §Build-mode wave assessment step 9 (the pre-dispatch label shell is folded into the bootstrap researcher's wave-assessment step so each dispatched work unit arrives self-contained — one fewer orchestration hop; see `${CLAUDE_PLUGIN_ROOT}/agents/idc-role-bootstrap-researcher.md` step 9 + `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Non-Negotiables`). GitHub backend executes `gh issue edit <N> --add-label "wave:<wave>" --add-label "phase:<phase>"` per issue. Filesystem backend mirrors the existing label-edit pattern its other ops use against `TRACKER.md` (per-row label-cell rewrite with read-modify-write; same posture as the filesystem backend's existing `setField` label writes). **Idempotent**: re-applying a label already present is a no-op — the implementation must detect `already_present` before issuing the underlying mutation so a re-run after partial failure is safe. Returns a per-issue mutation result list of the form `applied: [{issue: <N>, applied: bool, already_present: bool, error?: <str>}, ...]` — `applied=true, already_present=false` on a fresh write, `applied=false, already_present=true` on idempotent re-run, `applied=false, error=<msg>` on backend failure for that issue (other issues in the batch still attempt). Top-level verdict mirrors the rest of the ops surface: success when every entry has `error` absent; structured fail-closed error envelope when one or more entries carry `error` (caller decides retry / halt / `flip-to-filesystem` per `WORKFLOW.md §6.8`).
- **`complete_claimed_item(issue, claim_handle)`** — Build-scope op that atomically marks one wave-completed item Complete after Build's PR merges to main. Single caller — `idc-build` §Phase 6 bookend-close once the linked PR(s) merge to `origin/main`. Admitted as Build's terminal Status write surface (the Active→Complete leg of the Build carve-out) per `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md §Status-field carve-out`.

  **Inputs:** `issue` (one issue ref the caller currently holds the lane lock on), `claim_handle` (lane-lock token Build acquired at bookend-open).

  **Mutations (atomic, idempotent):**
  - `Status: Active → Complete`
  - `ClaimState: → Released`
  - `Lane: → (idle)`
  - Close the underlying GitHub issue (or no-op if already closed).

  **Idempotent:** if the item is already `Status=Complete`, the op returns success with no mutations.

  **Refuses (returns error, no mutations):**
  - Caller does not currently hold the lane lock for `issue`.
  - The PR(s) linked to `issue` are not merged to `origin/main` (verified by `git merge-base --is-ancestor` against each linked PR's merge commit).
  - `issue` is in `Status=Pending` (initial admission is Sequence-owned).

  Backend-specific implementation contracts live in the dispatched implementation skills — GitHub backend at `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-github-tracker-implementation/SKILL.md`, filesystem backend at `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-filesystem-tracker-implementation/SKILL.md`. This adapter routes the op signature unchanged; the implementation skills carry the atomic-mutation algorithm details.

## Output contract

The skill returns an adapter handle keyed by the resolved backend:

```yaml
adapter_handle:
  backend: filesystem | github                    # echoed from tracker-config.yaml
  config_path: <repo_root>/docs/workflow/tracker-config.yaml
  implementation_skill: idc:idc-skill-filesystem-tracker-implementation  # or idc:idc-skill-github-tracker-implementation, per backend
  operations:
    core: [createTicket, setField, link, move, query, comment]
    operational: [export-state, acquire-lane-lock, flip-to-filesystem, promote_wave_status, promote_next_eligible_wave, apply_dispatch_labels, complete_claimed_item]
  result: <return value of the dispatched operation>   # ticket_id | list | unit | error envelope
```

On dispatched-operation failure, the adapter returns a structured error envelope `{error_kind, raw_error, retried: false}` — no automatic retry; the caller decides whether to retry, halt, or invoke `flip-to-filesystem` (per `WORKFLOW.md §6.8 Fail-closed posture + flip-to-filesystem`).

## Fail-closed posture

The adapter inherits the fail-closed posture documented at `WORKFLOW.md §6.8 Fail-closed posture`:

1. Implementation-skill failure (gh CLI exit code ≠ 0, GraphQL error, network timeout, filesystem write failure) → emit a structured failure event to the run ledger with the failing operation + raw error.
2. Refuse dispatch (return non-zero from the adapter handle's `result` so Build halts before any source-code commit).
3. Surface an operator decision: continue waiting, or invoke `flip-to-filesystem` for gh-outage scenarios.

The fail-closed posture is fence-pinned at `tests/test_arch_tracker_adapter_offline.py` (LANDED LATER by Engineer's §Phase 1).

## Authority boundaries

- Read+route-only — never mutates `docs/workflow/tracker-config.yaml::backend` outside the explicit `flip-to-filesystem` op.
- Never writes to TRACKER.md (filesystem) or GitHub Projects items (github) directly — always delegates to the implementation skill.
- Never decides backend selection — the per-repo `tracker-config.yaml` is the source of truth.
- Never spawns teammates.
- Never reads or writes canonical docs (PRD, master architectural spec, master implementation plan, subphase plans, pillar plans).

## Citations

- Portable interface spec: `WORKFLOW.md §6 Tracker substrate` (six-method contract, project schema, label namespace, bookend mechanics, fail-closed posture, cutover runbook reference).
- Per-repo backend selector: `docs/workflow/tracker-config.yaml` (P1 — `backend: filesystem`; Engineer §Phase 5 cutover flips to `github`).
- Filesystem implementation: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-filesystem-tracker-implementation/SKILL.md` (renamed from `tracker-wave-queue-edit` at OR-A3).
- GitHub implementation: `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-github-tracker-implementation/SKILL.md` (NEW at OR-A2 — algorithm details admitted by Engineer's §Phase 1).
- Source plan: `docs/workflow/plans/workflow-changes/2026-05-08-tracker-github-migration-plan.md`.
- Ripple change order: `docs/workflow/ripple/2026-05-08-tracker-github-migration-ripple.md`.
- Autowave loop driver source plan: `docs/workflow/ripple/2026-05-15-autowave-carve-out-widening-ripple.md` (NEW — admits `promote_next_eligible_wave` as the universal-scope counterpart to `promote_wave_status`).
- `complete_claimed_item` backend implementation contracts: GitHub backend at `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-github-tracker-implementation/SKILL.md`; filesystem backend at `${CLAUDE_PLUGIN_ROOT}/skills/idc-skill-filesystem-tracker-implementation/SKILL.md`. The adapter routes the op signature unchanged; atomic-mutation algorithm details live in the implementation skills.
