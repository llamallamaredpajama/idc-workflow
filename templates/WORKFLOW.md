# WORKFLOW.md — {{PROJECT_NAME}} IDC governance contract

> **This file is a hard contract.** Its existence marks the repo as IDC-governed, and its
> section numbers are **stable** so the IDC roles and skills can cite rules by anchor
> (e.g. "WORKFLOW.md §3.1"). Keep the numbering stable when you edit.

> **The mental model — the pipeline.** Picture IDC as a pipeline. Ideas drop into the **Think
> Tank** (`/idc:think`) and firm up into one consideration; Think then carries that idea's **PRD +
> TRD** (the user-facing *what* and the technical *how*) to the **first Diverter** — the one gate
> (§2), fired at the **end of Think** on the **Think PR**, the one valve only you can open. Admitted
> water runs through the **planning train** (`/idc:plan`), then the build triplet of **turbines** —
> **Implementer → Filter → Finisher** (`/idc:build`) — and reaches the **second Diverter**: clean
> water pours out the **Faucet** (`/idc:autorun`) as merged software in your glass, while anything
> not-good goes to the **Recirculator** (`/idc:recirculate`, §4.4), the single controlled way back,
> which carries it up to the first Diverter again. The board is the **dashboard** that meters every
> turbine (§3.1). This is the friendly picture; the numbered sections below are the authoritative
> contract.

IDC carries an idea from a raw thought to merged, tested code. It is built on
**guardrails, not train tracks**: the model is trusted to do the work; the process
intervenes only where a real derailment would otherwise ship. There are exactly five
guardrails — the one requirements gate at the end of Think (§2), matrix deconfliction (§4.2),
real verification surfaces (§4.3), recirculator drift-healing (§4.4), and one-way flow through
the glass wall (§1.2). Everything else flows autonomously.

## 1. Canonical chain & flow

### 1.1 The pipeline

`Think → Plan → Build`, with the `Recirculator` as the only retrograde path and `Autorun` as the
one-shot drainer that traverses the whole pipe. Slash surfaces: `/idc:think`,
`/idc:plan`, `/idc:build`, `/idc:recirculate`, `/idc:autorun`, plus `/idc:init` (per-project
scaffold) and `/idc:doctor` (read-only health check).

| Stage | Slash surface | Surface it writes |
|---|---|---|
| Think | `/idc:think` | `docs/considerations/` + the gated **PRD** (`docs/prd/`) and **TRD** (`docs/specs/`) draft, opened on the Think PR (§2) |
| Plan | `/idc:plan` | `docs/plans/` (master + subphases + pillars), pillar matrices, and tracker issues — pure decomposition, no requirements docs |
| Build | `/idc:build` | source surfaces (per issue `BOUNDARIES`), tests, review reports, and tracker status |
| Recirculator | `/idc:recirculate` | every affected canonical doc, synchronized in one PR |

### 1.2 One-way flow + the glass wall

Requirements enter the pipeline **only** through the one gate at the end of Think (§2) — an
idea is admitted once, at the top, by merging its Think PR. Downstream, planning reaches Build
**only** through tracker issues (the glass wall); Build reaches planning **only** through the
Recirculator. No role edits a layer above it; a lower role that finds a higher layer wrong files
a recirculation and pauses only the affected issue.

### 1.3 The five-layer doc chain

PRD → master architectural spec (the TRD) → master implementation plan → subphase plans →
pillar plans. All five survive as files for traceability. **The requirements layers — the PRD
(always) and the TRD when `gating.trd: on` — are gated at the end of Think (§2) and authored
there; every plan-layer doc below them is drafted, updated, and merged autonomously** by Plan
and the Recirculator.

## 2. The one gate — requirements admission (the Think PR)

The single human checkpoint in the entire system, and it fires at the **end of Think**. When an
idea is crystallized, Think drafts its **PRD** (the user-facing *what*) and **TRD** (the
technical *how*; the `spec` layer) and opens a **Think PR** carrying that draft, plus one
**gate issue** (`idc:idc-gate-issue`) that carries a plain-terms summary ("here's what your app
will do differently") plus the proposed PRD/TRD diff. The PRD/TRD stay **draft until merge**:
**merge = approval = admission** to the pipeline. Approval is **sync or async** — the operator
may approve in-session, or leave the PR open and approve later from the GitHub web UI (a saved-
but-unapproved idea is just an open Think PR). The PRD always gates while `gating.prd: on`; the
TRD gates when `gating.trd: on` (greenfield off / brownfield on). **Nothing else in the system
asks for permission** — once the Think PR merges, planning and building free-flow. The
Recirculator reuses this **same** gate for any backflow that needs a requirements change (§4.4).

**Backend-portable approval.** The Think PR (and the §2.1 `decision-approved` label / decision-PR)
are **github** signals. On the **filesystem** backend — no PRs, no labels — the operator's approval
signal for *both* gates is the **gate issue's `Status` moved to `Done`** (`idc:idc-gate-issue` →
*Approval signal by backend*); detection and the fail-closed posture are otherwise identical, so a
non-GitHub repo's gates are never silently un-approvable.

### 2.1 The strategic decision gate (the second gate type)

The requirements gate above is the only gate that **admits** an idea, and the only thing that asks
for *permission*. Separately, a run can hit a genuine **non-requirements** strategic GO/NO-GO — e.g.
a proving-spike result — that changes no PRD/TRD. Rather than let the orchestrator **improvise** that
prompt (the failure mode the no-ask invariant forbids, §4.3/§4.5), IDC models it as a board state: an
**`operator-decision`** gate (`idc:idc-gate-issue`). It is **not** an admission gate — it never lands
a PRD/TRD and never reuses the Think-PR merge signal. Its fail-closed approval is an **explicit
positive act** (a `decision-approved` label, or a merged lightweight decision-PR); a
closed-but-unapproved gate is **not** a GO. It pauses **only its dependents** and reuses the existing
six tracker operations (§3.3) — no seventh op. The orchestrator **reports** a pending decision gate
and keeps draining the rest of the pipe, exactly as it reports a pending Think PR.

## 3. Tracker substrate

The tracker is the glass wall (§1.2). Its backend is selected by `backend:` in
`docs/workflow/tracker-config.yaml` and hidden behind the configured tracker adapter —
roles never hard-code backend semantics. Two backends ship: `github` (a GitHub Projects
v2 board; first-class) and `filesystem` (a root `TRACKER.md`; zero external setup).

### 3.1 Board schema — five fields

| Field | Values | Meaning |
|---|---|---|
| `Status` | `Blocked` / `Todo` / `In Progress` / `Done` | Where the issue sits in the queue. |
| `Stage` | `Consideration` / `Planning` / `Buildable` | Pipeline column: `Consideration` = an open Think PR / **pending admission** at the end-of-Think gate (§2); `Planning` = an admitted idea being decomposed; `Buildable` = a workable issue. Upstream `Consideration`/`Planning` items are pointers; the board's one-stop to-do index. |
| `Wave` | `Wave N` | Parallel-execution wave (matrix-assigned by Plan). |
| `Phase` | `Phase N` | Master-plan phase trace. |
| `Domain` | single-select | Master-plan domain trace. |

`/idc:init` links this board to the governed repo, so it appears on the repo's **Projects tab**
and issue sidebar (a v2 board is org/user-owned and otherwise invisible from the repo).

Plus **native blocked-by** links (dependencies), an `attempt:<n>` label (per-issue
fix-loop counter for unattended observability), and **claim comments** (a builder claims
an issue by flipping `Status` to `In Progress` and posting a comment naming the agent).
There is no claim-state machine, no lane or track field, and no bookend ceremony — a board
item is workable cold by any outside agent from its body + the plain GitHub API.

`Stage` is the column-grouping field and is **additive**: a repo provisioned before it
existed keeps working as a 4-field board (an empty `Stage` reads as buildable) until
`/idc:init` provisions the field (`/idc:doctor` is read-only — it only *flags* a missing
`Stage`, never provisions it) — no migration step, no data rewrite.

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
the artifact — **Think** writes the consideration pointer (`Stage = Consideration`), held
**Blocked** behind its gate issue while the Think PR is open (pending admission); merging the
Think PR (approval) unblocks it. **Plan** then decomposes the admitted consideration, advancing
it (`Consideration → Planning`) and writing plan/pillar pointers, retiring them as buildable
issues land (`Stage = Buildable`). No role writes a pointer for a stage it does not own.

### 3.3 Six operations

`createTicket`, `setField`, `link` (`sub`|`blocks`), `move` (status), `query`, `comment`.
Adding a seventh or dropping one is a contract change that requires a recirculation to admit.

## 4. Role authority & the guardrails

Each role is the sole writer of its surface and edits nothing above it (§1.2).

### 4.1 Think

Free-form brainstorm/interview in the main session, **zero durable workers** (research
goes to bounded fan-out). The conversation stays free, then Think **crystallizes** it: it writes
`docs/considerations/` and **authors the gated requirements docs — the PRD (`docs/prd/`) and the
TRD (`docs/specs/`) — and fires the one gate** by opening the **Think PR** + gate issue
(`idc:idc-gate-issue`). PRD/TRD stay draft until merge = approval = admission (§2). Think is the
sole author of the requirements layers; everything below them is decomposition.

### 4.2 Plan — pure decomposition (matrix deconfliction)

Plan **sheds requirements authoring** — it never writes the PRD/TRD and never gates (the gate
already fired at Think). One run decomposes an **admitted** consideration → issues: domain-expert
fan-out → goal-contract authoring → **pairwise clash/matrix analysis** (parallel work never
collides) → global re-sequencing against the live board (`In Progress` issues immutable;
re-sequencing happens ONLY here) → mechanical schema check → board admission, opening a
planning PR whose body is the audit trail and which **automerges when green** (no gate here).
**Zero durable workers** (bounded fan-out only). The only plan review is matrix deconfliction +
the schema check.

### 4.3 Build — real verification surfaces

The only board-polled role. One **durable worker per parallel-safe issue** executes the
issue's goal contract as a goal loop (record-and-vary, evidence-before-assertion, and the
**no-punt rule** — incidental work needed for success is fixed in the same loop, never
deferred). Review is fresh-context **bounded fan-out** — iterate → reverify → automerge
when all green → close. **Nothing merges that isn't green on real functional tests; a
shallow or placeholder suite is a review FAIL.** Builders never edit canonical docs;
divergence files a recirculation and pauses only the affected issue.

### 4.4 Recirculator — drift healing

The only retrograde path. Determines the highest affected layer and answers one question:
does a **gated requirements layer** change (the PRD always; the TRD/`spec` layer when
`gating.trd: on`)? **No** → update every affected doc down the chain in one autonomous PR (PR
body = the change order). **Yes** → reuse the §2 gate — a new gated **Think PR** carrying the
requirements diff, admitted the same way. **Zero durable workers.**

### 4.5 Autorun

One-shot full-pipe drainer. It only decomposes/builds **admitted** ideas: an **open Think PR**
(a consideration pending admission) is treated exactly like an open gate — **report + skip,
never stall or bypass**. Approved considerations → plan-run workers (board admission
serialized) → build eligible waves as they land → exit report when nothing actionable
remains (only requirements-gated items, the operator's gate issues, and un-admitted
considerations waiting on the operator). Loopable via `/loop`. Running it
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

**Concurrency budget:** Think / Plan / Recirculator = **zero** durable workers (bounded fan-out
only); Build = one durable worker per parallel-safe issue; review = bounded fan-out in
every runtime. **Fallback ladder:** with no durable-worker environment, that work runs
serially in the main session; review fan-out is always available (fresh context = true
adversarial independence, and token-optimal).

## 6. Model routing (tier-symbolic)

Process docs name **tiers**, never concrete models. The tier → model map lives in
`WORKFLOW-config.yaml::model_routing`; the runtime adapter resolves a tier to a concrete
model at spawn time, and the Recirculator maintains the table when models change.

- `reasoning` — planning cognition, the review coordinator/verdict + all judgment review
  dimensions, recirculator layer-impact analysis + PRD diffs, clash/matrix + sequencing, merge
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
`--no-verify`. Planning PRs and (non-gated) recirculation PRs automerge when green; build PRs
automerge on a PASS review with real tests green. The **Think PR** is the one human touchpoint
(§2) — it stays **draft until the operator merges it** (= approval = admission); a gated
recirculation rides the same Think-PR gate.
