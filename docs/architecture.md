# IDC Architecture (v2)

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
feeds the **Planning turbine** (`/idc:plan`), which feeds the build triplet — **Implementer →
Filter → Finisher** (`/idc:build`). The **Recirculator** is the **Bleed Valve**; **Autorun** is the
**Faucet** that opens the whole pipe at once.

The five-layer canonical chain — the spine everything traces to — is:

```
PRD → architecture spec → master implementation plan → subphase plans → pillar plans → tracker issues
```

`docs/considerations/` is pre-canonical input (Think's output). Tracker issues are the **water in
the pipe**: planning reaches Build only by turning plans into issues, and Build reaches planning
only through the Bleed Valve (the Recirculator). Flow is one-way; the chain is auditable end to end because
a sensor on every turbine reports to the dashboard (the board).

## Guardrails, not train tracks

v1 hand-held a weaker model with standing reviewer/fixer/researcher roles, multi-pass plan
reviews, a claim-state machine, and per-edit gates. v2 trusts the model and keeps only the
five parts of the rig that catch real derailments:

1. **The one locked valve to the PRD** — product function never changes without consent.
2. **Parallel pipes on separate sections** (matrix deconfliction) — wide builds never collide.
3. **The Filter** (real verification surfaces) — nothing reaches the Glass that isn't green on
   genuine functional tests.
4. **The Bleed Valve** (the Recirculator) — docs and reality never silently diverge.
5. **One-way flow + the metered dashboard** — the chain is auditable end to end.

Everything else flows autonomously and automerges when green.

## Write-authority boundaries

Each role is the sole writer of its surface and edits nothing upstream of it.

| Role | May write | Must NOT write |
|------|-----------|----------------|
| **Think** | `docs/considerations/` only | any canonical doc, tracker, source, tests |
| **Plan** | PRD, spec, master/subphase/pillar plans, pillar matrices, tracker issues | source, tests |
| **Build** | source, tests, review reports, tracker status (claim/close) | PRD, spec, plans |
| **Recirculator** | every affected canonical doc (one synchronized PR), affected open issues | source, tests |

When a lower role finds a higher layer wrong, it opens the Bleed Valve (files a recirculation) and
pauses only the affected issue — it never edits the upstream doc itself.

## The one gate (the Diverter Valve → PRD)

When Plan or the Recirculator determines the PRD must change — i.e. *what the software does for the user*
changes — the Diverter Valve diverts that flow up to the PRD: the affected issues park `Blocked`
behind a single gate issue (plain-terms summary + the PRD diff); the operator is push-notified and
opens the valve from the GitHub web UI; approval unblocks the chain. Implemented identically by
Plan and the Recirculator via `idc:idc-gate-issue` — **one valve, shared by forward flow and backflow**.
Nothing else asks for permission.

## The tracker contract (the dashboard)

The board is the rig's **dashboard** — a sensor on every turbine, not part of the plumbing
itself. The backend is selected by `backend:` in `docs/workflow/tracker-config.yaml` and hidden
behind `idc:idc-tracker-adapter` (→ `idc:idc-tracker-github` or `idc:idc-tracker-filesystem`).
The board carries **five** fields — `Status` (`Blocked|Todo|In Progress|Done`), `Stage`
(`Consideration|Planning|Buildable` — which part of the pipe each drop is in), `Wave`, `Phase`,
`Domain` — plus native blocked-by, an `attempt:<n>` label, and claim comments. `Stage` is
**additive**: a board provisioned before it existed reads an absent `Stage` as `Buildable` and
keeps working as a legacy 4-field board. The interface is six ops
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
compute the highest affected layer when something drifts (the Bleed Valve's backflow target).
```
