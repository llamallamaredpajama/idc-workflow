---
description: IDC health check — verify plugin scoping, gh/project access, tracker health, runtime, scaffold, and cache freshness
argument-hint: (no arguments)
---

`/idc:doctor` diagnoses whether the current repository is correctly set up for IDC v2. Its probes
are **read-only for source files and tracker/board state**. Lifecycle closeout writes only transient,
gitignored command evidence and may add its report glob to `.gitignore`. Run every check below from the governed repo root, then print ONE results
table with `PASS`/`FAIL`/`SKIP` and a one-line fix hint per row, ending with a one-line
verdict. Make no source or tracker changes. See `WORKFLOW.md §3`.

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
    on the repo's Projects tab; run `/idc:init` to link it through the validating tracker adapter."
  - GraphQL call itself errors (transient / auth) → could-not-determine note, **never FAIL**.

**4 — Governance scaffold present.** PASS only if all of these exist: `WORKFLOW.md` at the
repo root, `WORKFLOW-config.yaml` at the repo root, and `docs/workflow/` containing (at
least) its two v2 subdirectories `pillar-matrices` and `code-reviews`:
```bash
ls WORKFLOW.md WORKFLOW-config.yaml docs/workflow/pillar-matrices docs/workflow/code-reviews
```
A partial tree is a FAIL that lists the missing paths. Fix hint: run `/idc:init`.

**5 — Install receipt present.** PASS if `docs/workflow/install-receipt.yaml` exists and
parses with the expected keys (`receipt_version` — exactly `1` legacy or `2`, no other value,
`fingerprint_method: sha256`, `files[]`, and — for a `2` receipt — a valid `plugin_version`, the
version that last stamped this repo and the value `/idc:update`'s stale-runtime guard reads as
this repo's required version). A `2` receipt is **not clean** without a `plugin_version`
matching `X.Y.Z`, and a receipt whose `receipt_version` is anything other than `1` or `2`
(including absent or blank) is **not clean** either — the check below enforces both rules
rather than only checking `fingerprint_method`:
```bash
test -f docs/workflow/install-receipt.yaml \
  && grep -Eq '^fingerprint_method:[[:space:]]*sha256' docs/workflow/install-receipt.yaml \
  && grep -Eq '^receipt_version:[[:space:]]*(1|2)$' docs/workflow/install-receipt.yaml \
  && { ! grep -Eq '^receipt_version:[[:space:]]*2$' docs/workflow/install-receipt.yaml \
       || grep -Eq '^plugin_version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' docs/workflow/install-receipt.yaml; } \
  && echo receipt-ok
```
If absent → **SKIP** with the note "pre-receipt install — run `/idc:init` to graduate a
receipt" (a filesystem-only or pre-receipt repo is valid; do not hard-FAIL). A `receipt_version:
1` receipt (no `plugin_version`) still PASSes here — it has no recorded required-version yet
and is migrated to `2` the next time `/idc:init` or `/idc:update` stamps a fresh one; do not
treat it as drift. A `receipt_version: 2` receipt with a missing or malformed `plugin_version`,
or any receipt whose `receipt_version` is not `1` or `2` (including absent or blank) — anything
the check above does not print `receipt-ok` for — → **FAIL** with the note "invalid receipt —
receipt_version must be 1 or 2, and a `2` receipt requires a valid plugin_version; this is the
same invalid-receipt state `/idc:update`'s freshness guard refuses to run against (exit 2) —
repair or re-stamp it (`/idc:init` or `/idc:update`) before continuing." Do **not** recompute or
verify fingerprints here — that is update's job; doctor only checks presence and parse.

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

**8 — Runtime + plugin cache freshness.** First run `python3 --version`: Python **3.10 or newer** is
required; an older or missing runtime is **FAIL** with a plain upgrade/select-Python fix. Then check
the advisory cache freshness. The code `/idc:*` runs from Claude
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
  hint: `claude plugin update idc@idc-workflow --scope project`, then run `/reload-plugins` (or
  restart the session) to rebuild the cache. **`/clear` does not reload plugin commands or
  hooks** and will not fix this — it only clears conversation context. (Still counts as PASS — a
  stale cache is a heads-up, not a broken repo.)
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

- **`filesystem` → run the backend-neutral INDEX rules only** (read-only). The body-schema /
  prose-dependency re-scan stays skipped (the filesystem board carries no issue bodies — the schema
  check runs at Plan authoring), but the body-free index rules are backend-neutral and the strand
  classes they catch exist on filesystem too: `stranded-gate` / `unproven-gate-done` (a dependent
  still `Blocked` behind an `[operator-action]` gate already `Done` — the gate skill's dispose-first
  step 4 interrupted between the gate close and the unblock; tiered by whether the gate's guarded
  dispose is journaled) and `empty-status` (#255/#256). CAPTURE the producer's output first so a
  tracker-read FAILURE is detectable: `idc_tracker_fs.load` `die()`s (exit ≠ 0) on a MISSING or
  CORRUPT `TRACKER.md`, and piped straight into the lint that empty stdin prints a hollow
  `board-lint: clean (0 scanned)` (exit 0) that reads as PASS — a clean all-clear for a board that
  could not be inspected. Feed the tracker's structured records as INDEX-ONLY objects — the
  Buildable+Todo lane is EXCLUDED so nothing is ever body-schema-scanned (`scanned` stays 0; a Todo
  blocker is never `Done`, so its absence from the index keeps the stranded rule correctly silent) —
  and pass `--journal` so a Done gate is tiered proven-vs-unproven:
  ```bash
  fs_lint_in="$(mktemp)"
  if python3 - "${CLAUDE_PLUGIN_ROOT}/scripts" "$PWD/TRACKER.md" > "$fs_lint_in" <<'PY'
  import json, sys
  sys.path.insert(0, sys.argv[1])
  import idc_tracker_fs
  for it in idc_tracker_fs.load(sys.argv[2]).get("issues", []):
      if not isinstance(it, dict) or it.get("number") is None:
          continue
      stage, status = it.get("stage") or "Buildable", it.get("status") or "none"
      if stage == "Buildable" and status == "Todo":
          continue  # the body re-scan lane is github-only; never fed, so never schema-scanned
      obj = {"number": it["number"], "title": it.get("title") or "", "stage": stage, "status": status}
      if status == "Blocked":
          bb = it.get("blocked_by")
          obj["blocked_by"] = bb if isinstance(bb, list) else []
      print(json.dumps(obj))
  PY
  then
    python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_board_lint.py" \
      --journal "$PWD/docs/workflow/transition-journal.ndjson" < "$fs_lint_in"
  else
    # producer exited non-zero (missing/corrupt TRACKER.md) → emit an EXPLICIT SKIP marker so a
    # mechanical run classifies Row 9 as SKIP ("could not determine"), never the hollow
    # `clean (0 scanned)` an empty pipe would print. Capture + explicit exit check is portable in
    # both zsh and bash (no PIPESTATUS-vs-pipestatus divergence); this mirrors the github branch's
    # fail-closed posture below.
    echo "board-lint: SKIP — filesystem tracker unreadable (idc_tracker_fs.load exit ≠ 0); could not determine"
  fi
  rm -f "$fs_lint_in"
  ```
  - `board-lint: clean (0 scanned)` → **PASS** (note "index rules clean — the body re-scan is
    github-only"). A `stranded-gate` / `unproven-gate-done` / `empty-status` finding → **PASS with ⚠**
    with the same fix hints as the github branch below.
  - a `board-lint: SKIP — filesystem tracker unreadable …` line (the producer exited non-zero on a
    missing/corrupt `TRACKER.md`) → **SKIP** ("could not determine"), **never FAIL** and never the
    hollow `clean (0 scanned)` an empty pipe would print (no silent all-clear).
- **`github` → run the lint** (read-only). Emit one JSONL object per issue and pipe to the shipped
  helper: the Buildable+Todo lane as rich `{number,title,body,blocked_by}` objects (the scanned
  lane), **plus** the rest of the board as index-only `{number,stage,status}` objects so the
  retired-recirc rule can resolve a blocker to a Done Recirculation ticket:
  ```bash
  num=$(grep -E '^project_number:' docs/workflow/tracker-config.yaml | grep -oE '[0-9]+')
  owner=$(gh repo view --json owner -q .owner.login)
  # Build-eligible lane (canonical predicate: scripts/idc_autorun_drain.py): Status=Todo +
  # Stage=Buildable (legacy null → Buildable). The [operator-action] skip is applied downstream
  # in the helper; the drain's "all blocked-by Done" clause is intentionally not this row's concern.
  # Read the WHOLE board via the shared paginating reader — `gh project item-list` returns only its
  # 30-item first page (and --limit just moves the ceiling), so a grown board truncates and Row 9
  # under-scans the very lane it audits; idc_gh_board.py pages to completion and emits ASCII-escaped
  # JSON, so the downstream jq is control-char-safe.
  # CAPTURE the board first so a board-read FAILURE is detectable: piped straight into the lint, a
  # failed/empty read yields a hollow `board-lint: clean (0 scanned)` (exit 0) that reads as a PASS —
  # the silent-all-clear masking the exact outage this row should SKIP on. On a non-zero read, SKIP
  # (could not determine), never a clean PASS.
  # Pipe the number list straight into `while read`, never a for-loop over an unquoted capture: an
  # unquoted newline blob is NOT word-split under zsh — the real /idc:doctor Bash-tool shell — so a
  # for-loop would run once over the whole blob and falsely report "clean". `while read` iterates
  # per line in both bash and zsh.
  if ! board=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gh_board.py" --owner "$owner" --project "$num"); then
    # board unreadable (idc_gh_board exit ≠ 0) → emit an EXPLICIT SKIP marker so a mechanical run
    # classifies Row 9 as SKIP ("could not determine"), never the hollow `clean (0 scanned)` an empty
    # pipe would print. (A bare no-op here would emit nothing and still read as a silent all-clear.)
    echo "board-lint: SKIP — github board unreadable (idc_gh_board.py exit ≠ 0); could not determine"
  else
  {
    # (i) the build-eligible lane → rich {number,title,body,blocked_by} objects (the SCANNED lane).
    printf '%s\n' "$board" \
    | jq -r '.items[] | select(.status=="Todo") | select((.stage // "Buildable")=="Buildable") | select(.content.number != null) | .content.number' \
    | while IFS= read -r n; do
        [ -n "$n" ] || continue
        bb=$(gh api "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" --jq '[.[].number]' 2>/dev/null) || bb=''
        [ -n "$bb" ] || bb='null'   # empty stdout = the API call FAILED → UNKNOWN (not "no link"); a real no-dep result is the 200 '[]'. Tri-state lets the helper never false-flag a prose dep it couldn't disprove.
        gh issue view "$n" --json number,title,body --jq "{number:.number,title:.title,body:.body,blocked_by:$bb}"
      done
    # (ii) the REST of the board (except the Blocked lane, emitted richer in (iii)) → INDEX-ONLY
    #      {number,title,stage,status} objects, so the retired-recirc rule can resolve a blocker
    #      number → "Done Recirculation ticket" and the stranded-gate rule can recognise a blocker
    #      as a Done [operator-action] gate (title comes free from the captured $board). A SECOND jq
    #      over the already-captured $board (NOT a second board read); EXCLUDES the Buildable+Todo
    #      lane already emitted as rich objects in (i), so nothing is double-scanned (the helper's
    #      in_scan_lane() treats a stage≠Buildable / status≠Todo object as index-only — never
    #      schema-scanned/counted).
    printf '%s\n' "$board" \
    | jq -c '.items[] | select(.content.number != null)
             | select((.status=="Todo" and (.stage // "Buildable")=="Buildable") | not)
             | select((.status // "") != "Blocked")
             | {number: .content.number, title: (.content.title // ""), stage: (.stage // "Buildable"), status: (.status // "none")}'
    # (iii) the BLOCKED lane → index-only objects PLUS their native blocked_by (one dependencies
    #       call per Blocked item — the lane is small: gate dependents), so the stranded-gate rule
    #       can flag a dependent still Blocked behind a gate that is already Done (the gate skill's
    #       dispose-first step 4 interrupted between the gate close and the unblock). Same tri-state
    #       bb convention as (i): a failed lookup → null → the rule stays silent (never a false flag).
    printf '%s\n' "$board" \
    | jq -r '.items[] | select((.status // "") == "Blocked") | select(.content.number != null) | .content.number' \
    | while IFS= read -r n; do
        [ -n "$n" ] || continue
        bb=$(gh api "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by" --jq '[.[].number]' 2>/dev/null) || bb=''
        [ -n "$bb" ] || bb='null'
        printf '%s\n' "$board" \
        | jq -c --argjson n "$n" --argjson bb "$bb" '.items[] | select(.content.number == $n)
                 | {number: .content.number, title: (.content.title // ""), stage: (.stage // "Buildable"), status: "Blocked", blocked_by: $bb}'
      done
  } | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_board_lint.py" \
        --journal "$PWD/docs/workflow/transition-journal.ndjson"
  fi
  ```
  (`dependencies/blocked_by` GET is the read counterpart of the documented write endpoint;
  `gh issue view --jq` / `jq -c` both emit control-char-safe escaped JSON, so no external slurp is
  needed. The three passes share the one captured `$board` — the board is read exactly once.)
  - `board-lint: clean …` → **PASS** (note "N scanned, clean").
  - findings → **PASS with ⚠**: list the flagged issue numbers + counts; fix hint: "re-run the
    item through `/idc:plan`, or record the missing native blocked-by link (`gh … link … blocks`)."
    A `retired-recirc` finding means a paused issue is eligible only behind a **retired (Done)
    `Recirculation` ticket** (Plan's paused-issue re-link was skipped) — fix hint: "re-point it off
    the retired ticket onto its real new unblockers (re-run `/idc:plan` over the admitted scope)."
    A `stranded-gate` finding means a dependent is still **Blocked behind a gate that is already
    Done** AND one recognized proof **is journaled** (`guarded-dispose` or
    `verified-reconciliation`) — an interrupted proof-then-unblock — fix hint: "finish it through
    `idc_gate_repair.py --finish-pointer` (`idc:idc-gate-issue` step 4 recovery), never a raw
    setField." An `unproven-gate-done` finding means the gate is **Done but neither recognized proof
    is journaled** — a raw/manual close, a `Status` edit, or a janitor repair
    minted the `Done`, none of which validated the approval — fix hint: "do **not** auto-unblock.
    Confirm the proof kind with the one deterministic reader — `python3
    ${CLAUDE_PLUGIN_ROOT}/scripts/idc_gate_proof.py --repo "$PWD" --gate <gate#>` (`guarded-dispose`
    or `verified-reconciliation` = proven and safe to finish; `unproven` = not; **exit 2** = the
    journal is unreadable, which is *indeterminate*, never a clean negative). If it is genuinely
    `unproven`, confirm the gate was legitimately approved (its Think PR merged), then **reconcile it
    honestly** — `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_gate_repair.py --repo "$PWD" --owner
    <owner> --project <n> --gate <gate#> --pointer <dependent#> --pr <merged-think-PR>` (**dry run by
    default**; add `--apply` only after reading the plan). It verifies the PR really merged, stamps
    the gate's bound `idc-gate-pr` marker, repairs `Stage`/`Status` through the board helpers with the
    issue left closed, and journals an `op=gate-reconciliation` record carrying the observed-before
    state and the merged-PR evidence — after which the gate reads `verified-reconciliation`. It never
    back-dates an `op=dispose` (the guarded door did not run, and no record may claim it did) and
    never invents an `unblock` for a pointer that is already `Todo`. **Never hand-write a journal
    record to silence this finding** — that forges the one signal that distinguishes a validated
    approval from a closed browser tab. Unblocking a raw-closed requirements gate whose Think PR
    never merged would admit draft requirements."
  - summary contains `dependency lookups indeterminate` → annotate the row **PASS with ⚠** (still
    **PASS, never FAIL**), independent of clean/flagged: note "the GitHub dependencies API looked
    degraded — the native blocked-by lookup failed for N issue(s), so a dependency check
    (prose-dependency on a Buildable item, or the stranded-gate check on a `Blocked` item) could not
    run for them; re-run `/idc:doctor` once the API recovers." (Guards against a board-wide outage
    turning every issue UNKNOWN → nothing flagged → a `clean` summary masquerading as a true
    all-clear — including a `Blocked`-lane read outage that would otherwise leave a stranded gate
    invisible; codex round-15 P2.)
  - an explicit `board-lint: SKIP — github board unreadable …` line (the board read exited non-zero),
    OR the lint helper exit 2 / a `gh` error → **SKIP** ("could not determine"), **never FAIL** — a
    board-read failure must SKIP on that explicit marker, never be read as the hollow `clean
    (0 scanned)` an empty pipe would otherwise print (no silent all-clear).

**9b — Recirculation-intake sweep (advisory; never FAIL; read-only `--report`).** The SessionEnd hook
(`scripts/idc_recirc_sweep_hook.sh` → `idc_recirc_sweep.py --auto-correct`) is the primary detective
that re-stages **rogue Buildables** — issues that bypassed Plan (a raw `gh issue create … Stage =
Buildable`, or a captured review-residual) and so carry no `idc-provenance` marker — into
`Recirculation`, and captures untickered discovery/deferral markers. It won't fire on a `SIGKILL`,
so doctor re-runs the SAME helper in **read-only `--report`** mode as defense-in-depth — it mutates
nothing:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_sweep.py" --repo "$PWD" --report
```
- `recirc-sweep: skipped — no pillar matrix …` → **PASS** (note "no pillar matrix — the provenance
  regime is not established here, so there is nothing to re-stage"). Mirrors the no-matrix skip baked
  into the helper (a legacy board is never flagged).
- `recirc-sweep: clean (N buildable scanned)` → **PASS** (note "N buildable scanned, clean").
- one or more `rogue` / `ambiguous` / `capture:` lines → **PASS with ⚠**: list them; fix hint: "the
  SessionEnd hook auto-corrects rogues on the next session exit; to act now run `/idc:recirculate`
  (drain the discovered scope) or `/idc:plan` (re-mint the issue with provenance)." Like the
  `filesystem` board-lint branch above, the helper's marker/ticket capture is **github-only** (a
  filesystem board stores fields, not issue bodies); the report says so and re-stage-by-Stage still
  works.
- a `dropped larger-loop handoff` line (or a `, N dropped handoff(s)` clause in the summary) →
  **PASS with ⚠** (advisory; the sweep is **surface-only** here and mutates nothing): an admitted
  `Stage = Consideration` was never decomposed into Buildable work (no child and no in-flight Plan).
  List them; fix hint: "run `/idc:plan` over the admitted consideration to decompose it into
  Buildables (or the next `/idc:autorun` planning lane will)."
- helper exit 2 or error → **SKIP** ("could not determine"), **never FAIL**.

**9c — `Stage` carries the `Recirculation` option (github only; read-only detection + offer).** The
sweep can only re-stage a rogue if the board's `Stage` single-select actually has a `Recirculation`
option. This is a `github`-backend check (the `filesystem` backend's `Stage` is enum-validated in
code, so it always accepts `Recirculation`); **SKIP** for `filesystem`. Probe read-only (reuses
`$num` / `$owner` from check 3):
```bash
gh project field-list "$num" --owner "$owner" --format json --jq \
  '.fields[] | select(.name=="Stage") | .options[].name' | grep -qx "Recirculation" \
  && echo stage-recirc-ok || echo stage-recirc-missing
```
- `stage-recirc-ok` → **PASS**, no note.
- `stage-recirc-missing` (the `Stage` field exists but has no `Recirculation` option) → **PASS with
  ⚠**, note: "the board's `Stage` field has no `Recirculation` option, so the recirculation sweep
  cannot re-stage rogue Buildables — fix it by running **`/idc:update`** (the natural post-upgrade
  command; it appends the option) or `/idc:init`. The append is an **add-one-option migration**:
  existing options keep their node ids, so item values are preserved — never a replace of the option
  set." **doctor only detects and points — it never mutates the board.** (If check 3 already flagged
  the `Stage` field absent entirely — a legacy 4-field board — note that instead; `Stage` is additive
  and its absence is never a FAIL.)

Row 9 only *reads* the board (the paginating reader `idc_gh_board.py`, `gh issue view`,
`gh api … GET`, `gh project field-list`, and the helpers' read-only `--report` mode), preserving
doctor's strictly-read-only contract (guarded by `phase7-command-prose-invariants.sh`).

**10 — Board↔git reconciliation (advisory; never FAIL; read-only report).** Run the janitor scanner
(`idc_git_janitor.py`) in its **default report mode** — read-only, it mutates nothing — to surface
debris that a dead/interrupted session left outside the guard rail: orphan worktrees,
merged-but-surviving branches (local + remote), and board↔issue drift, tiered SAFE-FIX / REPORT-ONLY
/ RISKY / COHERENT. This is the same scanner `/idc:janitor` drives; doctor only ever *reports* it
(**never** `--apply-safe`), so the strictly-read-only contract holds. Reuses `$num` / `$owner` from
check 3 on github:
Pass `--report-session` + `--report-nonce` (the `nonce` from this command's active record — read it
with the `status` call in the lifecycle section below, BEFORE this row runs). That makes the SCANNER
itself persist `{scanner_exit}` in its source-owned provenance envelope bound to this record, which is what the closeout
re-derives this row's PASS from — a row-10 PASS the scan never recorded is refused, so the flags are
not optional:
```bash
nonce=$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json \
  | python3 -c 'import json,sys; print(next((r.get("nonce","") for r in json.load(sys.stdin)["active"] if r.get("command")=="doctor"),""))')
backend=$(grep -E '^backend:' docs/workflow/tracker-config.yaml | awk '{print $2}')
if [ "$backend" = "github" ]; then
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" \
    --repo "$PWD" --backend github --owner "$owner" --project "$num" --check-journal-divergence \
    --report-session "$CLAUDE_CODE_SESSION_ID" --report-nonce "$nonce"
else
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$PWD" --tracker "$PWD/TRACKER.md" \
    --check-journal-divergence --report-session "$CLAUDE_CODE_SESSION_ID" --report-nonce "$nonce"
fi
```
Read the scanner's exit code + its `janitor: N safe-fix, M risky, K report-only` summary:
- exit **0** (`COHERENT`) → **PASS** (note "board↔git coherent").
- exit **1** (findings) → **PASS with ⚠** (advisory, **never FAIL**): quote the summary counts; fix
  hint: "run `/idc:janitor` for the full report, then `/idc:janitor --apply-safe` to clear the
  SAFE-FIX tier (RISKY + REPORT-ONLY are reviewed by hand, never auto-applied)."
- exit **2** (fail-closed: not a git repo, unresolved default branch, unreadable board, or an
  indeterminate dimension) → **SKIP** ("could not determine"), **never FAIL** — surface the stderr
  diagnostic. Like Rows 8/9, Row 10 is never a hollow clean and never a FAIL.

## Output

Emit a single table, then a one-line verdict. Tally PASS / FAIL / SKIP across the ten rows (rows
9 and 10 — build-lane hygiene and board↔git reconciliation — are advisory. Row 8 may FAIL only for
an unsupported Python runtime; its cache comparison remains advisory):

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
| 8 | Runtime + plugin cache freshness | PASS | Python 3.13; running 2.1.0 |
| 9 | Build-lane hygiene (advisory) | PASS | 4 scanned, clean |
| 10 | Board↔git reconciliation (advisory) | PASS | board↔git coherent |

IDC doctor: N passed, M failed, K skipped
```

## Command lifecycle — verify at entry, close out

Doctor never changes source files or tracker/board state. It does write transient, gitignored command
evidence and may append `.idc-*-report.json*` to `.gitignore` once. Verify at entry, then close it with
a validated terminal status before your final answer:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json   # -> read the active record's `nonce`
# … after the table + verdict, PERSIST them (bound to this record's nonce) so the closeout re-reads its
# own report. The payload must satisfy the FULL doctor row contract: ALL rows 1..10 (unique ids), each
# `result` one of PASS|FAIL|SKIP, the script-backed row 10 (janitor scanner) carrying its `script` +
# integer `exit`, and a `verdict` EQUAL to the derived aggregation (FAIL if any row FAILed, else PASS).
# A 2-row / arbitrary / inconsistent-verdict payload is refused AT THE WRITE DOOR: …
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_command_report.py" --cwd "$PWD" write-doctor \
  --session "$CLAUDE_CODE_SESSION_ID" --nonce "<nonce from the status record>" \
  --rows-json '[{"id":1,"result":"PASS"},…,{"id":10,"result":"PASS","script":"idc_git_janitor.py","exit":0}]'
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command doctor \
  --status <complete|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — **all ten rows and a consistent final verdict were captured** (**a FAIL verdict is
  still a complete doctor run** — doctor completing is not the repo passing). The closeout **re-reads the
  persisted doctor report** (`.idc-doctor-report.json`), requires it **bound to this record's nonce**, and
  **re-validates the full row contract**: rows must be **exactly ids 1..10** (unique), each `result` a
  legal outcome, the **script-backed row 10 carrying `{script, exit}`**, and the **verdict EQUAL to the
  derived aggregation** of the row outcomes.
  **Then EVERY row claiming `PASS` is re-derived** — the closeout independently re-runs that row's own
  cheap, read-only check (rows 1–9 directly: the settings opt-in, `gh auth status`, the tracker/board
  probe, the scaffold `ls`, the receipt parse, `install-pi.sh --check`, the mirror links, the running
  version, board readability; row 10 via the scanner's own `--report-session`/`--report-nonce` report,
  whose `scanner_exit` must equal the row's recorded `exit`). **Report the truth and this costs you
  nothing** — a `FAIL` or `SKIP` row is *never* contested, so an honest run on a broken repo still closes
  `complete`. But a `PASS` the closeout **cannot re-establish is refused, not assumed** (rule B): a check
  that could not run — `gh` absent, a board that would not read — is a `SKIP`, never a pass. If your
  environment degraded between the run and the closeout (you lost `gh` auth, the board went away), just
  **re-run `/idc:doctor`**. A forged/absent report, one not bound to the record, a 2-row / arbitrary
  report, an inconsistent verdict, or any PASS row its re-run does not corroborate are all refused.
  Evidence refs: `refs:{}` (the report is the proof).
- **`blocked_external`** — doctor could not even establish its git-hygiene row (e.g. the cwd is not a
  git repo): run the scanner with `--report-session`/`--report-nonce` so it records `scanner_exit:2`
  bound to this record, then cite `blocker:{helper:"idc_git_janitor.py", exit:2, diagnostic}` (the only
  re-derivable doctor blocker; the cited exit must MATCH the report).

Doctor is a **diagnostic**, not a pipeline stage: it does not call the next-action oracle and never
claims a pipeline handoff.
