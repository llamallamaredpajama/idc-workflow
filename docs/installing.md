# Installing IDC

This guide covers six flows: installing the plugin on a machine, turning IDC on for a
project, enabling Codex support, updating an initialized project, uninstalling IDC from a
project, and setting up a second machine. It ends with troubleshooting via `/idc:doctor`.

## Prerequisites

- **Claude Code** (the CLI this plugin runs in).
- **GitHub CLI** (`gh`), authenticated: `gh auth login`. For the GitHub Projects tracker
  backend you also need the `project` OAuth scope:
  ```
  gh auth refresh -h github.com -s project
  gh auth status      # confirm "Token scopes: ... project"
  ```
- **`jq`** (used by `/idc:init` to merge plugin settings) — usually preinstalled; otherwise
  `brew install jq`.

## 1. Install the plugin on a machine

From inside Claude Code:

```
/plugin marketplace add llamallamaredpajama/idc-workflow
/plugin install idc@idc-workflow
```

This repo hosts its own marketplace (`.claude-plugin/marketplace.json`), so the first
command points Claude Code at it and the second installs the `idc` plugin. Installing puts
the plugin on the machine but does **not** activate IDC in any repo yet. In the
per-project scoping model the plugin stays **disabled** at the user level (check with
`claude plugin list`) — the `/idc:*` commands only exist inside projects that enable it,
which is what the next step does.

## 2. Turn IDC on for a project

A repo that has never been initialized has no `/idc:*` commands yet — including
`/idc:init` itself — so the first enablement has to happen from your **terminal**, not
from inside Claude Code:

```
cd <your-repo>
claude plugin enable idc@idc-workflow --scope project
```

This writes `{"enabledPlugins": {"idc@idc-workflow": true}}` into the repo's
`.claude/settings.json` (the same key `/idc:init` maintains). Then start a **new** Claude
Code session in that repo — existing sessions don't pick up enablement changes — and run:

```
/idc:init
```

What it does (idempotent — anything that already exists is left untouched and reported as
`skipped-existing`):

1. **Scaffold** — copies `WORKFLOW.md` and `WORKFLOW-config.yaml` to the repo root, and the
   `docs/workflow/` tree (`audits/`, `code-reviews/`, `handoffs/`, `ledgers/`,
   `operator-todos/`, `phase-planning/`, `pillar-conflicts/`, `pillar-matrices/`, `plans/`,
   `ripple/`, `diagrams/`) plus `docs/workflow/tracker-config.yaml`. The four template
   tokens (`PROJECT_NAME`, `GITHUB_OWNER`, `GITHUB_REPO`, `TRACKER_PROJECT_NUMBER`) are
   filled in from the repo and the board.
2. **Tracker board** — creates a GitHub Projects v2 board (or links an existing
   `"<name> IDC Tracker"`), provisions the eight IDC fields, and writes their node IDs into
   `docs/workflow/tracker-config.yaml`. Prefer the `filesystem` backend (a root
   `TRACKER.md`) if you don't want a GitHub Project — set `backend: filesystem` in
   `tracker-config.yaml` and skip the board.
3. **Per-project enablement** — merges `{"enabledPlugins": {"idc@idc-workflow": true}}` into
   `.claude/settings.json`, preserving your existing settings. This is why IDC stays off in
   your other repositories: enablement is per-project, not global.
4. **Install receipt** — writes `docs/workflow/install-receipt.yaml` with SHA-256
   fingerprints of files created by init. `/idc:update`, `/idc:upgrade`, and
   `/idc:uninstall` use this receipt to preserve operator customizations.

Pass a project name as the first argument to override the default (the repo directory
name): `/idc:init my-service`.

After it finishes, run `/idc:doctor` (below).

## 3. Enable Codex support

Codex (a non-Claude runtime) reads personal skills from `~/.agents/skills`, which normally
points at `~/.claude/skills`. Run:

```
/idc:init --codex
```

This runs `scripts/install-codex.sh`, which converts `~/.agents/skills` into a real
directory that re-links every existing personal skill **and** links the five IDC Codex
adapters to the installed plugin — so Codex can run the IDC roles without the adapters
leaking into your other Claude projects as bare skills.

- Re-running is safe — it refreshes the links and picks up any new personal skills.
- To undo it: `bash "<plugin-root>/scripts/install-codex.sh" --revert` restores the original
  `~/.agents/skills` symlink (the installer records the prior state before changing
  anything).

## 4. Update an initialized project

Run:

```
/idc:update
```

`/idc:update` refreshes stamped IDC scaffold files from the currently installed plugin.
It reads `docs/workflow/install-receipt.yaml`, compares SHA-256 fingerprints, and updates
only files still matching the receipt. If a file has a fingerprint mismatch, the command
prints a diff and requires operator review; there is no silent overwrite of customized
files. The refreshed receipt records `written_by: idc:update`, preserves
`state: customized` entries, and the command finishes with one revertable commit when it
actually changes files.

`/idc:upgrade` is kept as a compatibility alias for `/idc:update`; prefer
`/idc:update` in new docs and runbooks.

## 5. Uninstall IDC from a project

Run:

```
/idc:uninstall
```

`/idc:uninstall` removes repo-local IDC scaffold safely:

1. Verifies tracked files are clean and checks for in-flight tracker items. If the tracker
   read fails, it reports `could not verify in-flight items` and requires confirmation.
2. Builds a manifest from `docs/workflow/install-receipt.yaml` plus the hardcoded runtime
   footprint list (`WORKFLOW.md`, `WORKFLOW-config.yaml`, `docs/workflow/`, filesystem
   `TRACKER.md`, and the IDC enablement key in `.claude/settings.json`).
3. Archives existing manifest paths to `idc-archive-<date>.tar.gz` before deleting
   anything.
4. Removes files, strips only `.enabledPlugins["idc@idc-workflow"]`, and creates a single
   revertable commit.

GitHub is untouched by default. `--close-issues` closes board-linked issues but never
deletes them. `--delete-board` is permanent and requires typed confirmation of the board
title. Machine-global cleanup stays manual: run `claude plugin uninstall idc@idc-workflow`
and `bash "<plugin-root>/scripts/install-codex.sh" --revert` only if you also want to undo
machine-level plugin/Codex installation.

## 6. Set up a second machine

1. Install the plugin on the new machine (step 1).
2. `git clone` and `cd` into each governed repo. Per-project enablement lives in the repo's
   `.claude/settings.json`; if your repo commits that file, IDC is already on. Many repos
   gitignore `.claude/` — in that case run `claude plugin enable idc@idc-workflow
   --scope project` from the repo root on the new machine (the section 2 bootstrap; you
   can't re-run `/idc:init` while the plugin is disabled there). The scaffold and board
   need no re-init either way.
3. Make sure `gh` is authenticated with the `project` scope on the new machine.
4. If you use Codex on the new machine, run `/idc:init --codex` there once (the Codex link
   wiring is machine-local, not stored in the repo).
5. Run `/idc:doctor` to confirm everything resolves.

## Troubleshooting with `/idc:doctor`

`/idc:doctor` is read-only and reports each check as `PASS` / `FAIL` / `SKIP` with a fix
hint:

| Check | If it FAILs |
|-------|-------------|
| Plugin enabled for this project | Run `/idc:init`, or add `{"enabledPlugins":{"idc@idc-workflow":true}}` to `.claude/settings.json`. |
| `gh` authenticated with `project` scope | `gh auth login`, then `gh auth refresh -h github.com -s project`. |
| Tracker contract present + board reachable | Re-run `/idc:init`; check the `project` scope and the `project_number` in `tracker-config.yaml`. For the filesystem backend, ensure `TRACKER.md` exists. |
| Governance scaffold present | Re-run `/idc:init` to scaffold `WORKFLOW.md` + `docs/workflow/`. |
| Codex adapter links (if installed) | Re-run `bash "<plugin-root>/scripts/install-codex.sh" "<plugin-root>"`. Shown as `SKIP` if Codex was never installed. |

Common issues:

- **No `/idc:*` command exists at all (not even `/idc:doctor`)** — the plugin isn't
  enabled for this project and is disabled at the user level, so every fix-it command is
  itself unavailable. This can only be repaired from the terminal:
  `claude plugin enable idc@idc-workflow --scope project`, then start a new session.
- **"board not reachable" / field IDs empty** — the `project` scope is usually missing.
  Refresh it and re-run `/idc:init`; board provisioning needs the scope to create fields.
- **A non-IDC repo is picking up IDC** — check that repo's `.claude/settings.json`; remove
  the `idc@idc-workflow` enablement key if it was added by mistake.
- **Codex doesn't see a role adapter** — re-run the Codex installer; `/idc:doctor` confirms
  whether the five adapter links resolve.
