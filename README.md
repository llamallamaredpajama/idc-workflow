<p align="center">
  <img src="docs/assets/idc-banner.svg" alt="IDC — Iterative Development Cycle · guardrails, not train tracks" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-3.0.0-9CA689?style=flat-square&labelColor=252427" alt="version 3.0.0">
  <img src="https://img.shields.io/badge/Claude%20Code-plugin-9CA689?style=flat-square&labelColor=252427" alt="Claude Code plugin">
  <img src="https://img.shields.io/badge/commands-9-9CA689?style=flat-square&labelColor=252427" alt="9 commands">
  <img src="https://img.shields.io/badge/runtime-Claude%20%C2%B7%20Codex%20%C2%B7%20Pi-9CA689?style=flat-square&labelColor=252427" alt="runtimes">
  <img src="https://img.shields.io/badge/guardrails-5-F56A6A?style=flat-square&labelColor=252427" alt="5 guardrails">
  <img src="https://img.shields.io/badge/license-MIT-F9FAFD?style=flat-square&labelColor=252427" alt="MIT license">
</p>

<p align="center">
  <b>A <a href="https://claude.com/claude-code">Claude Code</a> plugin that carries software from a raw idea to merged, reviewed code —</b><br>
  a guardrail-framed, tracker-driven, goal-contract pipeline. <i>Guardrails, not train tracks.</i>
</p>

---

IDC is a **water rig for software**. You drop an idea into the **Think Tank**; Think crystallizes it
into a **PRD** (*what* it does) and a **TRD** (*how* it's built) and carries both to the **one gate** —
a reviewable **Think PR** you merge to admit it. From there the rig plans, builds, and reviews on its
own and **automerges when clean**, pouring merged code out the **Faucet** into your **Glass**. It stops
to ask you exactly **one** question, **once, at the top**: *do you approve these requirements?*

## The whole system, in one picture

<p align="center">
  <img src="docs/assets/mental-model-hero-vector.svg" alt="The IDC water rig — an idea in, working software out" width="100%">
</p>

An idea enters the **Think Tank** and Think crystallizes it into a **PRD + TRD**. The **first Diverter**
(the one gate) is a **Think PR** you merge to admit it. Admitted work runs through the **processing
train** — sliced into the **matrix**, screened by the **matrix-analysis filter**, fanned out by the
**sequencer manifold** into parallel **waves** — spins the build triplet of **turbines** (implementer →
review filter → finisher), and hits the **second Diverter**: clean water pours out the **Faucet** into
your **Glass**; anything not-good goes to the **Recirculator** — the one controlled way back, all the
way to the gate.

**→ The full mental model, part by part, lives in [`docs/mental-model.md`](docs/mental-model.md).**

## Table of contents

- [What IDC is](#what-idc-is)
- [The five guardrails](#the-five-guardrails)
- [Install](#install)
- [Quickstart](#quickstart)
- [The commands](#the-commands)
- [Architecture](#architecture)
- [The dashboard](#the-dashboard)
- [Runtime model](#runtime-model)
- [What ships](#what-ships)
- [Developing on this plugin](#developing-on-this-plugin)
- [Repository layout](#repository-layout)
- [License](#license)

## What IDC is

IDC — the **Iterative Development Cycle** — is the rig in the picture above: a **Think Tank** that
feeds the **one gate** (a Think PR admitting the PRD + TRD), a **processing train** that plans, a build
triplet of **turbines**, **two Diverters** (the gate at the top; ship-or-return at the end), and one
**Recirculator** for controlled backflow. Everything flows autonomously and **automerges when green**;
the rig intervenes only where a real derailment would otherwise ship.

| Stage | Command | The part of the rig | Writes |
|-------|---------|--------------------|--------|
| **Think** | `/idc:think` | 🛢️ **Think Tank → ╳ Diverter #1** — free brainstorm (zero teammates) → crystallize a function-first **PRD + TRD** → the **Think PR** gate (admit by merging). | `docs/considerations/`, `docs/prd/`, `docs/specs/` |
| **Plan** | `/idc:plan` | 🚂 **Processing train** — admitted idea → goal-contract issues: domain experts, the **matrix** (two grid-plates), the **matrix-analysis filter**, the **sequencer manifold** into waves. Pure decomposition — no requirements docs, no gate. | `docs/plans/`, matrices, issues |
| **Build** | `/idc:build` | ⊙ **Implementer → ▒ review filter → ⊙ Finisher → ╳ Diverter #2** — each issue's goal contract runs as a turbine (iterative loop); independent review screens every PR; automerge on PASS. | source, tests, review reports, tracker status |
| **Recirculator** | `/idc:recirculate` | ▶ **the backflow** — Diverter #2's return path: heals doc/reality drift in one PR (PR body = change order); a requirements change rides the Think-PR gate. | every affected canonical doc |
| **Autorun** | `/idc:autorun` | 🚰 **Faucet** — open it and the whole pipe drains on its own; loop it with `/loop`. | — |

> **Autorun** opens the faucet full: admitted considerations → plan → build eligible waves as they
> land → exit when nothing actionable remains (an open Think PR is reported + skipped, never bypassed).

## The five guardrails

IDC v3 trusts the model and keeps only the parts of the rig that catch real derailments. There
are exactly **five**:

| # | Guardrail (the part) | What it prevents |
|---|-----------|------------------|
| 1 | **The one gate at the top** (the Think PR admitting the PRD + TRD) | Your product's function — and, on brownfield, its architecture — never changes without your consent, asked once before any work begins. |
| 2 | **Parallel pipes on separate sections** (the matrix + sequencer manifold) | Wide builds never collide. |
| 3 | **The review filter** (real verification surfaces) | Nothing reaches the Glass that isn't green on genuine functional tests. |
| 4 | **The Recirculator** (controlled backflow) | Docs and reality never silently diverge. |
| 5 | **One-way flow + the metered dashboard** | The chain stays auditable end to end. |

**The one gate.** At the **end of Think**, the PRD + TRD ride a **Think PR** — they stay **draft until
you merge it** (merge = approval = admission). You get a push notification with a plain-terms summary +
the diff and open the gate from the GitHub web UI — on your phone, in-session, or later. The PRD always
gates (`gating.prd: on`); the TRD gates when `gating.trd: on` (brownfield on / greenfield off). Once the
Think PR merges, planning and building free-flow — nothing else asks for permission, and the
Recirculator reuses this same gate for any backflow that needs a requirements change.

## Install

IDC is **opt-in per repo** — its `/idc:*` commands must never appear in a repo you didn't
choose. Claude Code installs a plugin's *files* machine-wide but decides where its commands
*activate* by an enablement **scope**. So: register the marketplace once, then install at
**`project` scope** inside each repo you want governed — never the default `user` scope, which
would turn IDC on in *every* repo on the machine.

```bash
# once per machine — register the marketplace (installs/enables nothing on its own)
claude plugin marketplace add llamallamaredpajama/idc-workflow

# per repo — install AND enable for THIS repo only
cd <your-repo>
claude plugin install idc@idc-workflow --scope project
```

`--scope project` enables IDC in the repo's own `.claude/settings.json` and registers it
**disabled** (`idc@idc-workflow: false`) at the global `user` scope — an explicit off-switch,
stronger than merely being absent — so IDC stays invisible everywhere else. (Already installed
at the default `user` scope from an older version? Seal the leak with `claude plugin disable
idc@idc-workflow --scope user` — your project-scoped repos keep working.)

> **Updating.** Bump-driven: `claude plugin update idc@idc-workflow --scope project` (the
> `--scope project` matters — the bare command errors for a project install). A plugin update
> rebuilds Claude Code's version-keyed cache, so a session may need a restart to pick up new
> command definitions.

A GitHub board needs the `project` OAuth scope:
`gh auth refresh -h github.com -s project`.

## Quickstart

Start a **new** Claude Code session in the repo (so the commands load), then:

```bash
/idc:init        # install the rig: contract + config + board + receipt
/idc:doctor      # pressure-test it (read-only health check)
/idc:think       # cast in your first idea → PRD + TRD → the Think PR gate (merge to admit)
/idc:plan        # admitted idea → goal-contract issues on the board
/idc:build       # drain the buildable issues to merged, reviewed code
```

`/idc:init` scaffolds the governance contract + config (filling `domains` from a codebase
scan), provisions a **5-field** GitHub Projects board **linked to this repo** — or uses the
zero-setup `filesystem` backend — sets the type-aware TRD gate (brownfield on / greenfield off) by
scanning + confirming what already exists, enables the plugin **for this project only**, and writes an
install receipt. `/idc:doctor`'s first check fails loudly if IDC is ever enabled at the global
`user` scope.

## The commands

Nine slash entry points:

| Command | The part of the rig |
|---------|------|
| `/idc:think` | 🛢️ Think Tank → ╳ Diverter #1 — brainstorm → crystallize PRD + TRD → the Think PR gate |
| `/idc:plan` | 🚂 Processing train — admitted idea → goal-contract issues |
| `/idc:build` | ⊙▒⊙ the build triplet — issues → merged, reviewed code |
| `/idc:recirculate` | ▶ Recirculator — Diverter #2's controlled backflow; heal doc/reality drift in one PR |
| `/idc:autorun` | 🚰 Faucet — open the whole pipe, drain it hands-off |
| `/idc:init` | 🔧 install the rig (idempotent) |
| `/idc:doctor` | 🔧 pressure-test the rig (read-only) |
| `/idc:update` | 🔧 upgrade the fittings after a plugin bump |
| `/idc:uninstall` | 🔧 remove the rig in one revertable commit |

## Architecture

The spine everything traces to is a **five-layer canonical chain**. Its top two layers — the **PRD**
and the **TRD** — are authored by Think and admitted **once, at the Think PR gate**; everything below
is drafted autonomously. Planning reaches Build *only* by turning plans into issues — the water in the
pipe; Build reaches planning *only* through the Recirculator. Flow is one-way, and a sensor on every
component keeps the chain auditable end to end.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#9CA689','primaryTextColor':'#1b1a1c','primaryBorderColor':'#252427','lineColor':'#6f7a5e','fontFamily':'Trebuchet MS, Verdana, sans-serif'}}}%%
flowchart LR
    subgraph chain["Five-layer canonical chain — PRD + TRD admitted at the Think PR gate"]
        direction LR
        PRD["PRD"]:::doc --> SPEC["TRD<br/>(arch spec)"]:::doc --> MP["Master plan"]:::doc --> SUB["Subphase plans"]:::doc --> PIL["Pillar plans"]:::doc
    end
    PIL --> ISS["Tracker issues<br/>· the water in the pipe ·"]:::wall
    ISS --> BUILD["Build"]:::stage
    BUILD -.->|"Recirculator — the only way back"| PRD

    classDef doc fill:#F9FAFD,stroke:#252427,color:#252427;
    classDef stage fill:#9CA689,stroke:#252427,color:#1b1a1c;
    classDef wall fill:#252427,stroke:#252427,color:#F9FAFD;
```

**Write-authority boundaries** — each role is the sole writer of its surface and edits nothing
upstream of it. When a lower role finds a higher layer wrong, it routes through the Recirculator
(files a recirculation) and pauses only the affected issue.

| Role | May write | Must NOT write |
|------|-----------|----------------|
| **Think** | `docs/considerations/` + the gated **PRD + TRD** (drafted on the Think PR) | plans, tracker, source, tests |
| **Plan** | master/subphase/pillar plans, pillar matrices, tracker issues — pure decomposition | PRD, TRD, source, tests |
| **Build** | source, tests, review reports, tracker status | PRD, TRD, plans |
| **Recirculator** | every affected canonical doc (one PR), affected open issues | source, tests |

See [`docs/mental-model.md`](docs/mental-model.md) for the water-rig picture in full,
[`docs/architecture.md`](docs/architecture.md) for the precise architecture, and
[`docs/installing.md`](docs/installing.md) for detailed install + troubleshooting.

## The dashboard

The tracker is the rig's **dashboard** — instrumentation bolted onto the pipe, a sensor on every
component and a status light on every wave-pipe. Its backend is selected in
`docs/workflow/tracker-config.yaml` and hidden behind an adapter — roles never hard-code backend
semantics. Two backends ship: `github` (a GitHub Projects v2 board, first-class) and `filesystem` (a
root `TRACKER.md`, zero external setup). `/idc:init` links the github board to this repo, so it shows
on the repo's **Projects tab** and issue sidebar. The board carries **five** sensor readings:

| Field | Values |
|-------|--------|
| `Status` | `Blocked` · `Todo` · `In Progress` · `Done` |
| `Stage` | `Consideration` · `Planning` · `Buildable` (which part of the pipe the drop is in; `Consideration` = an open Think PR pending admission) |
| `Wave` | `Wave N` (which parallel pipe — matrix-assigned) |
| `Phase` | `Phase N` (master-plan phase trace) |
| `Domain` | single-select (master-plan domain trace) |

Plus native blocked-by links, an `attempt:<n>` label, and claim comments. Every issue body is a
self-sufficient **6-element goal contract**, so an outside agent can work it cold.

## Runtime model

The process is written against three abstract primitives; exactly one thin adapter per runtime
maps them to mechanics. There is no per-runtime process tree.

```mermaid
%%{init: {'theme':'base','themeVariables':{'primaryColor':'#9CA689','primaryTextColor':'#1b1a1c','primaryBorderColor':'#252427','lineColor':'#6f7a5e','fontFamily':'Trebuchet MS, Verdana, sans-serif'}}}%%
flowchart LR
    subgraph core["One core · three primitives"]
        direction LR
        DW["Durable worker"]:::p
        BF["Bounded fan-out"]:::p
        GL["Goal loop"]:::p
    end
    core --> CL["Claude adapter"]:::ad
    core --> CX["Codex adapter"]:::ad
    core --> PI["Pi adapter"]:::ad

    classDef p fill:#F9FAFD,stroke:#252427,color:#252427;
    classDef ad fill:#9CA689,stroke:#252427,color:#1b1a1c;
```

Model selection is **tier-symbolic** (`reasoning` / `standard` / `utility` in
`WORKFLOW-config.yaml`, resolved by the adapter at spawn time); the Codex runtime runs untiered
at highest effort. `/idc:init --codex` wires the Codex adapter
(`scripts/install-codex.sh --revert` undoes it).

## What ships

This repo is the plugin **and** its own marketplace:

- **9 commands** — the pipeline (`think · plan · build · recirculate · autorun`) plus `init`,
  `doctor`, and the lifecycle pair `update` / `uninstall`.
- **8 agents** — the per-stage orchestrator playbooks, the durable-worker implementer + finisher,
  and the review coordinator + review agent.
- **13 skills** — the runtime adapters (Claude · Codex · Pi), the tracker adapter + its two
  backends, the gate-issue helper, the consideration schema, the goal-contract shape, matrix
  analysis, the schema check, the merged review engine, and recirculator doc-sync.
- **`templates/`** — the per-project scaffold `/idc:init` copies into a governed repo
  (`WORKFLOW.md`, `WORKFLOW-config.yaml`, the 5-field `tracker-config.yaml`, and a lean
  `docs/workflow/` tree).

## Developing on this plugin

```bash
# live-test without installing — load the plugin for one session
claude --plugin-dir /path/to/idc-workflow

# reference integrity (namespacing, no personal paths, no dangling refs, release discipline)
bash scripts/lint-references.sh

# the functional verification suite (real round-trips, throwaway sandbox)
bash tests/smoke/run-all.sh
```

> `--plugin-dir` loads the working tree directly, bypassing Claude Code's version-keyed cache —
> the reliable way to test unreleased changes.

## Repository layout

```
.claude-plugin/   plugin.json (manifest) + marketplace.json (self-hosted marketplace)
agents/           8 agents — stage playbooks + implementer + finisher + review coordinator/agent
skills/           13 reusable procedures (runtime adapters, tracker, review engine, …)
commands/         9 slash commands (think|plan|build|recirculate|autorun|init|doctor|update|uninstall)
templates/        per-project scaffold copied by /idc:init
scripts/          lint-references.sh, release check, the filesystem tracker + stage helpers,
                  install-codex.sh, run-evals.sh
tests/smoke/      the v2 functional verification suite
docs/             mental-model, architecture, installing, PRD/specs/plans, developer notes, assets
llms.txt          agent-readable index of the whole plugin
```

## License

[MIT](LICENSE) © 2026 llamallamaredpajama

<p align="center">
  <br>
  <img src="https://img.shields.io/badge/%E2%97%89-guardrails%2C%20not%20train%20tracks-252427?style=flat-square&labelColor=9CA689" alt="guardrails, not train tracks">
  <br><br>
  <sub>Visual identity adapted from the industrial-chic aesthetic of <a href="https://www.coalhouse.co.uk">Coal House, Cardiff</a> — coal-black ink, sage, and coral, set in the Johnston/Gill lineage.</sub>
</p>
