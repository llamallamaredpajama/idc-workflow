# IDC v2 Overhaul — Consideration

- **Date:** 2026-06-12
- **Status:** Active (decided via operator grill-me interview; this file is the record of that interview)
- **Scope:** Full overhaul of the idc-workflow plugin — every command, agent, and skill
- **PRD impact:** YES — the plugin's user-facing function changes substantially. Operator approval was given live during the interview that produced this file; the v2 PRD rewrite is admitted work, not a pending gate.

---

## 1. What v2 does for the user (function first)

The operator's entire experience of the pipeline:

1. **`/idc:think`** — a free-thinking brainstorm/interview session. The operator talks; the session researches on demand; the output is a well-constructed **consideration file**: a function-first plan for what the code should do for the user and how it behaves. No gates, no teammates, no ceremony.
2. **`/idc:autorun`** — the one button. It traverses the whole pipe end-to-end: takes every consideration not yet planned, plans each one all the way to **goal-contract issues on the GitHub Project board**, heals board hygiene as it passes through, and activates build to implement eligible issues as they land. If there are no new considerations, it runs straight past planning and just fixes the board + builds what's eligible. It exits when nothing actionable remains (one-shot; `/loop /idc:autorun` for always-on).
3. **One gate, ever:** when planning (or ripple) determines the **PRD must change** — i.e., what the product does for its users changes — the affected issues land on the board **Blocked**, chained to a single approval issue containing a plain-terms summary ("here's what your app will do differently") plus the proposed PRD diff. The operator gets a **push notification** and can approve from the GitHub web UI on their phone. Approval flips the status; builders pick the items up on the next claim cycle. **Nothing else in the entire system asks for permission.**
4. Everything not touching the PRD flows through the pipeline fully autonomously: docs update themselves, plans review themselves via matrix analysis, PRs automerge when all green, drift heals itself through ripple.

The operator's mental model: *cast an idea into the stream at /idc:think; the stream carries it to merged, tested code; the only time the stream stops to ask is when the product's user-facing function is about to change.*

### Guardrails, not train tracks

v1 was built when agents were weaker; it hand-holds via standing reviewer/fixer/researcher roles, multi-pass plan reviews, claim-state machines, and per-edit approval gates. v2 trusts the model and keeps only the guardrails that catch real derailments:

- the **one PRD gate** (product function never changes without consent)
- **matrix deconfliction** (parallel work never collides)
- **real verification surfaces** (nothing merges that isn't actually green on genuine functional tests)
- **ripple** (docs and reality never silently diverge)
- **one-way flow + the glass wall** (planning reaches build only through GitHub issues; build reaches planning only through ripple)

---

## 2. Pipeline stages

### 2.1 Think — `/idc:think`

- Free-form brainstorming interview in the **main session, zero teammates**. Research questions go to throwaway subagents/workflows returning digests.
- Output: `docs/considerations/<date>-<slug>-considerations.md` — **function-first**: what the user gets, how it behaves, organized by domain where natural. Heavily PRD-shaped: it describes intended product function, not implementation tasks.
- No PRD pre-clearing at think time (deliberately rejected): thinking stays free; the gate lives in Plan only.
- Think writes only `docs/considerations/`. Unchanged from v1 in authority, radically lighter in machinery (the 4 think agents + 5 think skills are deleted).

### 2.2 Plan — `/idc:plan` (absorbs Sequence)

One planning run goes **consideration → issues on the board**. Phases, all inside a single session with dynamic fan-out, **zero teammates**:

1. **Absorb** — read the consideration, the canonical chain, and the live board state.
2. **Horizontal slice (domain experts)** — Workflow fan-out of throwaway read-only domain-expert subagents, one per *touched* domain. Domains are **config-seeded, planner-adjusted**: `WORKFLOW-config.yaml` declares the repo's standing domains (written at `/idc:init`, maintained by ripple); each run prunes to touched domains and may add ad-hoc ones. Each expert returns: what this consideration requires in its slice, what exists, the gap, risks, and goal-shaped work items.
3. **Draft the doc chain** — PRD diff (if function changes), arch-spec updates, master-plan section, subphase plans, pillar plans. Parallel drafting subagents write to disk and return digests; the orchestrator never absorbs full doc bodies. **The full five-layer chain survives as files** (PRD → arch spec → master implementation plan → subphase plans → pillar plans) for traceability — but only the PRD is gated; everything else is drafted and merged autonomously.
4. **Author the goal contracts** — each pillar is distilled into a complete 6-element contract (see §4), complexity-adaptive, using the `/fullauto-goal` authoring strategy. **Planning authors contracts; build only executes them.**
5. **Vertical slice (matrix/sequence)** — pairwise clash checks fan out (one subagent per pillar pair: shared surfaces? ordering? parallel-safe?); the orchestrator synthesizes the matrix and sequences the new issues **against the live board**: everything not In Progress gets re-waved globally. Re-sequencing happens ONLY here — nothing reorders the board without entering through planning's front door. In-progress issues are immutable.
6. **Validate + admit** — one mechanical schema check (every issue has: contract with runnable verification, declared file ownership, dependency links, trace to consideration/domain). Then create issues, set fields/blocked-by, mark PRD-dependent issues Blocked behind the gate issue, archive the consideration, open the planning PR (its body = the audit trail), automerge.

**Review reduction (decided):** matrix deconfliction + mechanical schema check are the ONLY plan review. The two-reviewer (custom + codex-adversarial) passes, fixer loops (≤3), governance trace audits, admissibility triage, and standalone audit files are all deleted. Content defects surface cheaply downstream: a builder hitting a contradiction files a ripple.

**PRD gate mechanics:** planning always runs to completion. The PRD diff rides in the planning PR but PRD-dependent issues land Blocked + gate issue + push notification. Non-PRD work from the same consideration flows through untouched.

### 2.3 Build — `/idc:build`

Mimics the pi-idc-collab 3-man triplet (implementer → reviewer → finisher) with the roles preserved and the session count collapsed:

- **Implementer** = one teammate per parallel-safe issue in the active wave, each in a pre-created worktree (lead pre-creates; never rely on `isolation: worktree` for teammates). Executes the issue's contract as a **/goal loop with the auto-goal discipline**: render-before-run, record-and-vary iteration, evidence-before-assertion, attempt ceiling, and the **no-punt rule** — incidental issues needed for success are fixed in the same loop, never deferred (this is the side-job-pileup killer). Single-issue waves: the orchestrator implements inline, no teammate.
- **Reviewer** = **not a session** — a fresh-context review fan-out per PR using the **merged review engine** (§5). Fresh subagents reading the diff cold give true adversarial independence token-efficiently; teammate-class reviewers are unnecessary.
- **Finisher** = the build orchestrator as **serial merge queue**: iterate on findings → reverify (real tests green) → **automerge when all green** → tracker close. One merger per wave means parallel PRs never race; merge conflicts get a deconflict pass on demand.
- **Wave close:** full test suite once → board cleanup of what it touched → promote next wave. Autowave is the default behavior, not a flag.
- **Phase close:** one review pass over the phase delta; findings filed as new board issues; phase close does NOT block on driving them to zero.
- Builders never edit canonical docs. Divergence (implementation vs pillar, or pillar vs upstream) → file ripple; only the affected issue pauses.
- Issues must be executable by **outside agents** (future overnight cloud domain-experts): everything needed lives in the issue body + plain GitHub API (claim = Status flip + claim comment naming the agent; `attempt:<n>` label for unattended observability).

### 2.4 Ripple — `/idc:ripple`

Lean autonomous doc-sync. Zero teammates.

- Trigger: any role (or operator) notices drift between docs and reality, or needs an upstream doc change.
- The run determines the highest affected layer and answers one question: **does user-facing product function change?**
  - **No** → update every affected doc down the chain in **one PR** (arch spec, master plan, subphases, pillars, CLAUDE.md tree, affected open issues — synchronized together), automerge. Fully autonomous.
  - **Yes** → same gate mechanism as planning: blocked operator-todo gate issue + plain-terms summary + PRD diff + push notification.
- **The PR description IS the change order** — drift evidence, layers changed, why PRD was/wasn't affected. The `docs/workflow/ripple/` change-order files, 4-value verdict taxonomy (NO_RIPPLE/MINOR_AUTONOMOUS/GATED/MAJOR_GATED), 4-condition autonomous test, change-order-author/reviewer/fixer teammates: all deleted.
- One-way flow preserved: ripple remains the only retrograde bridge from build back to planning docs.

### 2.5 Autorun — `/idc:autorun`

One-shot full-pipe drainer with two concurrent lanes:

- **Planning lane:** one plan-run teammate per unplanned consideration (parallel analysis/drafting), with **board admission serialized** through the autorun parent — one consideration sequences against the live board at a time.
- **Build lane:** activates as soon as eligible issues exist; keeps claiming waves as they appear, including ones unblocked mid-run from the operator's phone.
- Always traverses the pipe top-to-bottom: skip planning if no considerations → board hygiene/fix as it passes → build eligible work. Running autorun on a quiet repo just heals the board and drains stragglers.
- Exits with a report when nothing actionable remains (only PRD-gated items waiting on the operator). Loopable via `/loop` for standing operation.
- This satisfies the janitor need: no standing janitor, no separate sequence janitor mode. `/idc:doctor` stays read-only.

---

## 3. Canonical docs & governance

- **Doc chain kept, gates removed:** PRD / master architectural spec / master implementation plan / subphase plans / pillar plans all survive as files. Only the PRD is gated. All other docs are drafted, updated, and merged autonomously by plan and ripple.
- **One-way flow unchanged:** Think → Plan → Build, ripple as the only retrograde path, GitHub issues as the glass wall between planning and building.
- **WORKFLOW.md** is rewritten for v2: shorter, guardrail-framed, runtime-neutral (§7).
- Sequence is retired as a stage and as a command; sequencing is a phase inside plan; re-sequencing is global (all non-In-Progress issues) and only through plan.

## 4. The issue format (glass-wall contract)

The issue body is a **distilled, self-sufficient goal contract** — a builder works cold from the issue alone:

```
GOAL: <single observable end-state>
VERIFICATION SURFACE: <exact runnable commands + what passing looks like;
  failing-test-first when target behavior is untested — real functional tests,
  never placeholder/shallow suites>
CONSTRAINTS: <what must not regress; no-punt rule>
BOUNDARIES: touch <owned files/surfaces — the deconfliction output> / off-limits <…>
ITERATION POLICY: record-and-vary
BLOCKED-STOP: <halt conditions + attempt ceiling>
ASSUMPTIONS: <inferred details, vetoable>
---
Dependencies: native blocked-by links
Trace: pillar file · consideration · PRD section (deep context on demand)
```

Board schema: **4 custom fields** — Status (Blocked/Todo/In Progress/Done), Wave, Phase, Domain — plus native blocked-by, `attempt:<n>` label, claim comments. ClaimState, Lane, Track, bookend labels, and the 5-state claim machine are deleted.

## 5. The merged review engine

Combine ALL features of `code-review-custom` with the pi-idc-collab review agent into one engine, shipped **in the plugin** so consuming repos and external agents get it:

- Parallel specialist reviewers (~8) across the 13 dimensions (protocol, contract drift, error handling, resource mgmt, security, stack gotchas, unit-test rigor, integration-test gaps, dependency/bloat, complexity budget, git-history narrative, stale docs, simplification).
- Coordinator: cross-reviewer dedup by fingerprint, confidence scoring (≥0.8 floor), severity ladder (blocker/major/minor/nit), fail-closed verdicts (PASS / PASS-WITH-NITS / FAIL / FAIL-BLOCKED), structured JSON + human report.
- Findings include evidence + failure-mode ("attack") + unblock condition.
- Used at: per-PR build review (iterate → reverify → automerge on PASS) and phase-close delta review. Runs as fresh-context subagent fan-out in every runtime.
- **Test genuineness is a review dimension:** verification surfaces must be real functional tests proving behavior; shallow/shortcut AI test suites are a FAIL finding.

## 6. Runtime model — one core, thin adapters

The process is written against **three abstract primitives**:

| Primitive | Claude Code | Codex CLI (researched 2026-06-12, v0.130.0) |
|---|---|---|
| **Durable worker** (implementers, autorun lanes) | Claude Teams teammate (cmux) | Named thread driven via `codex app-server` (JSON-RPC `thread/start`, `turn/start`, `turn/steer`; companion-plugin broker is working prior art) or `codex exec resume <thread-name>` loops |
| **Bounded fan-out** (domain experts, drafters, clash pairs, reviewers) | Workflow tool / Task subagents | Native `spawn_agent`/`wait_agent` (≤6 concurrent, depth 2, stable) or `codex exec --ephemeral --json` process fan-out (escapes the cap; deterministic) |
| **Goal loop** (issue execution) | `/goal` + auto-goal discipline | Same contract executed inline (contract is harness-neutral) |

- Codex caveats designed around: threads are passive between turns (parent drives); no peer messaging (route via parent or filesystem mailboxes/scratch packets); no worktree isolation param (pre-create worktrees, `--cd`).
- Fallback ladder everywhere: no teams environment → durable-worker work runs serially in-session. Review fan-out is subagents in every runtime (fresh context = adversarial independence; also token-optimal).
- The five `codex-idc-*` parallel skill trees are deleted, replaced by **one Codex adapter** (primitives map + invocation mechanics) over the shared process docs. One copy of the truth; mirrors cannot drift.

### 6.1 Model routing (token optimization)

A tier-symbolic model table lives in `WORKFLOW-config.yaml` (`reasoning` / `standard` / `utility`, mapped per runtime); the runtime adapters resolve tiers to concrete models at spawn time; ripple maintains the table when models change. No hardcoded model IDs in process docs.

**Claude mapping and assignments:**

| Tier | Model | Used for |
|---|---|---|
| `reasoning` | Latest **Fable**, maximum thinking | All planning cognition: domain-expert synthesis, goal-contract authoring, clash/matrix judgment, sequencing decisions; ripple layer-impact analysis + PRD diffs; the review **coordinator/verdict** and all judgment review dimensions (correctness, security, error handling, contract drift, test rigor, complexity, integration gaps); merge deconfliction |
| `standard` | Latest **Opus**, extra-high effort | Think/grill-me interviews; build **implementers** (goal loops); finisher/orchestrator duties; the autorun parent |
| `utility` | Latest **Sonnet** | The execute-never-decide lane: web research + source digestion, repo reconnaissance sweeps, templated emission from up-tier-authored content (issue bodies from contracts, matrix YAML siblings, PR descriptions, doc formatting), board mechanics + hygiene classification, the mechanical schema check, and the inventory-style review dimensions (dependency/bloat, stale-docs sweep, git-history narrative) under the Fable coordinator, which may re-run any dimension up-tier on suspicion |

**The utility-tier rule:** Sonnet executes briefs authored by a higher tier and produces outputs that are cheaply verifiable (schema check, diff, tests). It never authors contracts, never makes judgment calls, never issues verdicts.

**Codex carve-out (operator-directed):** when Codex is the runtime, **no tiering** — highest available Codex model at highest reasoning effort for everything.

## 7. Teammate/concurrency budget (consolidation targets)

- Think: 0 teammates (was 3).
- Plan: 0 teammates inside a run (was up to ~7). Under autorun: 1 teammate per consideration being planned.
- Build: 1 implementer teammate per parallel issue (was ~3 roles/lane + 4 standing roles). Orchestrator is the finisher.
- Ripple: 0 teammates (was up to ~5).
- Deleted standing roles: bootstrap-researcher, plan-reviewers, fixer, subphase-pillar-planner, ripple-orchestrator, change-order-author, integration-verifier, phase-close-adversarial-reviewer, wave-blocker-diagnostic, think trio, merge-deconflictor-as-role (deconfliction becomes an on-demand pass), writer.

## 8. What gets deleted vs kept (inventory direction)

- **Commands:** keep `init`, `doctor`, `think`, `plan`, `build`, `ripple`, `autorun`. Retire `sequence`.
- **Agents:** ~23 → roughly 5–7 (per-phase orchestrator playbooks + implementer role + maybe the review coordinator). All idc-role-* standing teammates deleted except the implementer.
- **Skills:** ~38 → roughly 10–12: tracker adapter (+ github/filesystem backends), goal-contract authoring shape, matrix/clash analysis, schema check, merged review engine, ripple doc-sync, consideration schema, runtime adapters (claude, codex), operator-gate/notify helper.
- Bookend/ClaimState machinery, plan-review suite (review, review-base, adversarial-review, patch-from-findings, sibling-precedent, admissibility, governance-trace-audit, canonical-admission-audit), think skill suite, change-order suite: deleted.
- `/idc:init` updates: provision the 4-field board; write domain config into WORKFLOW-config.yaml from codebase analysis; v2 WORKFLOW.md scaffold; install receipts (folded lifecycle scope) enabling clean uninstall/upgrade of plugin-managed files in consuming repos.

## 9. Migration

- **Clean-slate v2 on a branch in this repo.** Old machinery deleted outright (git history is the archive); no legacy namespace, no incremental coexistence.
- **This file is the v2 consideration.** v2 itself is built in v2's process shape, hand-driven: domain analysis via fan-out → goal-contract work items → auto-goal implementation loops → merged-review on PRs → automerge when green.
- **In-flight plugin-lifecycle Phase 1 issues (install receipts, uninstall): parked, not built.** Their scope folds into v2 (§8 init/receipts) — upgrading existing IDC repos (e.g. pi-idc-collab with old-ceremony WORKFLOW.md) to v2 requires exactly that machinery. Existing pillar content gets re-run through v2 planning afterward, emitting fresh contract-shaped issues.
- Consuming repos migrate via `/idc:init` re-scaffold (v2 WORKFLOW.md + board schema migration).

## 10. Decision log (operator interview, 2026-06-12)

| # | Decision |
|---|---|
| 1 | Doc chain: keep all five layers as files; remove all gates except PRD |
| 2 | Sequence folds into plan; re-sequencing is global, only via plan; In Progress immutable; no standalone re-sequencer |
| 3 | Think stays free-thinking; no PRD pre-clearing; the engineer-gate in plan is the one and only gate, plain-terms, PRD-only |
| 4 | Gate is tracker-native: PRD-touching issues Blocked + gate issue + push notification; approve from GitHub web UI; everything else flows |
| 5 | Domains: config-seeded in WORKFLOW-config.yaml, planner-adjusted per run |
| 6 | Plan review = matrix deconfliction + mechanical schema check only |
| 7 | Plan runs use zero teammates; Workflow/subagent fan-out for experts, drafting, clash pairs |
| 8 | Issue body = distilled self-sufficient 6-element goal contract; pillar file linked for depth |
| 9 | Planning authors contracts (fullauto-goal strategy); build executes (/goal + no-punt); triplet roles kept, mapped to 1 implementer teammate + review fan-out + orchestrator-finisher; custom review → iterate → reverify → automerge when green; real functional tests mandatory |
| 10 | Ripple = lean autonomous doc-sync; one PR, automerge; PR-as-change-order; PRD-only gate; verdict taxonomy deleted |
| 11 | Autorun = one-shot two-lane drainer; serialized board admission; loopable |
| 12 | Migration = clean-slate v2; this interview is the consideration; lifecycle issues parked, scope folded into v2 |
| 13 | Board = 4 fields + blocked-by + attempt label + claim comments; must support outside/cloud agents working issues cold |
| 14 | Janitor = autorun's full-pipe traversal (auto --fix in passing); doctor stays read-only |
| 15 | Codex mirror = shared runtime-neutral core + one thin adapter per runtime (threads via app-server broker; spawn_agent/exec fan-out) |
| 16 | Model routing: Fable + max thinking for planning and judgment review + review coordinator; Opus + extra-high effort for think/implementing/finishing; Sonnet utility lane (execute-never-decide, incl. inventory review dimensions under the Fable coordinator); tier table in WORKFLOW-config.yaml resolved by runtime adapters. Codex runtime is untiered: highest model + highest effort for everything |

## 11. Assumptions flagged for veto

- Merged review engine ships inside the plugin (not as a user-level skill) so consuming repos and external/cloud agents can use it.
- Board schema details (4 fields, claim-comment protocol, attempt label) were delegated to the agent's judgment, chosen for plain-GitHub-API compatibility with outside agents.
- Command surface: `sequence` retired; all other commands keep their names with v2 semantics.
- Pillar/wave/phase vocabulary is retained.
- Worktree mandate (every orchestrator/implementer off-main in its own worktree) is retained from v1.
- Planning PRs and ripple PRs automerge without human review (the PRD gate is the only human touchpoint).
