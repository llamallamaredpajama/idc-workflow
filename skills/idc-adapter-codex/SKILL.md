---
name: idc-adapter-codex
description: 'Use when an IDC role running under the Codex CLI must turn an abstract runtime primitive (durable worker / bounded fan-out / goal loop) into concrete Codex mechanics. Codex is untiered — highest model + highest effort for everything.'
---
# idc-adapter-codex

The Codex CLI runtime adapter (researched against Codex v0.130.0, 2026-06-12). IDC process
docs are written against three abstract primitives (`WORKFLOW.md §5`); this skill maps each
to concrete Codex mechanics. There is exactly one Codex adapter — it replaces v1's five
per-command Codex skill trees, so there is one copy of the truth and the mirror cannot
drift.

## Primitive → mechanic map

| Primitive | Codex mechanic | Fallback |
|---|---|---|
| **Durable worker** (Build implementer, autorun lane) | A named thread driven via `codex app-server` (JSON-RPC `thread/start`, `turn/start`, `turn/steer`), or a `codex exec resume <thread-name>` loop. Threads are **passive between turns** — the parent drives every turn. | No durable-worker environment → run the work **serially in the main session**. |
| **Bounded fan-out** (domain experts, drafters, clash pairs, reviewers) | Native `spawn_agent` / `wait_agent` (≤ 6 concurrent, depth 2, stable), or `codex exec --ephemeral --json` process fan-out, which escapes the concurrency cap and is deterministic. Review fan-out is fresh `--ephemeral` processes (cold read = adversarial independence). | — |
| **Goal loop** (issue execution) | The same 6-element contract executed inline — the contract is harness-neutral; the goal-loop discipline (render-before-run, record-and-vary, evidence-before-assertion, attempt ceiling, no-punt) is followed as instruction text. | — |

### Codex caveats designed around

- **No peer messaging** between threads — route coordination through the parent or through
  filesystem mailboxes / scratch packets.
- **No worktree-isolation param** — pre-create worktrees and launch with `--cd <worktree>`.
- Threads are passive between turns — the parent is the only driver; there is no autonomous
  teammate loop.

## Model selection — untiered

The Codex runtime **ignores the tier table**. Use the **highest available Codex model at the
highest reasoning effort for every role** (operator-directed carve-out, `WORKFLOW.md §6`).
Do not read `model_routing` tiers; do not down-tier any lane.

## Authority boundaries

- Maps primitives to Codex mechanics only — never authors contracts, makes judgment calls,
  or issues verdicts.
- Never mutates the tracker or canonical docs.
