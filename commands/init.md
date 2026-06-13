---
description: IDC Init — scaffold a repo for the v2 IDC pipeline (WORKFLOW.md, config with codebase-derived domains, 4-field board, install receipts)
argument-hint: "[PROJECT_NAME] [--codex]"
---

You are running `/idc:init`. Install the IDC v2 workflow into the **current repository**:
scaffold the governance contract from the plugin templates, derive the repo's standing
domains, provision (or link) a GitHub Projects v2 board matching the **four-field** v2
contract, enable the plugin for the project, write an install receipt, and — with
`--codex` — wire the Codex adapter.

**Idempotent.** Anything already present is left untouched and reported `skipped-existing`;
never overwrite an operator's `WORKFLOW.md`, `WORKFLOW-config.yaml`, `docs/workflow/`, or
`tracker-config.yaml`. The board contract + destructive single-select caveat live in
`idc:idc-tracker-github`; the templates you copy from are under
`${CLAUDE_PLUGIN_ROOT}/templates/`. Work the phases in order, from the target repo root.

## Phase 0 — Preconditions
1. Confirm the cwd is a git repo (`git rev-parse --show-toplevel`); else stop and tell the
   operator to `cd` in.
2. Decide the backend. Default `github`; if the operator wants zero setup, `filesystem`.
   For `github`, confirm `gh` is authenticated **with the `project` scope**
   (`gh auth status` lists `project`). If missing, stop and tell the operator to run
   `gh auth refresh -h github.com -s project`, then re-run. Do not mutate auth yourself.

## Phase 1 — Derive tokens + domains
- `PROJECT_NAME` — first non-flag word of `$ARGUMENTS`; default `basename "$(git rev-parse --show-toplevel)"`.
- `TRACKER_PROJECT_NUMBER` — set in Phase 4 (github backend only).
- **Domains** — scan the repo's source layout (top-level source dirs, language manifests,
  existing module boundaries) and derive 2–6 standing domains, each a short name + one-line
  brief + primary surfaces. These seed `WORKFLOW-config.yaml::domains` (Phase 3) and the
  board's `Domain` field options (Phase 4). Plan prunes/extends them per run; Ripple
  maintains them. Keep them coarse — a domain is a slice a domain-expert reviewer owns.

## Phase 2 — Detect-and-skip (idempotency)
Check each target independently, recording `created` / `skipped-existing`:
- `WORKFLOW.md`, `WORKFLOW-config.yaml` at repo root
- `docs/workflow/tracker-config.yaml`
- each entry of `${CLAUDE_PLUGIN_ROOT}/templates/docs-tree/` inside `docs/workflow/`,
  checked individually (a partial tree gets its missing entries filled, so `/idc:doctor`
  converges).
Anything present is left untouched.

## Phase 3 — Scaffold from templates
Run the deterministic scaffold helper. It copies the templates, substitutes
`{{PROJECT_NAME}}`, lays down the lean `docs/workflow/` tree (`pillar-matrices/`,
`code-reviews/`, README), selects the backend, and — for the `filesystem` backend —
initializes `TRACKER.md`. It is idempotent: it never clobbers an existing operator file.
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/idc_init_scaffold.sh" \
  "${CLAUDE_PLUGIN_ROOT}" "$(git rev-parse --show-toplevel)" "$PROJECT_NAME" <github|filesystem>
```
Then write the Phase-1 derived domains into `WORKFLOW-config.yaml::domains` (replace the
empty `domains: []` with the list, each `- name: / brief: / surfaces: [...]`).

For the **filesystem** backend the board is now ready (`TRACKER.md` initialized) — skip
Phase 4. For **github**, the `{{TRACKER_PROJECT_NUMBER}}` token stays until Phase 4 fills
it. (The helper does only the mechanical, testable scaffold; domain derivation, board
provisioning, and the receipt are this command's agent-driven phases.)

## Phase 4 — Provision (or link) the board (github backend)
Decide create-vs-link:
- `tracker-config.yaml` already carries a real integer `project_number` → **link**: reuse,
  verify reachable with `gh project view <n> --owner <owner>`.
- Else find an existing board titled `"<PROJECT_NAME> IDC Tracker"` via
  `gh project list --owner <owner> --format json --limit 200` (always pass `--limit`; the
  default 30 can silently truncate and create a duplicate). Otherwise **create**:
  ```bash
  gh project create --owner "$OWNER" --title "$PROJECT_NAME IDC Tracker" --format json
  ```
  Capture `number` (→ `TRACKER_PROJECT_NUMBER`) and the node `id`/`url`. Derive
  `OWNER=$(gh repo view --json owner -q .owner.login)`.

Provision the **four** v2 fields. A new Projects v2 board ships a built-in single-select
`Status` — **reconcile** it (don't duplicate); create the other three. Single-selects need
≥1 option at creation:

| Field | Type | Options |
|-------|------|---------|
| `Status` | SINGLE_SELECT (reconcile built-in) | `Blocked`, `Todo`, `In Progress`, `Done` |
| `Wave` | SINGLE_SELECT (create) | seed `Wave 1` |
| `Phase` | SINGLE_SELECT (create) | seed `Phase 1` |
| `Domain` | SINGLE_SELECT (create) | seed with the Phase-1 derived domain names |

```bash
gh project field-create <n> --owner "$OWNER" --name "Wave"   --data-type SINGLE_SELECT --single-select-options "Wave 1"
gh project field-create <n> --owner "$OWNER" --name "Phase"  --data-type SINGLE_SELECT --single-select-options "Phase 1"
gh project field-create <n> --owner "$OWNER" --name "Domain" --data-type SINGLE_SELECT --single-select-options "<domain1>,<domain2>,..."
```
Reconcile the built-in `Status` to the four v2 values — **gated by board provenance** (the
option-replacement mutation is destructive: it re-IDs every option and wipes item values;
see `idc:idc-tracker-github`). Get the `Status` field node id + current options from
`gh project field-list <n> --owner "$OWNER" --format json --limit 50`, then take exactly one:
- **Board created this run** → safe: replace the option set with the full desired list
  (`Blocked`, `Todo`, `In Progress`, `Done`) via the `updateProjectV2Field` GraphQL mutation.
- **Linked board, options already exactly those four** → no-op (`skipped-existing`); never
  re-send (same-name replacement still re-IDs + wipes).
- **Linked board, any other option set** → check item count
  (`gh project view <n> --owner "$OWNER" --format json` → `.items.totalCount`); zero → safe,
  proceed; ≥1 → **STOP**, leave untouched, record an operator action pointing at the
  snapshot→mutate→rebuild SOP in `idc:idc-tracker-github`.
If the built-in field cannot be updated by your gh version, do not delete it (the API
forbids deleting the built-in `Status`); record an operator action to set the four options
in the web UI.

Cache the contract: substitute the project number, then write each field's node `id` into
`tracker-config.yaml::field_ids` (`Status`, `Wave`, `Phase`, `Domain`) with precise edits
so the inline comments survive:
```bash
sed -i '' -e "s|\"{{TRACKER_PROJECT_NUMBER}}\"|$TRACKER_PROJECT_NUMBER|g" docs/workflow/tracker-config.yaml
gh project field-list <n> --owner "$OWNER" --format json --limit 50   # → field node ids
```

## Phase 5 — Enable the plugin for this project
Merge the enablement key into `.claude/settings.json`, preserving every existing key, via
the shipped safe-write helper (same-directory temp file + atomic replace):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_settings_json.py" \
  enable .claude/settings.json idc@idc-workflow
```
If the settings file contains invalid JSON, stop and report the parse error; never replace,
truncate, or drop existing settings. `.claude/settings.json` remains operator-owned — IDC
manages only the `enabledPlugins["idc@idc-workflow"]` key.

## Phase 6 — Codex adapter (only with `--codex`)
If `$ARGUMENTS` contains `--codex`, wire the single v2 Codex runtime adapter:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh" "${CLAUDE_PLUGIN_ROOT}"
```

## Phase 7 — Write the install receipt
After Phases 2–6 complete successfully, write `docs/workflow/install-receipt.yaml` — the
manifest that `/idc:doctor` checks and a future uninstall/update consumes. Fully
init-generated; never add a receipt to `templates/`, never invent fingerprints. Fingerprints
are the SHA-256 hex of each file's final on-disk bytes (after token substitution):

```yaml
receipt_version: 1
fingerprint_method: sha256
written_by: idc:init
files:
  - path: WORKFLOW.md
    fingerprint: <64-lowercase-hex>
    state: stamped
```
Rules: entry keys exactly `path`/`fingerprint`/`state`; sort by path; compute with
`shasum -a 256` (macOS) or `sha256sum` (Linux); init entries are always `state: stamped`
(`idc:update` may later record `state: customized` for files the operator kept at its
diff-and-ask); the receipt never lists itself, `TRACKER.md` (runtime footprint), or `.claude/settings.json`
(operator-owned; IDC manages only one enablement key and never fingerprints the whole file).
On a gap-fill re-run, preserve existing entries byte-for-byte and append only newly-created
files; if nothing was created, leave it and report `skipped-existing`.

## Phase 8 — Summary
Print a table of every target (`created` / `skipped-existing`), the receipt status, the
board number + URL (github) or `TRACKER.md` (filesystem), and whether the Codex adapter was
installed. End by suggesting `/idc:doctor`, and — if any scope/probe was skipped — name
exactly what remains.

| Item | Status |
|------|--------|
