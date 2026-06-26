---
description: IDC health check — verify plugin scoping (no global leak), gh auth + project scope, the tracker board, the v2 scaffold, and plugin-cache freshness (read-only)
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
- **SKIP** (not PASS) if this command is running but neither read proves an explicit opt-in —
  no project/local key here, and the user switch isn't `true`. IDC is active via an opaque
  managed/`--plugin-dir` override, so per-repo scoping can't be proven. Pin a real install:
  `claude plugin install idc@idc-workflow --scope project` (or run `/idc:init`). A genuinely
  disabled state can't reach this command.

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
  re-provision via `/idc:init`). **Note (do not fail)** if any of the five `field_ids`
  (`Status`, `Stage`, `Wave`, `Phase`, `Domain`) is still empty — flag "field_ids
  incomplete". `Stage` is additive: a legacy board with no `Stage` field id is treated as
  `Buildable` elsewhere, so note its absence but never FAIL on it.

  **Note (do not fail) — repo link.** A v2 board is owned by the user/org and only appears on
  the repo's **Projects tab** + issue sidebar once linked; an unlinked board is still fully
  workable by `owner + number`, so this is a heads-up, never a FAIL. Probe repo-rooted (reuses
  `$owner` / `$num` from above):
  ```bash
  repo=$(gh repo view --json name -q .name)
  linked=$(gh api graphql -f query='query($o:String!,$r:String!){repository(owner:$o,name:$r){projectsV2(first:100){nodes{number}}}}' \
    -f o="$owner" -f r="$repo" --jq '.data.repository.projectsV2.nodes[].number' 2>/dev/null)
  printf '%s\n' "$linked" | grep -qx "$num" && echo board-linked || echo board-not-linked
  ```
  - `board-linked` → no note.
  - `board-not-linked` → **PASS with ⚠**, note: "board not linked to this repo — it won't appear
    on the repo's Projects tab; run `/idc:init` to link it (or `gh project link <num> --owner
    <owner> --repo <owner>/<repo>`)."
  - GraphQL call itself errors (transient / auth) → could-not-determine note, **never FAIL**.

**4 — Governance scaffold present.** PASS only if all of these exist: `WORKFLOW.md` at the
repo root, `WORKFLOW-config.yaml` at the repo root, and `docs/workflow/` containing (at
least) its two v2 subdirectories `pillar-matrices` and `code-reviews`:
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

**7 — Codex skill-mirror in sync (optional).** The optional Codex runtime mirror
(`scripts/install-codex.sh`) turns `~/.agents/skills` into a real directory of symlinks — one per
`$HOME/.claude/skills` entry plus the IDC adapters. A skill deleted since the last install leaves a
**dangling** mirror link, and a skill added since leaves a **missing** one, until the installer is
re-run. This check is **read-only** — it only inspects symlinks, mutating nothing. Gate on the
install-state file, then look for drift:
```bash
if [ ! -f "$HOME/.agents/.idc-install-state" ]; then echo "mirror-absent"; else
  # dangling: a mirror symlink whose target no longer resolves (e.g. a since-deleted skill)
  for l in "$HOME/.agents/skills"/*; do [ -L "$l" ] && [ ! -e "$l" ] && echo "dangling: $(basename "$l")"; done
  # missing: a $HOME/.claude/skills entry with no mirror link yet
  for d in "$HOME/.claude/skills"/*/; do n=$(basename "$d"); [ -d "$d" ] && { [ -L "$HOME/.agents/skills/$n" ] || echo "missing: $n"; }; done
  # load-bearing: the Codex adapter link must resolve to a SKILL.md
  [ -f "$HOME/.agents/skills/idc-adapter-codex/SKILL.md" ] || echo "adapter-broken"
fi
```
- **SKIP** — `mirror-absent` (no install-state file): the Codex mirror is not installed (an
  optional runtime). A Claude/Codex-without-mirror repo is valid; never FAIL here.
- **PASS** — state file present and no `dangling:` / `missing:` / `adapter-broken` lines: the mirror
  matches `$HOME/.claude/skills` + the adapters.
- **PASS with ⚠** — only `dangling:` / `missing:` lines (the Codex adapter still resolves): stale
  mirror cruft Codex ignores, not a boot blocker. Note the drifted names. Fix hint: re-sync (the
  re-run prunes its own stale links) — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-codex.sh"
  "${CLAUDE_PLUGIN_ROOT}"`.
- **FAIL** — `adapter-broken`: the mirror is installed but the load-bearing Codex adapter link
  (`~/.agents/skills/idc-adapter-codex`) does not resolve, so IDC will not load under Codex. Same
  fix: re-run the installer above.

**8 — Plugin cache freshness (advisory; never FAIL).** The code `/idc:*` runs from Claude
Code's **version-keyed cache** (`${CLAUDE_PLUGIN_ROOT}`), rebuilt **only when `plugin.json`'s
`version` changes** — so a `claude plugin marketplace update` that pulled new commits under an
unchanged version leaves the session running **stale cached code**. Surface the running version
and compare it best-effort, read-only, to the marketplace clone:
```bash
ver() { grep -E '"version"' "$1" 2>/dev/null | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'; }
run_ver=$(ver "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
clone_ver=$(ver "$HOME/.claude/plugins/marketplaces/idc-workflow/.claude-plugin/plugin.json")
echo "running ${run_ver:-unknown}; marketplace ${clone_ver:-absent}"
```
- **PASS** — `run_ver` is readable and the clone is `absent` or equals it. Note the running
  version, e.g. "running 2.1.0".
- **PASS with ⚠** — clone version differs from the running version: the cache is **stale**. Fix
  hint: `claude plugin update idc@idc-workflow --scope project`, then re-enable (or restart the
  session) to rebuild the cache. (Still counts as PASS — a stale cache is a heads-up, not a
  broken repo.)
- **SKIP** — `run_ver` unreadable (a managed / `--plugin-dir` load with no manifest on the cache
  path). This row is **advisory and is never FAIL.**

**9 — Build-lane hygiene (advisory; never FAIL).** Build and Autorun consume the board on
*trust*: the mechanical issue-body schema check (`scripts/idc_schema_check.py`) runs only **inside
Plan, once, at issue creation**. An issue that bypassed Plan — hand-filed, or a captured
review-residual — can sit build-eligible (`Status = Todo`, `Stage = Buildable`) while **malformed**
(fails the schema check) and/or carrying a **prose-only dependency** ("blocked on X" in the body
with no native *blocked-by* link), and Autorun's drain (which keys on native `blocked_by` only)
would claim and execute it cold. This row re-runs the existing schema check over that lane and
flags prose dependencies with no recorded link. It is a **read-only `⚠` heads-up — never a hard
FAIL** (Build still trusts the board; the schema check stays Plan's gate). Branch on
`docs/workflow/tracker-config.yaml::backend`:

- **`filesystem` → SKIP**, note: "filesystem board carries no issue bodies — the body-schema /
  prose-dependency re-scan is github-only; the schema check runs at Plan authoring."
- **`github` → run the lint** (read-only). List the Buildable+Todo lane, emit one JSONL object per
  issue, and pipe to the shipped helper:
  ```bash
  num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
  owner=$(gh repo view --json owner -q .owner.login)
  # Build-eligible lane (canonical predicate: scripts/idc_autorun_drain.py): Status=Todo +
  # Stage=Buildable (legacy null → Buildable). The [operator-action] skip is applied downstream
  # in the helper; the drain's "all blocked-by Done" clause is intentionally not this row's concern.
  # Pipe the number list straight into `while read`, never a for-loop over an unquoted capture: an
  # unquoted newline blob is NOT word-split under zsh — the real /idc:doctor Bash-tool shell — so a
  # for-loop would run once over the whole blob and falsely report "clean". `while read` iterates
  # per line in both bash and zsh.
  gh project item-list "$num" --owner "$owner" --format json --jq \
    '.items[] | select(.status=="Todo") | select((.stage // "Buildable")=="Buildable") | .content.number' \
  | while IFS= read -r n; do
      [ -n "$n" ] || continue
      bb=$(gh api "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" --jq '[.[].number]' 2>/dev/null) || bb=''
      [ -n "$bb" ] || bb='null'   # empty stdout = the API call FAILED → UNKNOWN (not "no link"); a real no-dep result is the 200 '[]'. Tri-state lets the helper never false-flag a prose dep it couldn't disprove.
      gh issue view "$n" --json number,title,body --jq "{number:.number,title:.title,body:.body,blocked_by:$bb}"
    done | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_board_lint.py"
  ```
  (`dependencies/blocked_by` GET is the read counterpart of the documented write endpoint;
  `gh issue view --jq` emits control-char-safe escaped JSON, so no external `jq` slurp is needed.)
  - `board-lint: clean …` → **PASS** (note "N scanned, clean").
  - findings → **PASS with ⚠**: list the flagged issue numbers + counts; fix hint: "re-run the
    item through `/idc:plan`, or record the missing native blocked-by link (`gh … link … blocks`)."
  - summary contains `dependency lookups indeterminate` → annotate the row **PASS with ⚠** (still
    **PASS, never FAIL**), independent of clean/flagged: note "the GitHub dependencies API looked
    degraded — the native blocked-by lookup failed for N issue(s), so prose-dependency detection
    was skipped for them; re-run `/idc:doctor` once the API recovers." (Guards against a board-wide
    outage turning every issue UNKNOWN → nothing flagged → a `clean` summary masquerading as a true
    all-clear.)
  - helper exit 2 or a `gh` error → **SKIP** ("could not determine"), **never FAIL**.

Row 9 only *reads* the board (`gh project item-list`, `gh issue view`, `gh api … GET`), preserving
doctor's strictly-read-only contract (guarded by `phase7-command-prose-invariants.sh`).

## Output

Emit a single table, then a one-line verdict. Tally PASS / FAIL / SKIP across the nine rows (rows
8 and 9 — plugin cache freshness and build-lane hygiene — are **advisory**: each is only ever PASS
or SKIP, never FAIL):

```
| # | Check | Result | Fix hint |
|---|---|---|---|
| 1 | Plugin scoped to this repo | PASS | — |
| 2 | gh + project scope | PASS | — |
| 3 | Tracker contract reachable | PASS | — |
| 4 | Governance scaffold | PASS | — |
| 5 | Install receipt | SKIP | run /idc:init to graduate a receipt |
| 6 | Pi runtime (optional) | SKIP | Pi runtime not installed — optional |
| 7 | Codex skill-mirror (optional) | SKIP | Codex mirror not installed — optional |
| 8 | Plugin cache freshness | PASS | running 2.1.0 |
| 9 | Build-lane hygiene (advisory) | PASS | 4 scanned, clean |

IDC doctor: N passed, M failed, K skipped
```
