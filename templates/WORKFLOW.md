# WORKFLOW.md — {{PROJECT_NAME}} IDC governance contract

> **This file is a hard contract.** Its existence marks the repo as IDC-governed, and its
> section numbers are **stable** so the IDC roles and skills can cite rules by anchor
> (e.g. "WORKFLOW.md §3.1"). Keep the numbering stable when you edit.

IDC carries an idea from a raw thought to merged, tested code. It is built on
**guardrails, not train tracks**: the model is trusted to do the work; the process
intervenes only where a real derailment would otherwise ship. There are exactly five
guardrails — the one PRD gate (§2), matrix deconfliction (§4.2), real verification
surfaces (§4.3), ripple drift-healing (§4.4), and one-way flow through the glass wall
(§1.2). Everything else flows autonomously.

## 1. Canonical chain & flow

### 1.1 The pipeline

`Think → Plan → Build`, with `Ripple` as the only retrograde path and `Autorun` as the
one-shot drainer that traverses the whole pipe. Slash surfaces: `/idc:think`,
`/idc:plan`, `/idc:build`, `/idc:ripple`, `/idc:autorun`, plus `/idc:init` (per-project
scaffold) and `/idc:doctor` (read-only health check).

| Stage | Slash surface | Surface it writes |
|---|---|---|
| Think | `/idc:think` | `docs/considerations/` (pre-canonical) |
| Plan | `/idc:plan` | `docs/prd/`, `docs/specs/`, `docs/plans/` (master + subphases + pillars), pillar matrices, and tracker issues |
| Build | `/idc:build` | source surfaces (per issue `BOUNDARIES`), tests, review reports, and tracker status |
| Ripple | `/idc:ripple` | every affected canonical doc, synchronized in one PR |

### 1.2 One-way flow + the glass wall

Planning reaches Build **only** through tracker issues (the glass wall). Build reaches
planning **only** through Ripple. No role edits a layer above it; a lower role that finds
a higher layer wrong files a Ripple and pauses only the affected issue.

### 1.3 The five-layer doc chain

PRD → master architectural spec → master implementation plan → subphase plans → pillar
plans. All five survive as files for traceability. **Only the PRD is gated (§2); every
other doc is drafted, updated, and merged autonomously** by Plan and Ripple.

## 2. The one gate — PRD (user-facing function)

The single human checkpoint in the entire system. When Plan or Ripple determines that
the **PRD must change** — i.e. what the product does for its users changes — the affected
tracker issues land **Blocked**, chained by native blocked-by to one **gate issue** that
carries a plain-terms summary ("here's what your app will do differently") plus the
proposed PRD diff. The operator receives a push notification and approves from the GitHub
web UI; approval unblocks the chained issues, which builders pick up on the next claim
cycle. **Nothing else in the system asks for permission.** Non-PRD work from the same run
flows through untouched.

## 3. Tracker substrate

The tracker is the glass wall (§1.2). Its backend is selected by `backend:` in
`docs/workflow/tracker-config.yaml` and hidden behind the configured tracker adapter —
roles never hard-code backend semantics. Two backends ship: `github` (a GitHub Projects
v2 board; first-class) and `filesystem` (a root `TRACKER.md`; zero external setup).

### 3.1 Board schema — five fields

| Field | Values | Meaning |
|---|---|---|
| `Status` | `Blocked` / `Todo` / `In Progress` / `Done` | Where the issue sits in the queue. |
| `Stage` | `Consideration` / `Planning` / `Buildable` | Pipeline column: upstream pointer items ride `Consideration`/`Planning`; buildable issues ride `Buildable`. The board's one-stop to-do index. |
| `Wave` | `Wave N` | Parallel-execution wave (matrix-assigned by Plan). |
| `Phase` | `Phase N` | Master-plan phase trace. |
| `Domain` | single-select | Master-plan domain trace. |

Plus **native blocked-by** links (dependencies), an `attempt:<n>` label (per-issue
fix-loop counter for unattended observability), and **claim comments** (a builder claims
an issue by flipping `Status` to `In Progress` and posting a comment naming the agent).
There is no claim-state machine, no lane or track field, and no bookend ceremony — a board
item is workable cold by any outside agent from its body + the plain GitHub API.

`Stage` is the column-grouping field and is **additive**: a repo provisioned before it
existed keeps working as a 4-field board (an empty `Stage` reads as buildable) until
`/idc:init` (or `/idc:doctor`) provisions the field — no migration step, no data rewrite.

### 3.2 The issue is a self-sufficient goal contract

Every issue body is a distilled 6-element goal contract a builder can work cold:

```
GOAL: <single observable end-state>
VERIFICATION SURFACE: <exact runnable commands + what passing looks like; real
  functional tests, never placeholder/shallow suites; failing-test-first when untested>
CONSTRAINTS: <what must not regress; the no-punt rule>
BOUNDARIES: touch <owned surfaces — the deconfliction output> / off-limits <…>
ITERATION POLICY: record-and-vary
BLOCKED-STOP: <halt conditions + attempt ceiling>
ASSUMPTIONS: <inferred details, vetoable>
---
Dependencies: native blocked-by links
Trace: pillar file · consideration · PRD section
```

A **buildable** issue (`Stage = Buildable`) carries the full contract above. An upstream
**pointer item** (`Stage = Consideration`/`Planning`) carries only a repo-file reference plus
`Phase`/`Domain` — it indexes a consideration, in-flight plan, or pillar on the board without
copying its content (files stay the source of truth). A pointer is **reference + labels
only**: it never carries a goal-contract, and Build only ever claims `Stage = Buildable`
issues — so a staged-upstream pointer is never scooped (the glass wall, §1.2). The schema
check (`idc:idc-schema-check`) validates the two shapes apart.

**Pointer-write authority** (additive to §4): a pointer is written by the stage that produces
the artifact — **Think** writes the consideration pointer (`Stage = Consideration`), **Plan**
writes plan/pillar pointers and advances them (`Consideration → Planning`), retiring them as
buildable issues land (`Stage = Buildable`). No role writes a pointer for a stage it does not
own.

### 3.3 Six operations

`createTicket`, `setField`, `link` (`sub`|`blocks`), `move` (status), `query`, `comment`.
Adding a seventh or dropping one is a contract change that requires a Ripple to admit.

## 4. Role authority & the guardrails

Each role is the sole writer of its surface and edits nothing above it (§1.2).

### 4.1 Think

Free-form brainstorm/interview in the main session, **zero durable workers** (research
goes to bounded fan-out). Writes only `docs/considerations/`. No PRD pre-clearing, no
admission language — thinking stays free; the gate lives in Plan.

### 4.2 Plan — matrix deconfliction

One run goes consideration → issues: domain-expert fan-out → doc-chain drafting →
goal-contract authoring → **pairwise clash/matrix analysis** (parallel work never
collides) → global re-sequencing against the live board (`In Progress` issues immutable;
re-sequencing happens ONLY here) → mechanical schema check → board admission, opening a
planning PR whose body is the audit trail. **Zero durable workers** (bounded fan-out
only). The only plan review is matrix deconfliction + the schema check.

### 4.3 Build — real verification surfaces

The only board-polled role. One **durable worker per parallel-safe issue** executes the
issue's goal contract as a goal loop (record-and-vary, evidence-before-assertion, and the
**no-punt rule** — incidental work needed for success is fixed in the same loop, never
deferred). Review is fresh-context **bounded fan-out** — iterate → reverify → automerge
when all green → close. **Nothing merges that isn't green on real functional tests; a
shallow or placeholder suite is a review FAIL.** Builders never edit canonical docs;
divergence files a Ripple and pauses only the affected issue.

### 4.4 Ripple — drift healing

The only retrograde path. Determines the highest affected layer and answers one question:
does user-facing product function change? **No** → update every affected doc down the
chain in one autonomous PR (PR body = the change order). **Yes** → the §2 gate. **Zero
durable workers.**

### 4.5 Autorun

One-shot full-pipe drainer: unplanned considerations → plan-run workers (board admission
serialized) → build eligible waves as they land → exit report when nothing actionable
remains (only PRD-gated items waiting on the operator). Loopable via `/loop`. Running it
on a quiet repo just heals board hygiene and drains stragglers. `/idc:doctor` stays
read-only.

## 5. Runtime primitives & concurrency budget

The process is written against three abstract primitives; the runtime adapter for your
harness maps them to concrete mechanics.

| Primitive | Used for |
|---|---|
| **Durable worker** | Build implementers, autorun lanes |
| **Bounded fan-out** | domain experts, drafters, clash pairs, reviewers |
| **Goal loop** | issue execution |

**Concurrency budget:** Think / Plan / Ripple = **zero** durable workers (bounded fan-out
only); Build = one durable worker per parallel-safe issue; review = bounded fan-out in
every runtime. **Fallback ladder:** with no durable-worker environment, that work runs
serially in the main session; review fan-out is always available (fresh context = true
adversarial independence, and token-optimal).

## 6. Model routing (tier-symbolic)

Process docs name **tiers**, never concrete models. The tier → model map lives in
`WORKFLOW-config.yaml::model_routing`; the runtime adapter resolves a tier to a concrete
model at spawn time, and Ripple maintains the table when models change.

- `reasoning` — planning cognition, the review coordinator/verdict + all judgment review
  dimensions, ripple layer-impact analysis + PRD diffs, clash/matrix + sequencing, merge
  deconfliction.
- `standard` — think/interview, build implementers (goal loops), the finisher/orchestrator,
  the autorun parent.
- `utility` — the execute-never-decide lane: research digestion, repo reconnaissance,
  templated emission from up-tier content, board mechanics, the schema check, and the
  inventory-style review dimensions under the coordinator.

The Codex runtime is **untiered**: highest available model at highest reasoning effort for
every role.

## 7. Commit / PR conventions

Every commit traces to the issue or change order it advances. Never commit with
`--no-verify`. Planning PRs and ripple PRs automerge when green (the §2 PRD gate is the
only human touchpoint); build PRs automerge on a PASS review with real tests green.
