# IDC Workflow

A [Claude Code](https://claude.com/claude-code) plugin that packages **IDC** — the
Iterative Development Cycle — a guardrail-framed, tracker-driven, goal-contract pipeline for
carrying software work from a raw idea to merged, reviewed code.

## What IDC v2 is

Cast an idea into the stream at `/idc:think`; the stream carries it to merged, tested code on
its own. The only time it stops to ask is when the product's **user-facing function** is
about to change.

```
Think  →  Plan  →  Build        (Ripple heals drift; Autorun drains the whole pipe)
```

IDC v2 is **guardrails, not train tracks** — it trusts the model and keeps only the
guardrails that catch real derailments. There are exactly five: the one PRD gate, matrix
deconfliction, real verification surfaces, ripple drift-healing, and one-way flow through the
glass wall (tracker issues). Everything else flows autonomously and automerges when green.

| Stage | Command | What it does | Writes |
|------|---------|--------------|--------|
| **Think** | `/idc:think` | Free-form brainstorm (zero teammates) → one function-first consideration. | `docs/considerations/` |
| **Plan** | `/idc:plan` | Consideration → goal-contract issues: domain experts, the five-layer doc chain (only the PRD gated), matrix deconfliction, board admission. | `docs/prd/`, `docs/specs/`, `docs/plans/`, matrices, issues |
| **Build** | `/idc:build` | Executes each issue's goal contract as a goal loop; the merged review engine reviews every PR; automerge on PASS. | source, tests, review reports, tracker status |
| **Ripple** | `/idc:ripple` | Heals doc/reality drift in one PR (PR body = change order); PRD changes take the gate. | every affected canonical doc |
| **Autorun** | `/idc:autorun` | One-shot full-pipe drainer; loopable via `/loop`. | — |

The **one gate**: when planning or ripple determines the PRD must change, affected issues
land `Blocked` behind a single approval issue (plain-terms summary + the PRD diff); you get a
push notification and approve from the GitHub web UI on your phone. Nothing else asks for
permission.

## What this repository ships

This repo is the plugin **and** its own marketplace:

- **9 commands** — `/idc:think`, `/idc:plan`, `/idc:build`, `/idc:ripple`, `/idc:autorun`,
  plus `/idc:init` (per-project scaffold), `/idc:doctor` (read-only health check), and the
  lifecycle pair `/idc:update` (refresh stamped files after a plugin update) and
  `/idc:uninstall` (remove IDC footprints in one revertable commit).
- **8 agents** — the per-stage orchestrator playbooks (plan, build, ripple, autorun), the
  durable-worker implementer and finisher, and the review coordinator + review agent.
- **13 skills** — the runtime adapters (Claude, Codex, Pi), the tracker adapter + its two
  backends, the gate-issue helper, the consideration schema, the goal-contract shape, matrix
  analysis, the schema check, the merged 13-dimension review engine, and ripple doc-sync.
- **`templates/`** — the per-project scaffold `/idc:init` copies into a governed repo
  (`WORKFLOW.md`, `WORKFLOW-config.yaml` with codebase-derived domains + tier-symbolic model
  routing, the 4-field `tracker-config.yaml`, and a lean `docs/workflow/` tree).

## Install

IDC is **opt-in per repo** — its `/idc:*` commands must never appear in a repo you didn't
choose. Claude Code installs a plugin's *files* machine-wide but decides where its commands
*activate* by an enablement **scope**, so the rule is: register the marketplace once, then
install at **`project` scope** inside each repo you want governed — never the default `user`
scope, which would turn IDC on in *every* repo on the machine.

```
# once per machine — register the marketplace (installs/enables nothing on its own)
claude plugin marketplace add llamallamaredpajama/idc-workflow

# per repo — install AND enable for THIS repo only
cd <your-repo>
claude plugin install idc@idc-workflow --scope project
```

`--scope project` writes the enablement into the repo's own `.claude/settings.json` and never
touches your global `~/.claude/settings.json`, so IDC stays invisible everywhere else. (Already
installed at the default `user` scope from an older version? Seal the leak with `claude plugin
disable idc@idc-workflow --scope user` — your project-scoped repos keep working.)

Start a **new** Claude Code session in the repo (so the commands load), then run `/idc:init`
(idempotent). It scaffolds the governance contract + config (filling `domains` from a codebase
scan), provisions a **4-field** GitHub Projects board (`Status` =
`Blocked|Todo|In Progress|Done`, `Wave`, `Phase`, `Domain`) or uses the zero-setup
`filesystem` backend, enables the plugin **for this project only**, and writes an install
receipt. Run `/idc:doctor` afterward to verify (read-only) — its first check fails loudly if
IDC is ever enabled at the global `user` scope. A GitHub board needs the `project` OAuth
scope: `gh auth refresh -h github.com -s project`.

## Runtime model

The process is written against three abstract primitives — durable worker, bounded fan-out,
goal loop — and one thin adapter per runtime maps them to mechanics. It runs on Claude Code
or **Codex** (`/idc:init --codex` wires the single Codex adapter into `~/.agents/skills`;
`scripts/install-codex.sh --revert` undoes it). Model selection is **tier-symbolic**
(`reasoning`/`standard`/`utility` in `WORKFLOW-config.yaml`, resolved by the adapter);
the Codex runtime runs untiered at highest effort.

## Developing on this plugin

```
# Live-test without installing: load the plugin for one session
claude --plugin-dir /path/to/idc-workflow

# Reference integrity (namespacing, no personal paths, no dangling refs)
bash scripts/lint-references.sh

# The functional verification suite (real round-trips, throwaway sandbox)
bash tests/smoke/run-all.sh
```

## Repository layout

```
.claude-plugin/   plugin.json (manifest) + marketplace.json (self-hosted marketplace)
agents/           6 stage orchestrators + implementer + review coordinator
skills/           12 reusable procedures (runtime adapters, tracker, review engine, …)
commands/         9 slash commands (think|plan|build|ripple|autorun|init|doctor|update|uninstall)
templates/        per-project scaffold copied by /idc:init
scripts/          lint-references.sh, the filesystem tracker + plan/review/ripple/autorun
                  helpers, install-codex.sh, run-evals.sh, materialize-sandbox.sh
tests/smoke/      the v2 functional verification suite
docs/             architecture, installing, PRD/specs/plans, developer notes
llms.txt          agent-readable index of the whole plugin
```

See [`docs/architecture.md`](docs/architecture.md) for how the pieces fit together, and
[`docs/installing.md`](docs/installing.md) for detailed install + troubleshooting.

## License

[MIT](LICENSE) © 2026 llamallamaredpajama
