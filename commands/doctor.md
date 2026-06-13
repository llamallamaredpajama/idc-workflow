---
description: IDC health check — verify plugin enablement, gh auth + project scope, the 4-field tracker board, and the v2 scaffold (read-only)
argument-hint: (no arguments)
---

`/idc:doctor` diagnoses whether the current repository is correctly set up for IDC v2. **It
is strictly read-only** — it never creates, edits, or deletes a file, and never mutates
`gh`/board state. Run every check below from the governed repo root, then print ONE results
table with `PASS`/`FAIL`/`SKIP` and a one-line fix hint per row, ending with a one-line
verdict. Make NO changes. See `WORKFLOW.md §3`.

## Checks

**1 — Plugin enabled.** Read `.claude/settings.json` and `.claude/settings.local.json` (a
missing file is fine). PASS if `.enabledPlugins["idc@idc-workflow"]` is `true` in either:
```bash
cat .claude/settings.json .claude/settings.local.json 2>/dev/null \
  | jq -s 'add // {} | .enabledPlugins."idc@idc-workflow" == true'
```
If neither file flags it but this command is running, the plugin is enabled at user scope or
by local override → still **PASS** (note "user-scope / local override"). Only a genuine
disabled state is FAIL. Fix hint: run `/idc:init`.

**2 — gh authenticated with `project` scope.** PASS only if logged in AND the token scopes
include `project`:
```bash
gh auth status 2>&1 | grep -q "Token scopes:.*'project'" && echo project-ok
```
FAIL hints: `gh auth refresh -h github.com -s project` (logged in, scope missing) or
`gh auth login` (not logged in).

**3 — Tracker contract present + reachable.** Read `docs/workflow/tracker-config.yaml`.
Missing → FAIL (hint: run `/idc:init`). Otherwise branch on `backend:`:
- `filesystem` → PASS if `TRACKER.md` exists at the repo root, else FAIL (hint: run
  `/idc:init`).
- `github` → `project_number` must be a real integer (not a `{{…}}` token), then probe the
  board read-only:
  ```bash
  owner=$(gh repo view --json owner -q .owner.login)
  num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
  gh project view "$num" --owner "$owner" --format json >/dev/null && echo board-ok
  ```
  PASS on exit 0; FAIL otherwise (hint: token still present → run `/idc:init`; board gone →
  re-provision via `/idc:init`). **Note (do not fail)** if any of the four `field_ids`
  (`Status`, `Wave`, `Phase`, `Domain`) is still empty — flag "field_ids incomplete".

**4 — Governance scaffold present.** PASS only if all of these exist: `WORKFLOW.md` at the
repo root, `WORKFLOW-config.yaml` at the repo root, and `docs/workflow/` containing exactly
its two v2 subdirectories `pillar-matrices` and `code-reviews`:
```bash
ls WORKFLOW.md WORKFLOW-config.yaml docs/workflow/pillar-matrices docs/workflow/code-reviews
```
A partial tree is a FAIL that lists the missing paths. Fix hint: run `/idc:init`.

**5 — Install receipt present.** PASS if `docs/workflow/install-receipt.yaml` exists and
parses with the expected keys (`receipt_version`, `fingerprint_method: sha256`, `files[]`):
```bash
test -f docs/workflow/install-receipt.yaml \
  && grep -Eq '^fingerprint_method:[[:space:]]*sha256' docs/workflow/install-receipt.yaml \
  && echo receipt-ok
```
If absent → **SKIP** with the note "pre-receipt install — run `/idc:init` to graduate a
receipt" (a filesystem-only or pre-receipt repo is valid; do not hard-FAIL). Do **not**
recompute or verify fingerprints here — that is update's job; doctor only checks presence
and parse.

## Output

Emit a single table, then a one-line verdict. Tally PASS / FAIL / SKIP across the five rows:

```
| # | Check | Result | Fix hint |
|---|---|---|---|
| 1 | Plugin enabled | PASS | — |
| 2 | gh + project scope | PASS | — |
| 3 | Tracker contract reachable | PASS | — |
| 4 | Governance scaffold | PASS | — |
| 5 | Install receipt | SKIP | run /idc:init to graduate a receipt |

IDC doctor: N passed, M failed, K skipped
```
