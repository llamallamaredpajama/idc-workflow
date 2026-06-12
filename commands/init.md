---
description: IDC project installer — scaffold WORKFLOW + provision the tracker board + enable the plugin in a target repo (idempotent)
argument-hint: "[PROJECT_NAME] [--codex]"
---

You are running `/idc:init`. Install the IDC workflow into the **current repository**:
scaffold the governance contract from the plugin templates, provision (or link) a GitHub
Projects v2 tracker board that matches the IDC field contract, enable the plugin for the
project, and — with `--codex` — wire the Codex adapters.

**This command is idempotent.** Anything that already exists is left untouched and
reported as `skipped-existing`; never overwrite an operator's `WORKFLOW.md`,
`WORKFLOW-config.yaml`, `docs/workflow/`, or `tracker-config.yaml`.

Operator arguments: `$ARGUMENTS` — an optional project name and an optional `--codex` flag.

Read the board field/option contract before provisioning:
`idc:idc-skill-github-tracker-implementation` (the canonical eight-field schema and the
**destructive single-select mutation** caveat live there). The plugin templates you copy
from are under `${CLAUDE_PLUGIN_ROOT}/templates/`.

Work through the phases in order. Run from the target repo root (must be a git repo).

## Phase 0 — Preconditions
1. Confirm the cwd is a git repo (`git rev-parse --show-toplevel`); if not, stop and tell
   the operator to `cd` into the repo first.
2. Confirm `gh` is authenticated **with the `project` scope** (`gh auth status` must list
   `project` in its token scopes). Board provisioning needs it. If the scope is missing,
   stop and tell the operator to run `gh auth refresh -h github.com -s project`, then
   re-run `/idc:init`. Do not attempt to mutate auth yourself.

## Phase 1 — Derive the four tokens
- `PROJECT_NAME` — first non-flag word of `$ARGUMENTS`; default to the repo directory name
  (`basename "$(git rev-parse --show-toplevel)"`).
- `GITHUB_OWNER` / `GITHUB_REPO` — from
  `gh repo view --json owner,name -q '.owner.login + " " + .name'` (fall back to parsing
  `git remote get-url origin`).
- Determine the owner type once (`gh api "repos/$GITHUB_OWNER/$GITHUB_REPO" --jq .owner.type`
  → `User` or `Organization`; note `gh repo view --json owner` does NOT expose a `type`
  field) — `gh project` commands take `--owner <login>` for both, but you need the
  login for every board call.
- `TRACKER_PROJECT_NUMBER` — set in Phase 3 (created/linked board).

## Phase 2 — Detect-and-skip (idempotency)
Check each target independently and remember a `created` / `skipped-existing` status:
- `WORKFLOW.md` at repo root
- `WORKFLOW-config.yaml` at repo root
- `docs/workflow/tracker-config.yaml`
- each entry of `${CLAUDE_PLUGIN_ROOT}/templates/docs-tree/` inside `docs/workflow/`,
  **checked individually** — a partial tree (e.g. only 4 of the standard subdirs) gets
  its missing entries filled, so `/idc:doctor`'s "run `/idc:init`" fix hint always
  converges instead of looping on a skipped-existing directory
Anything already present is **left untouched**.

## Phase 3 — Scaffold from templates
For each target that Phase 2 marked absent, copy from `${CLAUDE_PLUGIN_ROOT}/templates/`:
- `templates/WORKFLOW.md` → `./WORKFLOW.md`
- `templates/WORKFLOW-config.yaml` → `./WORKFLOW-config.yaml`
- `templates/tracker-config.yaml` → `./docs/workflow/tracker-config.yaml`
  (`mkdir -p docs/workflow` first)
- each `templates/docs-tree/` entry absent from `./docs/workflow/` → copy it there
  (the standard dirs each keep their `.gitkeep`; `docs-tree/README.md` →
  `docs/workflow/README.md`); entries that already exist are never touched

Then substitute the tokens in the copied files (the board number is filled after Phase 4).
On macOS use `sed -i ''` (BSD); on Linux use `sed -i` (GNU):
```bash
for f in WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml; do
  [ -f "$f" ] && sed -i '' \
    -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
    -e "s|{{GITHUB_OWNER}}|$GITHUB_OWNER|g" \
    -e "s|{{GITHUB_REPO}}|$GITHUB_REPO|g" "$f"
done
```
The numeric project-number token is written quoted in the YAML templates
(`"{{TRACKER_PROJECT_NUMBER}}"`) and bare in `WORKFLOW.md` prose; Phase 4 substitutes
both forms — the **quoted** token in the YAML files becomes a bare integer
(`github_project_number: 7`, not `"7"`), and the **bare** token in `WORKFLOW.md`
becomes the same integer.

## Phase 4 — Provision (or link) the tracker board
Decide create-vs-link first:
- If `docs/workflow/tracker-config.yaml` already carries a real integer `project_number`
  (pre-existing install) → **link**: reuse it, skip creation, but still verify the board is
  reachable with `gh project view <n> --owner <owner>`.
- Else look for an existing board:
  `gh project list --owner <owner> --format json` — if one is titled
  `"<PROJECT_NAME> IDC Tracker"`, link to it. Otherwise **create** it:
  ```bash
  gh project create --owner "$GITHUB_OWNER" --title "$PROJECT_NAME IDC Tracker" --format json
  ```
  Capture `number` (→ `TRACKER_PROJECT_NUMBER`) and the project node `id`/`url`.

Provision the **eight canonical fields** to match the contract in
`idc:idc-skill-github-tracker-implementation`. New Projects v2 boards ship with a built-in
single-select `Status` field — **reconcile it** rather than creating a duplicate; the
other seven are created fresh. Single-select fields require at least one option at
creation; seed the open-ended ones minimally (more options are added later via the
destructive-mutation SOP in the skill — safe here because a fresh board has no items to
wipe).

| Field | Type | Options to set |
|-------|------|----------------|
| `Status` | SINGLE_SELECT (reconcile built-in) | `Pending`, `Active`, `Blocked`, `Complete` |
| `ClaimState` | SINGLE_SELECT (create) | `Unclaimed`, `Claimed`, `Running`, `RetryQueued`, `Released` |
| `Wave` | SINGLE_SELECT (create) | seed `Wave 0` |
| `Phase` | SINGLE_SELECT (create) | seed `Phase 0` |
| `Track` | SINGLE_SELECT (create) | seed `default` |
| `Lane` | SINGLE_SELECT (create) | seed `(idle)` |
| `Domain` | SINGLE_SELECT (create) | seed `default` |
| `Pillar trace key` | TEXT (create) | — |

Create the seven new fields:
```bash
gh project field-create <number> --owner "$GITHUB_OWNER" --name "ClaimState" \
  --data-type SINGLE_SELECT --single-select-options "Unclaimed,Claimed,Running,RetryQueued,Released"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Wave"   --data-type SINGLE_SELECT --single-select-options "Wave 0"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Phase"  --data-type SINGLE_SELECT --single-select-options "Phase 0"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Track"  --data-type SINGLE_SELECT --single-select-options "default"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Lane"   --data-type SINGLE_SELECT --single-select-options "(idle)"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Domain" --data-type SINGLE_SELECT --single-select-options "default"
gh project field-create <number> --owner "$GITHUB_OWNER" --name "Pillar trace key" --data-type TEXT
```
Reconcile the built-in `Status` field to the four IDC values. Get the project node id and
the `Status` field node id from `gh project field-list <number> --owner "$GITHUB_OWNER"
--format json`, then replace its option set with the destructive
`updateProjectV2Field(singleSelectOptions: [...])` GraphQL mutation (send the full desired
list — `Pending`, `Active`, `Blocked`, `Complete`). This is destructive by design but safe
on a brand-new empty board. If the built-in field cannot be updated in your gh version,
do NOT try to delete it — the built-in Projects v2 `Status` field cannot be deleted via
the API. Instead record an operator-todo: the operator sets the option list to exactly
`Pending`, `Active`, `Blocked`, `Complete` in the board's web UI (field settings).

Now cache the contract into the scaffolded files — substitute the project number in
all THREE places it appears (on macOS use `sed -i ''`; on Linux `sed -i`):
```bash
# quoted token in the YAML configs → bare integer (valid YAML)
sed -i '' -e "s|\"{{TRACKER_PROJECT_NUMBER}}\"|$TRACKER_PROJECT_NUMBER|g" \
  docs/workflow/tracker-config.yaml WORKFLOW-config.yaml
# bare token in the governance contract prose
sed -i '' -e "s|{{TRACKER_PROJECT_NUMBER}}|$TRACKER_PROJECT_NUMBER|g" WORKFLOW.md
```
Then:
- Re-run `gh project field-list <number> --owner "$GITHUB_OWNER" --format json` and write
  each field's node `id` into the matching `field_ids:` entry (use precise edits so the
  inline comments and the `"Pillar trace key"` quoting survive).
Option ids do not need caching — the runtime resolves them by name at call-time per the
skill.

## Phase 5 — Enable the plugin for this project
Merge the enablement key into the project-local `.claude/settings.json`, preserving every
existing key:
```bash
mkdir -p .claude
[ -f .claude/settings.json ] || echo '{}' > .claude/settings.json
tmp="$(mktemp)"
jq '.enabledPlugins["idc@idc-workflow"] = true' .claude/settings.json > "$tmp" && mv "$tmp" .claude/settings.json
```
If `jq` is unavailable, read the file and add the key with a precise edit instead — never
drop existing settings.

## Phase 6 — Codex adapters (only with `--codex`)
If `$ARGUMENTS` contains `--codex`, run the installer, passing the plugin root as an
argument (it is text-substituted here but is NOT a shell env var inside the script):
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" "${CLAUDE_PLUGIN_ROOT}"
```

## Phase 7 — Summary
Print a table of every target with `created` / `skipped-existing`, the board number + URL,
and whether Codex adapters were installed:

| Item | Status |
|------|--------|

End by suggesting the operator run `/idc:doctor` to verify the install, and — if the
`project` scope or board probe was skipped — name exactly what remains to finish.
