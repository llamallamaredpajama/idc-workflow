---
description: IDC health check — verify plugin scoping (no global leak), gh auth + project scope, the 4-field tracker board, and the v2 scaffold (read-only)
argument-hint: (no arguments)
---

`/idc:doctor` diagnoses whether the current repository is correctly set up for IDC v2. **It
is strictly read-only** — it never creates, edits, or deletes a file, and never mutates
`gh`/board state. Run every check below from the governed repo root, then print ONE results
table with `PASS`/`FAIL`/`SKIP` and a one-line fix hint per row, ending with a one-line
verdict. Make NO changes. See `WORKFLOW.md §3`.

## Checks

**1 — Plugin scoped to this repo (no global leak).** IDC must be enabled at **project** scope
(this repo only), never at the **user** scope (every repo on the machine). Read this repo's
`.claude/settings.json` + `.claude/settings.local.json` (missing is fine) for the per-repo
opt-in, and `~/.claude/settings.json` for the global switch:
```bash
cat .claude/settings.json .claude/settings.local.json 2>/dev/null \
  | jq -s 'add // {} | .enabledPlugins."idc@idc-workflow" == true'   # true = opted in HERE
jq -r '.enabledPlugins."idc@idc-workflow" // "absent"' ~/.claude/settings.json 2>/dev/null
```
- **FAIL (global leak)** if the user-scope read is `true` — IDC is active in *every* repo on
  the machine. Fix: turn off the global switch (repos that want IDC keep their own project
  key): `claude plugin disable idc@idc-workflow --scope user`.
- **PASS** if the user-scope read is not `true` and the project/local read is `true` (IDC is
  correctly pinned to this repo).
- **SKIP** (not PASS) if neither the user-scope read is `true` nor the project/local read is
  `true`, yet this command is running — IDC is active via an opaque managed/`--plugin-dir`
  override, so a proper per-repo opt-in can't be proven. Note the override and pin it for a real
  install: `claude plugin install idc@idc-workflow --scope project` (or run `/idc:init`). A
  genuinely disabled state can't reach this command; reserve **PASS** strictly for the explicit
  project-scope case above.

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

**6 — Pi runtime (optional).** The IDC Pi runtime (`runtime/pi/`, vendored) needs **Bun** to
boot the coms-net hub + role harness; the **Pi agent** itself (the `pi` binary / npm package
`@earendil-works/pi-coding-agent`, historically `@mariozechner/pi-*`) is a separate
install-time dependency. This check is **read-only** — it shells out to the plugin's dry-run
probe, which detects Bun + Pi presence/version and mutates nothing:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-pi.sh" --check
```
Read the report rows (Bun / Pi agent / runtime/pi):
- **Pi agent ABSENT** → **SKIP** (note "Pi runtime not installed — optional"). The Pi runtime
  is opt-in; a repo driven by the Claude/Codex runtimes is valid and must not FAIL here.
- **Pi agent PRESENT** and the probe exits `0` (Bun present + vendored runtime OK) → **PASS**
  (note the reported Bun + Pi versions).
- Probe exits non-zero — **fail-closed FAIL**: a hard prerequisite is missing (Bun absent, or
  `runtime/pi/` incomplete) so the Pi runtime cannot boot. Fix hint: install Bun
  (https://bun.sh) or re-pull the plugin to restore `runtime/pi/`.

## Output

Emit a single table, then a one-line verdict. Tally PASS / FAIL / SKIP across the six rows:

```
| # | Check | Result | Fix hint |
|---|---|---|---|
| 1 | Plugin scoped to this repo | PASS | — |
| 2 | gh + project scope | PASS | — |
| 3 | Tracker contract reachable | PASS | — |
| 4 | Governance scaffold | PASS | — |
| 5 | Install receipt | SKIP | run /idc:init to graduate a receipt |
| 6 | Pi runtime (optional) | SKIP | Pi runtime not installed — optional |

IDC doctor: N passed, M failed, K skipped
```
