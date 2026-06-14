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

## 1. Register the marketplace (once per machine)

This repo hosts its own marketplace (`.claude-plugin/marketplace.json`). Registering it does
**not** install or enable anything — it just makes the `idc` plugin available to install:

```
claude plugin marketplace add llamallamaredpajama/idc-workflow
```

## 2. Install IDC into a project (project scope — never global)

IDC is **opt-in per repo**: install it at **`project` scope** from inside each repo you want
governed. This puts the plugin's files on the machine (shared) but enables its `/idc:*`
commands for **this repo only** — it enables IDC in the repo's own `.claude/settings.json` and
registers it **disabled** (`false`) at the global `~/.claude/settings.json`, so it stays off
everywhere else:

```
cd <your-repo>
claude plugin install idc@idc-workflow --scope project
```

> **Why `--scope project`?** `claude plugin install` defaults to `--scope user`, which enables
> IDC in **every** repo on the machine — the leak you don't want. `--scope project` keeps it
> pinned here. Already installed at user scope from an older version? Seal the leak with
> `claude plugin disable idc@idc-workflow --scope user`; your project-scoped repos keep working.

Start a **new** Claude Code session in the repo (so the `/idc:*` commands load), then run
`/idc:init`. It is idempotent (anything present is reported `skipped-existing`) and:

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
   `{"enabledPlugins": {"idc@idc-workflow": true}}` into `.claude/settings.json` with the
   shipped safe-write helper (preserving every other setting; invalid JSON fails without
   truncation). This is why IDC stays off in your other repos.
4. **Writes an install receipt** (`docs/workflow/install-receipt.yaml`) with SHA-256
   fingerprints of the IDC-owned scaffold files it stamped — the manifest that makes clean
   removal/update possible (it distinguishes stamped scaffold files from your
   customizations). `.claude/settings.json` is operator-owned and is never fingerprinted as a
   stamped receipt entry; IDC manages only its enablement key.

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

1. Register the marketplace (step 1).
2. `git clone` and `cd` into each governed repo. Per-project enablement lives in the repo's
   `.claude/settings.json`; if your repo commits that operator-owned file, IDC is already on.
   Otherwise run `claude plugin install idc@idc-workflow --scope project` from the repo root.
   The scaffold + board need no re-init.
3. Ensure `gh` is authenticated with the `project` scope (github backend).
4. If you use Codex, run `/idc:init --codex` there once (the link wiring is machine-local).
5. Run `/idc:doctor` to confirm everything resolves.

## 5. Update IDC after a plugin update

When you update the installed plugin — run `claude plugin update idc@idc-workflow --scope project`
from each governed repo (the bare command defaults to `--scope user` and would update the global
copy, not your project-scoped install), or let your plugin manager pull a new version — the
scaffold already living in your repo doesn't change on its own.
Run `/idc:update` from the repo to refresh it:

- It reads the **install receipt** to tell pristine scaffold files (which it refreshes to the new
  version automatically) from files you've **customized** (which it shows you as a diff and asks
  before touching — your edits are never silently overwritten).
- It is **files-only and idempotent**: a repo already current reports `skipped-already-current`,
  and it **never mutates your GitHub board** — it only *reports* if the board's fields have drifted
  from what the new version expects, leaving any change to you.
- A pre-receipt repo (initialized before receipts existed) is asked about every scaffold file once,
  then graduated to a receipt so future updates are automatic.

If a newly-shipped `/idc:*` command doesn't appear right after an update, restart your Claude Code
session — that's a client-side plugin-cache refresh, not an update failure.

## 6. Uninstall IDC from a project

`/idc:uninstall` removes IDC's footprints from the repo — the inverse of `/idc:init`:

- It archives your work products (the `docs/workflow/` tree, `TRACKER.md`) to an untracked
  `idc-archive-<date>.tar.gz` at the repo root (the path is always printed), then removes the
  scaffold, configs, and the project's enablement key in **one revertable commit** — `git revert`
  that commit reinstates everything.
- It deletes **only what IDC created** (driven by the install receipt), asks before removing any
  file you customized, and is idempotent (a re-run reports `skipped-absent`).
- **GitHub is untouched by default.** Pass `--close-issues` to close (reversibly) the board's
  issues, or `--delete-board` to permanently delete the board (typed confirmation required); issue
  *deletion* is never offered.
- It does **not** touch machine-global state: to also remove the plugin from your machine run
  `claude plugin uninstall idc@idc-workflow`, and to undo Codex wiring run
  `scripts/install-codex.sh --revert`. The uninstall summary names both.

## Troubleshooting with `/idc:doctor`

`/idc:doctor` is read-only and reports each check as `PASS` / `FAIL` / `SKIP` with a fix hint:

| Check | If it FAILs |
|-------|-------------|
| Plugin scoped to this repo (no global leak) | Enabled at `user` scope? `claude plugin disable idc@idc-workflow --scope user`. Not enabled here? `claude plugin install idc@idc-workflow --scope project` (or `/idc:init`). |
| `gh` authenticated with `project` scope | `gh auth login`, then `gh auth refresh -h github.com -s project`. |
| Tracker contract present + reachable | Re-run `/idc:init`; check the `project` scope and `project_number`. For the filesystem backend, ensure `TRACKER.md` exists. |
| Governance scaffold present | Re-run `/idc:init` to scaffold `WORKFLOW.md` + the `docs/workflow/` tree. |
| Install receipt present | `SKIP` (pre-receipt repo is valid) or re-run `/idc:init` to write one. |

Common issues:

- **No `/idc:*` command exists at all** — IDC isn't enabled for this repo. Install it at
  project scope from the terminal: `claude plugin install idc@idc-workflow --scope project`,
  then start a new session.
- **"board not reachable" / field IDs empty** — the `project` scope is usually missing;
  refresh it and re-run `/idc:init`.
- **A non-IDC repo is picking up IDC** — IDC is enabled at the global `user` scope. Seal it
  with `claude plugin disable idc@idc-workflow --scope user` (repos that want IDC keep their
  own project key). If instead one specific repo committed the key, remove `idc@idc-workflow`
  from that repo's `.claude/settings.json`. `/idc:doctor`'s first check flags this state.
