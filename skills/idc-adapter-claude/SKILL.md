---
name: idc-adapter-claude
description: 'Use when an IDC role running under Claude Code must turn an abstract runtime primitive (durable worker / bounded fan-out / goal loop) into concrete Claude mechanics, or resolve a model tier to a concrete model.'
---
# idc-adapter-claude

The Claude Code runtime adapter. IDC process docs are written against three abstract
primitives (`WORKFLOW.md §5`); this skill maps each to concrete Claude Code mechanics and
resolves the tier-symbolic model table (`WORKFLOW.md §6`) to concrete models at spawn time.
There is exactly one adapter per runtime — this is the only place Claude mechanics live, so
the process docs stay runtime-neutral and cannot drift per-runtime.

## Primitive → mechanic map

| Primitive | Claude Code mechanic | Fallback |
|---|---|---|
| **Durable worker** (Build implementer, autorun lane, **recirc consultant + Plan worker** of the larger loop) | A Claude Teams teammate in its own cmux pane: the lead pre-creates a worktree, `TeamCreate`s, then spawns the teammate with `Agent({team_name, …})` pointed at that worktree (NOT the `isolation:"worktree"` param, which silently runs on `main`); coordinate via `SendMessage`; tear down with `TeamDelete`. | No durable-worker runtime → degrade to a **Task subagent** for a single bounded unit (the proven #393 recirc-as-subagent path) or an **inline serial pass** in the main session, one unit at a time. The loop still closes; only the realization differs. |
| **Bounded fan-out** (domain experts, drafters, clash pairs, reviewers) | The `Workflow` tool for deterministic fan-out/pipeline, or parallel `Agent` (Task) subagents for independent reads. Review fan-out is always **fresh-context subagents** (cold read = adversarial independence, token-optimal). | Subagents are available in every Claude environment; no fallback needed. |
| **Goal loop** (issue execution) | The native `/goal` loop with auto-goal discipline: render-before-run, record-and-vary iteration, evidence-before-assertion, the attempt ceiling, and the no-punt rule. The issue body IS the contract. | — |

### The larger loop's workers (recirc consultant + Plan)

Build's larger loop (`idc:idc-build` Phase 1b) spawns a **recirc consultant per recirc event** and a
**batched Plan worker** as **durable workers** — realized exactly like the Build triplet by the map
above: teammate (Teams) → resident (pi) → thread (Codex) → **Task subagent / inline serial pass** where
no durable-worker runtime exists, so the loop closes in **every** runtime; only the realization differs.
Both roles are **zero-teammate**: a teammate **cannot spawn its own teammates**, so each does its
internal fan-out through the **bounded-fan-out** primitive — the `Workflow` tool (deterministic
`pipeline()`/`parallel()`, "ultracode") or parallel Task subagents under Claude, app-server threads
under Codex, the resident pool under pi — **never** by spawning teammates. So a Plan worker realized as
a teammate still fans its domain experts / clash pairs out as Workflow/subagents, and a recirc
consultant fans its layer-impact reads out the same way.

### Durable-worker rules (load-bearing)

- **Never edit the same file from two workers at once.** One unit per worker.
- **Pre-create worktrees** (`git worktree add .claude/worktrees/<name> -b worktree-<name>`)
  and verify with `git worktree list` before any worker writes; the teammate pins git to
  the worktree (`git -C <path>` or `cd` first).
- The Build orchestrator is the **single merge-queue** (finisher); parallel PRs never race.

## Two-level fan-out + worktree topology

The durable-worker and bounded-fan-out primitives **compose** into a **two-level fan-out**: the
durable worker is a **sous-chef** that owns an area end-to-end (outer level — one Teams teammate per
matrix-disjoint area), and inside that area it runs **bounded fan-out to line cooks** (inner level),
each cook on a **disjoint** sub-surface so two cooks can never race on one file
(`idc:idc-implementer` / `idc:idc-finisher`).

- **Outer level (sous-chef).** A Claude Teams teammate in its own pre-created worktree, exactly as
  the durable-worker row above — never the Agent-tool `isolation:"worktree"` param (it silently
  runs on `main`).
- **Inner level (line cooks).** The **`Workflow` tool** drives the cooks deterministically — a
  `pipeline()` (implement → review → finish) **per cook** or a `parallel()` across cooks, **one cook
  per `parallel()` thunk / per disjoint-surface item** (cooks parallelise across *surfaces*, not
  across the pipeline's implement→review→finish *stages*), with **`isolation:'worktree'` per cook**.
  This is the Workflow tool's *own* worktree isolation (a working code path), distinct from the
  broken Agent-tool param above — so each cook gets an isolated worktree without the lead
  pre-creating it.

**Worktree topology — cook → area-staging → merge (worktree-per-cook).** Each line cook runs in its
**own worktree** (worktree-per-cook); the cooks' disjoint sub-surfaces converge onto the
**area-staging** branch the sous-chef owns; the sous-chef **merges** that staging branch (the
finisher merges into the integration branch as the single Build orchestrator under the serialized
merge lease — Teams' A2 row, `idc:idc-finisher`). Fan-out widens *who builds*, never *who judges*:
the cooks build, an **independent** review issues the verdict, and only then does the finisher merge.

## Model-tier resolution

Read `WORKFLOW-config.yaml::model_routing`. For a spawn at tier `<tier>`, resolve
`model_routing.<tier>.claude.model` and apply its `thinking` / `effort` hint. Process docs
name only the tier; this skill resolves the concrete model. The Recirculator maintains the table when
models change — never hardcode a model id in a command, agent, or non-adapter skill.
`WORKFLOW-config.yaml` also carries the `gating:` requirements-gate toggle (`gating.prd` /
`gating.trd`), but that is read by the gate predicate (`scripts/idc_recirculator_layers.py`) for
Plan and the Recirculator — not by tier resolution.

| Tier | Resolves to (per config) | Applied to |
|---|---|---|
| `reasoning` | `model_routing.reasoning.claude` | planning cognition; review coordinator/verdict + judgment dimensions; recirculation analysis + PRD diffs; clash/matrix + sequencing; merge deconfliction |
| `standard` | `model_routing.standard.claude` | think/interview; build implementers; finisher/orchestrator; autorun parent |
| `utility` | `model_routing.utility.claude` | execute-never-decide: research digestion, recon, templated emission, board mechanics, the schema check, inventory review dimensions |

## Authority boundaries

- Maps primitives and resolves tiers only — never authors contracts, makes judgment calls,
  or issues verdicts.
- Never mutates the tracker, canonical docs, or `WORKFLOW-config.yaml` (the Recirculator owns the
  model table).
