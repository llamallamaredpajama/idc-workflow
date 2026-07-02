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

## Two-level fan-out + worktree topology

The durable-worker and bounded-fan-out primitives **compose** into a **two-level fan-out**: the
durable worker is a **sous-chef** that owns an area end-to-end (outer level — one app-server thread
per matrix-disjoint area), and inside that area it runs **bounded fan-out to line cooks** (inner
level), each cook on a **disjoint** sub-surface so two cooks can never race on one file
(`idc:idc-implementer` / `idc:idc-finisher`).

- **Outer level (sous-chef).** A named Codex thread driven via `codex app-server`, launched with
  `--cd <worktree>` — Codex has **no worktree-isolation param**, so the parent pre-creates the
  worktree.
- **Inner level (line cooks).** Native `spawn_agent` / `wait_agent` (≤ 6 concurrent, depth 2), or
  `codex exec --ephemeral --json` process fan-out which escapes the concurrency cap — **one cook per
  spawned agent / `--ephemeral` process**. The two paths isolate differently: `spawn_agent`
  sub-agents **inherit the parent thread's worktree** (there is no per-agent `--cd`), so the
  **worktree-per-cook** topology is realized by the **`--ephemeral` process** path, each process
  `--cd`'d into its own pre-created worktree. Use the process path when cooks must own distinct
  worktrees; `spawn_agent` cooks share the thread's surface and must therefore stay on disjoint paths
  within it.

**Worktree topology — cook → area-staging → merge (worktree-per-cook).** Each `--ephemeral`-process
line cook runs in its **own worktree** (worktree-per-cook), `--cd`'d in (the `spawn_agent` path shares
the thread's worktree, so worktree-per-cook uses the process path); the cooks' disjoint sub-surfaces
converge onto the **area-staging** branch the sous-chef owns; the sous-chef **merges** that staging
branch (the app-server serially merges finisher threads — Codex's A2 row). Fan-out widens *who
builds*, never *who judges*: the cooks build, an **independent** `--ephemeral` review issues the
verdict, and only then does the finisher merge.

## Model selection — untiered

The Codex runtime **ignores the tier table**. Use the **highest available Codex model at the
highest reasoning effort for every role** (operator-directed carve-out, `WORKFLOW.md §6`).
Do not read `model_routing` tiers; do not down-tier any lane.

The model-escalation ladder (`WORKFLOW-config.yaml::model_routing` — deterministic → Sonnet →
Opus → Fable → human) does not change this. Codex's parity with the ladder is keeping this
untiered posture **explicit and documented identically** here, not adopting the ladder or reading
`model_routing.overrides` — parity is the contract expressed the same way, never Codex's model
policy changing to match.

## Authority boundaries

- Maps primitives to Codex mechanics only — never authors contracts, makes judgment calls,
  or issues verdicts.
- Never mutates the tracker or canonical docs.
