# IDC Architecture (v3)

How the pieces of the IDC plugin fit together: the flow, the five guardrails, the
write-authority boundaries, the tracker contract, the runtime model, and how commands,
agents, and skills compose. It is derived from `templates/WORKFLOW.md` (the contract a
governed repo installs) and `docs/specs/master-architectural-spec.md` (the plugin's own
architecture). For the human-facing picture of the whole system, read
[`mental-model.md`](mental-model.md) — the **water rig**; this document is its precise
counterpart. For the rules a governed project runs under, read that project's `WORKFLOW.md`.

## The flow

```
Think → Plan → Build        (the Recirculator heals drift; Autorun drains the whole pipe)
```

In water-rig terms (see [`mental-model.md`](mental-model.md)): the **Think Tank** (`/idc:think`)
crystallizes an idea into a PRD + TRD and fires the **one gate** (the Think PR, **Diverter #1**);
once admitted, the **processing train** (`/idc:plan`) decomposes it, and the build triplet —
**Implementer → review filter → Finisher** (`/idc:build`) — runs each wave and ends at **Diverter #2**
(ship or return). The **Recirculator** is Diverter #2's controlled backflow; **Autorun** is the
**Faucet** that opens the whole pipe at once.

The five-layer canonical chain — the spine everything traces to — is:

```
PRD → TRD (architecture spec) → master implementation plan → subphase plans → pillar plans → tracker issues
```

`docs/considerations/` is pre-canonical input (Think's brainstorm). The top two layers — the **PRD**
and the **TRD** — are authored by Think and admitted **once, at the Think PR gate**; the plan layers
below them are drafted autonomously. Tracker issues are the **water in the pipe**: planning reaches
Build only by turning plans into issues, and Build reaches planning only through the Recirculator.
Flow is one-way; the chain is auditable end to end because a sensor on every component reports to the
dashboard (the board).

## Guardrails, not train tracks

v1 hand-held a weaker model with standing reviewer/fixer/researcher roles, multi-pass plan
reviews, a claim-state machine, and per-edit gates. v3 trusts the model and keeps only the
five parts of the rig that catch real derailments:

1. **The one gate at the top** — the Think PR admitting the PRD + TRD; product function never changes
   without consent, and it's asked **once**, before any work begins.
2. **Parallel pipes on separate sections** (the matrix + sequencer manifold) — wide builds never collide.
3. **The review filter** (real verification surfaces) — nothing reaches the Glass that isn't green on
   genuine functional tests.
4. **The Recirculator** (controlled backflow) — docs and reality never silently diverge.
5. **One-way flow + the metered dashboard** — the chain is auditable end to end.

Everything else flows autonomously and automerges when green.

## Write-authority boundaries

Each role is the sole writer of its surface and edits nothing upstream of it.

| Role | May write | Must NOT write |
|------|-----------|----------------|
| **Think** | `docs/considerations/` + the gated PRD + TRD (drafted on the Think PR) | plans, tracker, source, tests |
| **Plan** | master/subphase/pillar plans, pillar matrices, tracker issues — pure decomposition | PRD, TRD, source, tests |
| **Build** | source, tests, review reports, tracker status (claim/close) | PRD, TRD, plans |
| **Recirculator** | every affected canonical doc (one synchronized PR), affected open issues | source, tests |

When a lower role finds a higher layer wrong, it routes through the Recirculator (files a
recirculation) and pauses only the affected issue — it never edits the upstream doc itself.

## The one gate (Diverter #1 → the Think PR)

The single human checkpoint fires at the **end of Think**. When an idea crystallizes, Think drafts its
**PRD** (*what the software does for the user*) and **TRD** (*how it's built* — the `spec` layer) and
opens a **Think PR** carrying that draft, plus one gate issue (plain-terms summary + the PRD/TRD diff);
the operator is push-notified and opens the gate from the GitHub web UI. The PRD/TRD stay **draft until
merge** — **merge = approval = admission**. Approval is **sync or async** (in-session, or leave the PR
open and approve later). The PRD always gates while `gating.prd: on`; the TRD (the `spec` layer) gates
when `gating.trd: on` (greenfield off / brownfield on). The Recirculator **reuses this same gate** for
any backflow that needs a requirements change — implemented identically via `idc:idc-gate-issue`, **one
valve shared by the top gate and backflow**. Once the Think PR merges, planning and building free-flow;
nothing else asks for permission.

## The tracker contract (the dashboard)

The board is the rig's **dashboard** — a sensor on every component, not part of the plumbing
itself. The backend is selected by `backend:` in `docs/workflow/tracker-config.yaml` and hidden
behind `idc:idc-tracker-adapter` (→ `idc:idc-tracker-github` or `idc:idc-tracker-filesystem`).
The board carries **five** fields — `Status` (`Blocked|Todo|In Progress|Done`), `Stage`
(`Consideration|Planning|Buildable` — which part of the pipe each drop is in; `Consideration` = an open
Think PR pending admission), `Wave`, `Phase`, `Domain` — plus native blocked-by, an `attempt:<n>`
label, and claim comments. `Stage` is **additive**: a board provisioned before it existed reads an
absent `Stage` as `Buildable` and keeps working as a legacy 4-field board. The interface is six ops
(createTicket/setField/link/move/query/comment). An issue body is a self-sufficient 6-element goal
contract, so an outside agent can work it cold.

## Runtime model — one core, thin adapters

The process is written against three abstract primitives — **durable worker**, **bounded
fan-out**, **goal loop** — and exactly one adapter per runtime maps them to mechanics
(`idc:idc-adapter-claude`, `idc:idc-adapter-codex`, `idc:idc-adapter-pi`). There is no
per-runtime process tree. Concurrency budget: Think/Plan/Recirculator use zero durable workers (bounded
fan-out only); Build uses one durable worker per parallel-safe issue; review is bounded fan-out
everywhere. Model selection is **tier-symbolic** (`reasoning`/`standard`/`utility` in
`WORKFLOW-config.yaml::model_routing`, resolved by the adapter at spawn time); the Codex runtime
is untiered.

## Composition + naming

- **Commands** (`commands/*.md`) are the slash entry points; `/idc:plan` tells the session to
  operate as the Plan orchestrator by reading the matching agent playbook.
- **Agents** (`agents/*.md`) are the per-stage orchestrators, the durable-worker implementer +
  finisher, and the review coordinator.
- **Skills** (`skills/<name>/SKILL.md`) are the reusable procedures the roles compose.

All agents and skills use a flat `idc-<thing>` name; the harness adds the `idc:` namespace.
`${CLAUDE_PLUGIN_ROOT}` resolves to the install path inside command/agent/skill bodies (it is
text-substituted, not a shell env var). `scripts/lint-references.sh` enforces that every
`idc:<name>` reference and every shipped-path token resolves to a real file.

## Required trace (the audit rule)

Subphase plans record their upstream master domain/phase; pillar plans record their upstream
subphase; each issue's `Trace:` line cites its pillar · consideration · PRD section. These
traces let any issue be walked back to the requirement that justified it — and let the Recirculator
compute the highest affected layer when something drifts (the backflow target).
