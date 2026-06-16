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
| **Durable worker** (Build implementer, autorun lane) | A Claude Teams teammate in its own cmux pane: the lead pre-creates a worktree, `TeamCreate`s, then spawns the teammate with `Agent({team_name, …})` pointed at that worktree (NOT the `isolation:"worktree"` param, which silently runs on `main`); coordinate via `SendMessage`; tear down with `TeamDelete`. | No teams environment → run the work **serially in the main session**, one unit at a time. |
| **Bounded fan-out** (domain experts, drafters, clash pairs, reviewers) | The `Workflow` tool for deterministic fan-out/pipeline, or parallel `Agent` (Task) subagents for independent reads. Review fan-out is always **fresh-context subagents** (cold read = adversarial independence, token-optimal). | Subagents are available in every Claude environment; no fallback needed. |
| **Goal loop** (issue execution) | The native `/goal` loop with auto-goal discipline: render-before-run, record-and-vary iteration, evidence-before-assertion, the attempt ceiling, and the no-punt rule. The issue body IS the contract. | — |

### Durable-worker rules (load-bearing)

- **Never edit the same file from two workers at once.** One unit per worker.
- **Pre-create worktrees** (`git worktree add .claude/worktrees/<name> -b worktree-<name>`)
  and verify with `git worktree list` before any worker writes; the teammate pins git to
  the worktree (`git -C <path>` or `cd` first).
- The Build orchestrator is the **single merge-queue** (finisher); parallel PRs never race.

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
