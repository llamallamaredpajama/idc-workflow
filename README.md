# IDC Workflow

A [Claude Code](https://claude.com/claude-code) plugin that packages **IDC** — the
Iterative Development Chain — a governed, tracker-driven, multi-agent workflow for taking
software work from a raw idea all the way to merged, reviewed code.

> **WORK IN PROGRESS — pre-v0.1.0.** Migrated from a local Claude Code install into a
> standalone, installable plugin. Interfaces may still change.

## What IDC is

IDC breaks development into five roles that run as a chain. Each role is the **sole writer**
of its own surface, so no role can quietly overwrite another's work:

```
Think  →  Plan  →  Sequence  →  Build        (Ripple handles drift at any step)
```

| Role | What it does | What it writes |
|------|--------------|----------------|
| **Think** | Turns raw ideas, prompts, and source material into concise "considerations". | `docs/considerations/` |
| **Plan** | Turns admitted considerations into the canonical plan: product requirements, architecture spec, master plan, sub-plans, and per-feature "pillar" plans. | `docs/prd/`, `docs/specs/`, `docs/plans/` |
| **Sequence** | Puts the planned work in order on a tracker board (which feature goes in which wave). | the tracker (ordering only) |
| **Build** | Implements the next ready item against its plan, test-first, and opens a PR. | source code, tests, PRs |
| **Ripple** | When reality diverges from the plan, files a change order and synchronizes the docs. | `docs/workflow/ripple/` |

The point of the chain is **traceability**: every line of code traces back through a pillar
plan, a master plan, an architecture spec, and a product requirement. Nothing gets built
that the plan didn't ask for, and nothing in the plan drifts silently out of sync.

## What this repository is

This repo is the plugin itself **and** its own marketplace. It ships:

- **8 commands** — the role entry points (`/idc:think`, `/idc:plan`, …) plus `/idc:init`
  and `/idc:doctor`.
- **23 agents** — the role orchestrators and the specialized teammates they spawn.
- **38 skills** — the reusable procedures the roles compose (tracker operations, plan
  review, change-order authoring, …), including Codex-native adapters.
- **`templates/`** — the per-project scaffold `/idc:init` copies into a governed repo.

## Install on a machine

From inside Claude Code:

```
/plugin marketplace add llamallamaredpajama/idc-workflow
/plugin install idc@idc-workflow
```

That makes the `idc` commands, agents, and skills available. (Installing does **not** turn
IDC on for every repo — see below.)

## Install into a project

The plugin ships disabled outside IDC projects, so a repo that has never been initialized
has no `/idc:*` commands yet — including `/idc:init` itself. Bootstrap from your terminal
first, then start a new Claude Code session in the repo:

```
cd <your-repo>
claude plugin enable idc@idc-workflow --scope project
```

Then, inside that new session, run:

```
/idc:init
```

`/idc:init` is idempotent (safe to re-run) and:

- scaffolds `WORKFLOW.md` (the governance contract), `WORKFLOW-config.yaml`, and a
  `docs/workflow/` tree from the plugin templates;
- provisions a **GitHub Projects v2 board** with the eight IDC tracker fields (or links an
  existing one), and records its field IDs in `docs/workflow/tracker-config.yaml`;
- enables the plugin **for this project only** by writing
  `{"enabledPlugins": {"idc@idc-workflow": true}}` into `.claude/settings.json`.

That last step is the key to keeping things clean: IDC turns on **per-project**, so your
non-IDC repositories never see the workflow. Run `/idc:doctor` afterward to verify the
install (it checks plugin enablement, `gh` auth + `project` scope, board reachability, the
scaffold, and Codex links — read-only).

A GitHub Projects board needs the `project` OAuth scope:

```
gh auth refresh -h github.com -s project
```

## Command surface

| Command | Role / purpose |
|---------|----------------|
| `/idc:think` | Turn raw ideas and source material into pre-canonical considerations. |
| `/idc:plan` | Convert admitted considerations into the canonical planning chain. |
| `/idc:sequence` | Admit polished pillar plans into tracker wave order (status/order only). |
| `/idc:build` | Implement the next admitted tracker item against its pillar plan. |
| `/idc:ripple` | File change orders and resolve drift across the canonical chain. |
| `/idc:autorun` | Run a consideration end-to-end through Plan → Sequence without pausing. |
| `/idc:init` | Install IDC into the current repo (scaffold + board + per-project enable). |
| `/idc:doctor` | Read-only health check of an IDC-governed repo. |

## Codex support

The five role adapters also run under **Codex** (a non-Claude runtime). Codex reads skills
from `~/.agents/skills`, so `/idc:init --codex` runs
[`scripts/install-codex.sh`](scripts/install-codex.sh), which wires the IDC Codex adapters
into the Codex skill view **without** polluting your other Claude projects. Re-running
refreshes the links; `scripts/install-codex.sh --revert` restores the original state.

## Developing on this plugin

```
# Live-test without installing: load the plugin for one session
claude --plugin-dir /path/to/idc-workflow

# Check reference integrity (namespacing, no personal paths, no dangling refs)
bash scripts/lint-references.sh

# Run the behavioral eval suite (19 evalsets) against a disposable IDC sandbox
bash scripts/run-evals.sh           # uses scripts/materialize-sandbox.sh
```

The eval suite — what it measures, how to run a single case, and how scoring works — is
documented in [`docs/dev/evals.md`](docs/dev/evals.md).

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the lint, validates the
two plugin manifests, smoke-renders the templates, and syntax-checks every shell script on
each push and pull request.

## Repository layout

```
.claude-plugin/      plugin.json (manifest) + marketplace.json (self-hosted marketplace)
agents/              23 role orchestrators + teammate roleplayers (+ references/)
skills/              38 reusable procedures (incl. codex-idc-* adapters, idc-workflow)
commands/            8 slash commands (think|plan|sequence|build|ripple|autorun|init|doctor)
templates/           per-project scaffold copied by /idc:init
scripts/             lint-references.sh, install-codex.sh, run-evals.sh, materialize-sandbox.sh
docs/                architecture, installing, and developer notes (docs/dev/)
evals/               evaluation suite
llms.txt             agent-readable index of the whole plugin
```

**Runtime assumption:** the orchestrator agents and slash commands are built for a
Claude Code environment with Claude Teams primitives (TeamCreate / SendMessage —
e.g. cmux); the skills and the Codex adapters do not require it.

See [`docs/architecture.md`](docs/architecture.md) for how the roles, agents, and skills
fit together, and [`docs/installing.md`](docs/installing.md) for detailed install and
troubleshooting steps.

## License

[MIT](LICENSE) © 2026 llamallamaredpajama
