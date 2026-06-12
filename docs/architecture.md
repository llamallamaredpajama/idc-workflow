# IDC Architecture

This page explains how the pieces of the IDC plugin fit together: the role chain, the
write-authority boundaries that keep roles from stepping on each other, the tracker
contract, and how commands, agents, and skills compose at runtime.

It is derived from the governance contract shipped in `templates/WORKFLOW.md` and the
`idc:idc-workflow` routing skill. For the per-repo rules a governed project actually runs
under, read that project's own `WORKFLOW.md`.

## The role chain

IDC is a chain of five roles. The everyday path is linear; **Ripple** is the escape hatch
that runs whenever any role discovers the plan no longer matches reality.

```
Think → Plan → Sequence → Build
                      ↑
                   Ripple   (drift handling — can be triggered from any role)
```

The canonical document chain — the spine everything traces to — is:

```
PRD → architecture spec → master implementation plan → subphase plans → pillar plans → TRACKER
```

`docs/considerations/` is pre-canonical input (Think's output). `docs/workflow/ripple/` is a
change-order inbox: a proposal is not accepted truth until a gated Ripple PR lands.

> Historically the cognitive work now owned by **Plan** was split across three sub-roles
> (Engineer, Develop, Deconflict). Those are merged into Plan; you may still see the older
> names in some skill bodies, but the live surface is the five roles above.

## Write-authority boundaries

The core invariant: **each role is the sole writer of its surface, and no role edits a
surface upstream of it.** This is what makes the chain auditable.

| Role | May write | Must NOT write |
|------|-----------|----------------|
| **Think** | `docs/considerations/` only | any canonical doc, tracker, source, tests; may not declare scope admitted |
| **Plan** | PRD, architecture spec, master plan, subphase plans, pillar plans, clash evidence, planning manifest, matrix | source, tests, tracker ordering |
| **Sequence** | tracker ordering/status, optional wave handoffs | PRD, specs, plans, pillars, source, tests |
| **Build** | source, tests, implementation-PR artifacts, `docs/workflow/operator-todos/`, status-only tracker bookends | PRD, specs, master/subphase/pillar plans |
| **Ripple** | change orders + gated canonical/planning-doc PRs (after operator approval) | source, tests; no automatic canonical edits |

When a lower role discovers a higher layer is wrong (e.g. Build finds the pillar plan
contradicts the architecture spec), it does **not** fix the upstream doc itself. It stops,
files a Ripple, and pauses the affected work. Ripple is the single guarded path for
cross-role canonical edits.

### The Engineer Gate

Plan and Ripple edits to the most authoritative docs are operator-gated:

- **PRD / architecture spec** edits need operator approval **before drafting** and **before
  merge** (Ripple verdict `MAJOR_GATED`).
- **Master / subphase / pillar plan** edits need approval **before merge** (`GATED`).
- Subphase plans, pillar plans, clash evidence, and the planning manifest are autonomous.

## Two edit pipelines

Ripple is the shared canonical-edit guard for two pipelines (from the `idc:idc-workflow`
skill):

- **Codebase pipeline** — the `Think → Plan → Sequence → Build` chain, for changes whose
  source-of-truth is product/runtime code, specs, and plans. Originates from product need.
- **Governance pipeline** — a lighter `Audit → Plan → PR` path, for changes whose
  source-of-truth is governance itself: agent files, skill bodies, the `CLAUDE.md` tree,
  `docs/workflow/`, hooks. Originates from audits or observed friction.

Every change order declares a `Pipeline:` field (`governance` or `codebase`) so hand-back
resumes the right upstream flow.

## The tracker contract

Sequence and Build coordinate through a tracker, selected by `backend:` in
`docs/workflow/tracker-config.yaml`:

- **`github`** — a GitHub Projects v2 board. IDC defines **eight custom fields**, read by
  name (the runtime resolves option IDs at call time):

  | Field | Type | Notes |
  |-------|------|-------|
  | `Status` | single-select | `Pending` · `Active` · `Blocked` · `Complete` (queue state; Sequence-owned) |
  | `ClaimState` | single-select | `Unclaimed` · `Claimed` · `Running` · `RetryQueued` · `Released` (runtime claim; Build-owned) |
  | `Wave` | single-select | execution wave |
  | `Phase` | single-select | phase tag |
  | `Track` | single-select | parallel track |
  | `Lane` | single-select | build lane (includes `(idle)`) |
  | `Domain` | single-select | subsystem/domain |
  | `Pillar trace key` | text | links a board item back to its pillar plan |

  A board item is a **candidate** for Build when `Status="Active"` AND
  `ClaimState="Unclaimed"`, with `Phase` matching the active matrix and `Pillar trace key`
  matching a matrix `pillar_id`. `/idc:init` provisions exactly these fields; the GitHub
  Projects backend needs the `project` OAuth scope.

- **`filesystem`** — a `TRACKER.md` file at the repo root. Zero external setup; good for
  getting started or repos without a GitHub Project.

The backend is hidden behind the `idc:idc-skill-tracker-adapter` dispatch skill, so roles
never call a backend directly and a `github ⇄ filesystem` flip is transparent.

## How commands, agents, and skills compose

Three layers, from operator-facing to reusable:

1. **Commands** (`commands/*.md`) are the slash entry points. `/idc:plan`, for example,
   tells the current session to operate as the Plan orchestrator by reading the matching
   agent file.
2. **Agents** (`agents/*.md`) are the orchestrators and the teammates they spawn. A role
   orchestrator (e.g. `idc-plan`) runs in the parent session and dispatches **teammates**
   — durable, separately-context'd Claude Code sessions created with `TeamCreate` +
   `Agent` (e.g. `idc-role-subphase-pillar-planner`) — never one-shot Task subagents,
   because teammates can hold context, coordinate, and be messaged mid-run.
3. **Skills** (`skills/*/SKILL.md`) are the reusable procedures agents compose: tracker
   operations, plan review, change-order shaping, drift evidence, and so on. The
   `codex-idc-*` skills are role adapters for the Codex runtime; `idc-workflow` is the
   top-level routing skill for non-pane environments.

`${CLAUDE_PLUGIN_ROOT}` resolves to the plugin's install path inside command, agent, and
skill bodies, so files reference each other portably (e.g.
`${CLAUDE_PLUGIN_ROOT}/agents/idc-build-runbook.md`). It is **not** a shell environment
variable — scripts receive the plugin root as an explicit argument instead.

## Required trace (the audit rule)

- Subphase plans must record `Upstream Master Plan Domain/Phase`.
- Pillar plans must record `Upstream Subphase` and `Tracker Trace Key`.
- Tracker edits must cite an existing polished pillar-derived unit.

These traces are what let any board item be walked back to the product requirement that
justified it — and what let Ripple compute the "highest affected layer" when something
drifts.
