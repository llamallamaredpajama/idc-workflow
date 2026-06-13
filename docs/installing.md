# Installing IDC

This guide covers installing the plugin on a machine, turning IDC on for a project, enabling
Codex support, and a second machine — then troubleshooting with `/idc:doctor`.

## Prerequisites

- **Claude Code** (the CLI this plugin runs in).
- **GitHub CLI** (`gh`), authenticated (`gh auth login`). For the GitHub Projects tracker
  backend you also need the `project` OAuth scope:
  ```
  gh auth refresh -h github.com -s project
  gh auth status      # confirm "Token scopes: ... project"
  ```
  (Or use the `filesystem` backend — a root `TRACKER.md`, zero external setup.)
- **`jq`** and **`python3`** — used by `/idc:init` and the shipped tracker/check helpers;
  usually preinstalled.

## 1. Install the plugin on a machine

From inside Claude Code:

```
/plugin marketplace add llamallamaredpajama/idc-workflow
/plugin install idc@idc-workflow
```

This repo hosts its own marketplace (`.claude-plugin/marketplace.json`). Installing puts the
plugin on the machine but does **not** activate IDC in any repo — it stays disabled at the
user level (the per-project scoping model).

## 2. Turn IDC on for a project

A never-initialized repo has no `/idc:*` commands yet — including `/idc:init` — so bootstrap
from your **terminal** first:

```
cd <your-repo>
claude plugin enable idc@idc-workflow --scope project
```

Start a **new** Claude Code session in the repo, then run `/idc:init`. It is idempotent
(anything present is reported `skipped-existing`) and:

1. **Scaffolds** `WORKFLOW.md` + `WORKFLOW-config.yaml` at the root and the lean
   `docs/workflow/` tree (`pillar-matrices/`, `code-reviews/`) + `tracker-config.yaml`,
   substituting `{{PROJECT_NAME}}`. It fills `WORKFLOW-config.yaml::domains` from a codebase
   scan and ships the tier-symbolic `model_routing` table.
2. **Provisions the tracker.** For the `github` backend it creates (or links) a GitHub
   Projects v2 board and provisions the **four** v2 fields — `Status`
   (`Blocked|Todo|In Progress|Done`), `Wave`, `Phase`, `Domain` — caching their node IDs in
   `tracker-config.yaml`. For the `filesystem` backend it initializes a root `TRACKER.md` and
   needs no board.
3. **Enables the plugin for this project** by merging
   `{"enabledPlugins": {"idc@idc-workflow": true}}` into `.claude/settings.json` (preserving
   your other settings). This is why IDC stays off in your other repos.
4. **Writes an install receipt** (`docs/workflow/install-receipt.yaml`) with SHA-256
   fingerprints of the files it stamped — the manifest that makes clean removal/upgrade
   possible (it distinguishes stamped scaffold files from your customizations).

Pass a project name to override the default: `/idc:init my-service`. Afterward run
`/idc:doctor` (read-only) to verify the install.

## 3. Enable Codex support

Codex (a non-Claude runtime) reads personal skills from `~/.agents/skills`. Run:

```
/idc:init --codex
```

This runs `scripts/install-codex.sh`, which converts `~/.agents/skills` into a real directory
that re-links your existing personal skills **and** links the IDC plugin skills (the single
Codex runtime adapter `idc-adapter-codex` plus the shared skills) to the installed plugin —
so Codex can run the IDC pipeline without the skills leaking into your other Claude projects.
Re-running refreshes the links; `bash "<plugin-root>/scripts/install-codex.sh" --revert`
restores the original state (the installer records the prior state first).

## 4. Set up a second machine

1. Install the plugin (step 1).
2. `git clone` and `cd` into each governed repo. Per-project enablement lives in the repo's
   `.claude/settings.json`; if your repo commits that file, IDC is already on. Otherwise run
   `claude plugin enable idc@idc-workflow --scope project` from the repo root. The scaffold +
   board need no re-init.
3. Ensure `gh` is authenticated with the `project` scope (github backend).
4. If you use Codex, run `/idc:init --codex` there once (the link wiring is machine-local).
5. Run `/idc:doctor` to confirm everything resolves.

## Troubleshooting with `/idc:doctor`

`/idc:doctor` is read-only and reports each check as `PASS` / `FAIL` / `SKIP` with a fix hint:

| Check | If it FAILs |
|-------|-------------|
| Plugin enabled for this project | Run `/idc:init`, or add `{"enabledPlugins":{"idc@idc-workflow":true}}` to `.claude/settings.json`. |
| `gh` authenticated with `project` scope | `gh auth login`, then `gh auth refresh -h github.com -s project`. |
| Tracker contract present + reachable | Re-run `/idc:init`; check the `project` scope and `project_number`. For the filesystem backend, ensure `TRACKER.md` exists. |
| Governance scaffold present | Re-run `/idc:init` to scaffold `WORKFLOW.md` + the `docs/workflow/` tree. |
| Install receipt present | `SKIP` (pre-receipt repo is valid) or re-run `/idc:init` to write one. |

Common issues:

- **No `/idc:*` command exists at all** — the plugin isn't enabled for this project and is
  disabled at the user level. Repair from the terminal:
  `claude plugin enable idc@idc-workflow --scope project`, then start a new session.
- **"board not reachable" / field IDs empty** — the `project` scope is usually missing;
  refresh it and re-run `/idc:init`.
- **A non-IDC repo is picking up IDC** — remove the `idc@idc-workflow` enablement key from
  that repo's `.claude/settings.json`.
