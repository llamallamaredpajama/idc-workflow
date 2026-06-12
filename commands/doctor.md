---
description: IDC health check — verify plugin enablement, gh auth + project scope, tracker board, scaffold, and Codex links (read-only)
argument-hint: (no arguments)
---

You are running `/idc:doctor`. Diagnose whether the current repository is correctly set
up for the IDC workflow. **This command is strictly read-only — never create, edit, or
delete any file, and never mutate gh/board state.** Run each check below, then print one
results table where every row is `PASS`, `FAIL`, or `SKIP` with a one-line fix hint.

Run from the root of the governed repo (the directory that should contain `WORKFLOW.md`).

## Checks

### 1. Plugin enabled for this project
Read `.claude/settings.json` AND `.claude/settings.local.json` — either may carry the
key. PASS if `.enabledPlugins["idc@idc-workflow"]` is `true` in either file. If neither
carries it, the plugin may still be enabled at user scope: this command running at all
implies the plugin is loaded, so report `PASS (user-scope or local override)` rather
than FAIL when the project files lack the key but the plugin is demonstrably active.
FAIL hint (plugin genuinely off): `run /idc:init, or add
{"enabledPlugins":{"idc@idc-workflow":true}} to .claude/settings.json`.

### 2. gh authenticated with project scope
Run `gh auth status 2>&1`. PASS only if it shows a logged-in account AND the token scopes
include `project` (look for `project` in the "Token scopes" line). If logged in but the
`project` scope is absent → FAIL hint: `gh auth refresh -h github.com -s project`. If not
logged in at all → FAIL hint: `gh auth login`.

### 3. Tracker contract present + board reachable
Read `docs/workflow/tracker-config.yaml`.
- If missing → FAIL hint: `run /idc:init to scaffold docs/workflow/tracker-config.yaml`.
- If `backend: filesystem` → PASS if `TRACKER.md` exists at the repo root; else FAIL hint:
  `create TRACKER.md or run /idc:init`. (No board probe needed for the filesystem backend.)
- If `backend: github` → confirm `project_number` is a real integer (not a `{{...}}` token
  or null) AND probe the board read-only with
  `gh project view <project_number> --owner <owner> --format json` (derive `<owner>` from
  `gh repo view --json owner -q .owner.login`). PASS if the probe exits 0; else FAIL hint:
  `board not reachable — re-run /idc:init or check gh project scope / project_number`.
  Also note (do not fail) if any `field_ids` value is still empty — hint: `field_ids not
  cached; re-run /idc:init board provisioning`.

### 4. Governance scaffold present
PASS if `WORKFLOW.md` exists at the repo root AND `docs/workflow/` exists with its standard
subdirectories (`audits`, `code-reviews`, `diagrams`, `handoffs`, `ledgers`,
`operator-todos`, `phase-planning`, `pillar-conflicts`, `pillar-matrices`, `plans`,
`ripple`). FAIL hint names whichever is missing: `run /idc:init to scaffold WORKFLOW.md +
docs/workflow/`. A partial tree (some dirs present) is a FAIL listing the missing dirs.

### 5. Codex adapter links (only if Codex install was run)
Check whether `$HOME/.agents/.idc-install-state` exists.
- If it does NOT exist → `SKIP` with hint: `Codex adapters not installed (run /idc:init
  --codex to enable Codex)`.
- If it exists → confirm each of the five IDC Codex adapter links under
  `$HOME/.agents/skills/` resolves to a readable `SKILL.md` (i.e. the adapter directories
  reachable through that path each contain a `SKILL.md`). PASS if all five resolve; else
  FAIL hint: `re-run the Codex installer:
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" "${CLAUDE_PLUGIN_ROOT}"`.

## Output

Print a single table:

| # | Check | Result | Fix hint |
|---|-------|--------|----------|

End with a one-line verdict: `IDC doctor: N passed, M failed, K skipped`. If everything
that ran is `PASS`, say the repo is IDC-ready. Make no changes.
