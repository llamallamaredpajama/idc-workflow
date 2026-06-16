# Master Architectural Spec — IDC Workflow Plugin (v3)

**Upstream trace:** this spec realizes `docs/prd/prd.md` (v2) and is derived from
`docs/considerations/2026-06-12-idc-v2-overhaul-considerations.md` (the authoritative v2
spec — operator interview, 16 decisions). Where this doc and the consideration conflict,
the consideration wins.

> This is the architecture of the **plugin itself** — how IDC v3 is built and wired. It is
> distinct from `templates/WORKFLOW.md`, which is the per-project governance *contract* the
> plugin installs into consuming repos. This spec governs the plugin; WORKFLOW.md governs a
> governed repo.

## 1. Scope

The IDC Workflow plugin packages **IDC** — the Iterative Development Cycle — as an
installable [Claude Code](https://claude.com/claude-code) plugin: a guardrail-framed,
tracker-driven, goal-contract pipeline that carries software work from a raw idea to
merged, reviewed code. This spec fixes the plugin's component architecture, naming
convention, the tracker substrate, the one gate, the runtime model, and the inventory
invariants. Per-command/skill behaviour is authored in the build phases; this spec is the
contract those phases hold to.

## 2. What IDC v3 is (function)

The operator casts an idea into the stream at `/idc:think`; the stream carries it to
merged, tested code; it stops to ask exactly once — at the **end of Think**, when the operator
admits the idea's requirements (PRD + TRD) by merging the Think PR.

- **Pipeline:** `Think → Plan → Build`, `Recirculator` the only retrograde path, `Autorun` the
  one-shot drainer. Nine commands total: `init`, `doctor`, `think`, `plan`, `build`,
  `recirculate`, `autorun`, `update`, `uninstall`.
- **Five guardrails, nothing else:** the one requirements gate at the end of Think; matrix
  deconfliction; real verification surfaces; recirculator drift-healing; one-way flow through
  the glass wall. The model is trusted; there are no standing reviewer/fixer/researcher roles,
  multi-pass plan reviews, claim-state machine, or per-edit gates.

## 3. Component architecture & naming convention

### 3.1 Composition

- `commands/*.md` — slash entry points (auto-discovered; namespaced `idc:<name>` by the
  harness at load time).
- `agents/*.md` — orchestrator playbooks + the one durable-worker role + the review
  coordinator (invoked as subagents or read as trampolines).
- `skills/<name>/SKILL.md` — reusable procedures (invoked via the Skill tool as
  `idc:<name>`).
- `${CLAUDE_PLUGIN_ROOT}` resolves to the install path inside command/agent/skill bodies
  (text-substituted, **not** a shell env var). `plugin.json` carries no explicit component
  lists — discovery is by directory.

### 3.2 The v3 namespace (flat `idc-*`)

All agents and skills use a flat `idc-<thing>` name (no `idc-skill-` / `idc-role-` /
`codex-idc-` prefixes — those were v1). Frontmatter `name:` is **bare** (the harness adds
the `idc:` namespace). Body references to a sibling component are written `idc:<name>` and
MUST resolve to a real `skills/<name>/`, `agents/<name>.md`, or `commands/<name>.md` — the
reference-integrity linter (`scripts/lint-references.sh`) enforces this.

**Agents (≤ 8):**

| Agent | Role |
|---|---|
| `idc-plan` | Plan orchestrator playbook — pure decomposition (domain dispatch → contracts → matrix → admit; no requirements authoring). |
| `idc-build` | Build orchestrator + finisher/merge-queue. |
| `idc-implementer` | The one durable-worker role — executes an issue contract as a goal loop. |
| `idc-review-coordinator` | Merged review engine coordinator (dedup, confidence, verdict). |
| `idc-recirculator` | Recirculator orchestrator playbook (doc-sync; a requirements change reuses the Think-PR gate). |
| `idc-autorun` | Autorun two-lane drainer playbook. |

(Think has no standing agent — `commands/think.md` runs it inline, free-form with zero teammates;
it authors the PRD+TRD draft and fires the one gate via the Think PR.)

**Skills (≤ 14, target ~12):**

| Skill | Purpose |
|---|---|
| `idc-adapter-claude` | Claude runtime adapter — primitives → Claude mechanics + tier→model resolution. |
| `idc-adapter-codex` | Codex runtime adapter — primitives → Codex mechanics (untiered). |
| `idc-tracker-adapter` | Backend dispatch (reads `tracker-config.yaml::backend`). |
| `idc-tracker-github` | GitHub Projects v2 backend (5 fields, blocked-by, claim comments, attempt label). |
| `idc-tracker-filesystem` | Filesystem backend (`TRACKER.md`; zero setup; the sandbox test substrate). |
| `idc-gate-issue` | Requirements gate-issue helper (the Think PR; sync/async approval) + push notification. |
| `idc-consideration-schema` | Function-first consideration file schema (Think output). |
| `idc-goal-contract` | 6-element goal-contract authoring shape (Plan authors; Build executes). |
| `idc-matrix-analysis` | Pairwise clash check + matrix synthesis + wave sequencing. |
| `idc-schema-check` | Mechanical issue-body schema check (contract + ownership + deps + trace). |
| `idc-review-engine` | Merged 13-dimension review engine (specialist fan-out brief + dimensions). |
| `idc-recirculator-sync` | Recirculator doc-sync: highest-affected-layer + downstream synchronization set. |

### 3.3 Runtime-neutral core + thin adapters

Process docs (commands, agents, the non-runtime skills) are written against the three
abstract primitives only (durable worker / bounded fan-out / goal loop; `WORKFLOW.md §5`).
Exactly **one** adapter per runtime (`idc-adapter-claude`, `idc-adapter-codex`) maps the
primitives to concrete mechanics and resolves model tiers. There is no per-runtime process
tree — one copy of the truth; mirrors cannot drift. (v1's five `codex-idc-*` skill trees
are deleted.)

## 4. Tracker substrate

The contract is fixed in `templates/WORKFLOW.md §3`; the plugin implements it as a
dispatch skill + two backends.

- **Dispatch.** `idc-tracker-adapter` resolves `docs/workflow/tracker-config.yaml::backend`
  and routes to `idc-tracker-github` or `idc-tracker-filesystem`. Unknown backend → halt
  (`unknown_backend`), never a silent default.
- **Schema.** Five fields — `Status` (`Blocked|Todo|In Progress|Done`), `Stage`
  (`Consideration|Planning|Buildable`; additive), `Wave`, `Phase`, `Domain` — plus native
  blocked-by, an `attempt:<n>` label, and claim comments. No
  ClaimState/Lane/Track/Pillar-trace-key field, no bookend ceremony.
- **Six operations.** `createTicket`, `setField`, `link`, `move`, `query`, `comment`. A
  seventh is a contract change requiring a recirculation.
- **The issue is the contract.** Each issue body is a self-sufficient 6-element goal
  contract + Dependencies + Trace (`WORKFLOW.md §3.2`), authored by Plan via
  `idc-goal-contract`, executable cold by an outside agent.
- **Claim protocol.** Claim = `Status → In Progress` + a claim comment naming the agent.
  No lock primitive; a single merge-queue (the Build orchestrator) serializes merges so
  parallel PRs never race.

## 5. The one gate (requirements admission, at the end of Think)

The single human checkpoint fires at the **end of Think**. Think crystallizes an idea into a
**PRD + TRD** draft and opens a **Think PR** carrying it, plus one gate issue (`idc-gate-issue`)
with a plain-terms summary + the PRD/TRD diff; the operator is push-notified and approves from the
GitHub web UI. Approval is **sync or async**, and the PRD/TRD stay **draft until merge** — **merge
= approval = admission**. The PRD always gates (`gating.prd`); the TRD (the `spec` layer) gates
when `gating.trd: on`. The Recirculator **reuses this same gate** for any backflow that needs a
requirements change. This is the **only** human checkpoint; Plan, Build, and non-gated
recirculations automerge when green.

## 6. Runtime primitives & model routing

- **Primitives** (`WORKFLOW.md §5`): durable worker, bounded fan-out, goal loop. Concurrency
  budget: Think/Plan/Recirculator = 0 durable workers; Build = 1 per parallel-safe issue (serial
  in-session fallback); review = bounded fan-out everywhere.
- **Model routing** (`WORKFLOW.md §6`): tier-symbolic (`reasoning`/`standard`/`utility`)
  resolved by the runtime adapter from `WORKFLOW-config.yaml::model_routing`; no hardcoded
  model IDs in process docs. Codex runtime untiered.

## 7. Inventory invariants & fitness fences

These are load-bearing and verified by the rebuild's verification surface:

- `commands/` = exactly the nine v3 commands (`init`, `doctor`, `think`, `plan`, `build`,
  `recirculate`, `autorun`, `update`, `uninstall`; no `sequence`/`upgrade`).
- `agents/` ≤ 8 files; `skills/` ≤ 14 directories.
- No v1 vocabulary (`ClaimState`, `bookend-`, `idc-role-`, `codex-idc-`,
  `MINOR_AUTONOMOUS`, `MAJOR_GATED`, `Pillar trace key`) in `commands/ agents/ skills/
  templates/ README.md llms.txt`.
- `scripts/lint-references.sh` exits 0 (genuine cross-reference integrity over the v3
  namespace).
- The merged review engine ships **inside the plugin** (`idc-review-engine` +
  `idc-review-coordinator`), so consuming repos and outside/cloud agents get it.
- `plugin.json` version `3.0.0` at release.
