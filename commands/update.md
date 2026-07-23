---
description: IDC Update — resync a repo's stamped scaffold to the installed plugin after a plugin update (receipt-driven; customized files are diff-and-asked; the only board change is a non-destructive append of a missing required Stage option — never a destructive/structural board change)
argument-hint: (no arguments)
---

You are running `/idc:update`. Bring a governed repo's stamped scaffold up to date with the
installed plugin version, **files only**. The install receipt
(`docs/workflow/install-receipt.yaml`) is the source of truth for what IDC stamped, so update can
tell a pristine file (safe to refresh silently) from one the operator customized (must ask). Work
the phases in order, from the target repo root (`ROOT="$(git rev-parse --show-toplevel)"`).

**The compare is safety-critical and fails toward asking.** A file is silently re-stamped *only*
when the receipt proves it untouched; anything else is shown as a diff and the operator decides.
Update makes **one, and only one, non-destructive** board change — appending a missing *required*
`Stage` option (additive: existing options keep their node ids, so item values survive) — and
**reports** every other kind of board drift without touching it. It never performs a destructive or
structural board mutation (no option-set replace, no field rename/delete) and never touches the
data-bearing configs. U7 adds the one-time adoption bootstrap: update writes the durable
`reconciliation-baseline-required` / `baseline-pending` marker before bootstrap begins, delegates to
`/idc:janitor --bootstrap`, and writes the adoption receipt last only after bootstrap converges. Until
that bootstrap completes, ordinary mutators stay blocked while doctor/update/janitor/recovery remain
available. Idempotent: a re-run with nothing stale reports `skipped-already-current` and the option
append is a no-op. The receipt is rewritten **only at the very end of a fully successful run**, so a
half-finished update can never masquerade as complete.

## Phase 0 — Preconditions

1. **Git repo + scaffold present.** `git rev-parse --show-toplevel`; confirm `WORKFLOW.md` and
   `docs/workflow/` exist (else this repo isn't initialized — point at `/idc:init`). A clean tree
   is recommended so the refreshed files are reviewable as a discrete change.
2. **Stale-session guard (HALT if stale).** Claude Code caches this command's markdown at session
   start and runs it from a **version-keyed cache** dir. If the plugin was updated *this session*,
   a newer version sits in the cache but the body executing now may be the OLD one — running stale
   update logic against a newer install can re-introduce just-fixed bugs. This is now a **repo
   contract, not just a cache check**: pass `--repo` so the running version is also compared
   against this repo's own install receipt (`plugin_version` — the version that last stamped it),
   never just the installed-cache siblings. Check before doing anything:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_plugin_freshness.py" \
     --plugin-root "${CLAUDE_PLUGIN_ROOT}" --repo "$ROOT" --json
   ```
   If `"verdict": "stale"` (exit 4), **STOP immediately** and tell the operator: this session's
   IDC version is older than either this repo's install receipt or the installed plugin cache —
   run `/reload-plugins` (or restart the session) and re-run `/idc:update`. **`/clear` does not
   reload plugin commands or hooks** — it only clears conversation context, not the cached plugin
   bundle — so `/clear` alone will NOT fix a stale session; only `/reload-plugins` or a full
   restart re-reads the plugin. Do **not** proceed on stale logic. `"current"` or
   `"development-current"` (e.g. a `--plugin-dir` dev load newer than the repo's receipt) →
   proceed. A plugin update may also ship new commands/skills an already-running session won't see
   until reload — same fix. If the command instead exits `2` (invalid receipt — a
   `receipt_version: 2` receipt whose `plugin_version` is missing or malformed), **STOP**: the
   repo's install receipt is corrupt or hand-edited, not stale — report this to the operator and do
   not guess a version or proceed; the receipt needs manual repair (or deletion, to graduate a
   fresh one) before `/idc:update` can run safely.
3. **Scope-aware plugin update (terminal step, done before this command).** `/idc:update` only
   resyncs this repo's scaffold files; pulling the new *plugin* version itself is a terminal
   command — `claude plugin update idc@idc-workflow --scope project`. The bare
   `claude plugin update idc@idc-workflow` defaults to `--scope user` and **errors**
   (`Plugin 'idc' is not installed at scope user`) for a project-scoped install, so always pass
   `--scope project`. If that step was skipped, `${CLAUDE_PLUGIN_ROOT}` still resolves to the old
   cached version and this command will only see the old templates (reporting
   `skipped-already-current`) — surface that as the likely cause rather than declaring the repo
   current.

## Phase 1 — Classify the stamped files against the receipt

- **Receipt present:** classify every stamped file against on-disk reality:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" verify --repo "$ROOT" --json
  ```
  The JSON's `always_ask` list names the **operator-data files** (`WORKFLOW-config.yaml`,
  `docs/workflow/tracker-config.yaml`, and `docs/workflow/verification-handles.yaml`). The two
  configs are seeded from blank stubs, then filled with this repo's data (`domains`, `field_ids`,
  `project_number`, the `prd` path, …). Update therefore **never overwrites a data-bearing config**
  and never offers a destructive keep/replace over operator data. The verification-handle registry is a governed, secret-free,
  operator-owned recipe file: update must preserve it and never overwrite a cited or customized
  recipe with a template refresh. Because these files are operator data by design, update **never
  overwrites them and never offers a destructive whole-file replace.** Handle every `always_ask`
  file **present on disk** with the preserve rules in Phase 2 §A regardless of its drift class or
  recorded `state`; this takes precedence over the rules below (and subsumes the old
  legacy-receipt guard — a `state: stamped` operator-data file is preserved, never silently
  re-stamped). The one exception is a `missing` operator-data file (the operator deleted it): there
  is no data on disk to preserve and no file for §A's advisory checks to read, so it follows the
  `missing` rule below — restore as the blank stub, default leave-removed — which §A also points to.
  Branch the remaining (non-`always_ask`) files on the drift class **and** the recorded `state`:
  - `unchanged` **and** `state: stamped` → pristine. Safe to refresh
    silently — but only if the installed plugin's template for that file actually differs from
    what's on disk; if identical, `skipped-already-current`.
  - `modified`, **or** any entry the receipt marked `state: customized` → operator-customized:
    **show-diff-and-ask** (on-disk vs the installed template's rendered bytes); the operator
    chooses keep or replace. Never silently overwrite a customization.
  - `missing` → was stamped but removed; offer to restore it from the template (default: leave
    removed unless the operator wants it back). A missing data-bearing config restores as the blank
    stub for the operator to re-fill.
  - `unrecorded` → files the **installed plugin version stamps that this receipt does not list** —
    they are **new in a newer plugin version** (e.g. a pre-4.0.0 receipt has no
    `docs/workflow/workflow-machine.yaml`), so the receipt-driven classes above never see them.
    Absent on disk → **install it via §B now** (this is the version migration, not an operator
    removal — no leave-removed default). Present on disk → provenance unknown: show-diff-and-ask
    like `modified`, never silently overwrite. An `unrecorded` data-bearing config follows §A as
    always. Phase 4's fresh stamp records every one that landed.

    **The intake home (`docs/workflow/intakes/`) migrates this way.** A pre-4.1.0 receipt has no
    `docs/workflow/intakes/.gitkeep`, so an older repo gets the intake home installed here — the
    keepfile, and nothing else. **Never touch intake contents.** A compiled `/idc:intake` manifest
    in that directory is an operator work product, not governed scaffold: it has no template (the
    resolver rejects it by design), it is never receipt-listed, and it therefore appears in **no**
    classification bucket. Adding the home to an older repo must leave every manifest already in it
    byte-for-byte untouched.
  If the receipt is present but **invalid** (the helper exits non-zero), STOP and report the parse
  error — do not silently treat files as untouched.
- **No receipt (pre-receipt install):** this is the one-time graduation. **Diff-and-ask for every
  scaffold file** (treat them all as possibly-customized), apply what the operator approves, then
  Phase 4 writes the repo's first receipt. The operator-data files are the exception even here:
  apply the preserve rules in **Phase 2 §A** — the two configs use the structure-only advisory and
  `verification-handles.yaml` is preserved after fixed-code validation, never overwritten.

## Phase 2 — Apply the approved refreshes (files only)

### §A — Operator-data files (`always_ask`): preserve, advise, never overwrite

For each `always_ask` file **present on disk**, **leave the file exactly as-is** — it holds the
operator's data. (A `missing` operator-data file — the operator deleted it — has no data to preserve
and no file for the advisory checks below to read; do **not** run them against a nonexistent path —
follow the Phase 1 `missing` rule instead: restore as the blank stub, default leave-removed.)

- **`WORKFLOW-config.yaml` + `docs/workflow/tracker-config.yaml`** use the existing
  **structure-only** advisory: resolve + render the template (the §B mechanics below), then compare
the template (the §B mechanics below), then compare structural keys (list contents, block scalars,
and flow values are treated as opaque, so `domains` entries / `field_ids` values / model-routing
prose never read as drift — only a genuinely new key does):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_config_keys.py" --added "$ROOT/<dest>" "<rendered-template>"
```
- **Nothing printed** → the file is already structurally current; report `preserved — config
  current`. **Do not show a diff, do not ask anything.**
- **Key-paths printed** → the new version added that structure (e.g. a new `field_ids.*` field).
  Report `preserved — N new optional key(s): <list>` and tell the operator how to adopt them **by
  hand** (add the key, keep your values). **Never** overwrite the file or offer a whole-file
  replace — that discards the operator's data and is never the right move for these files.

This is the same notion of "structure" `/idc:init` seeds, so a config can be brought into
structural alignment without ever risking the `domains`, `field_ids`, `project_number`, or `prd`
values it carries.

- **`docs/workflow/verification-handles.yaml`** is preserved as operator-owned recipe data, not
  a structure-only config. Validate it read-only through the fixed helper:
  ```bash
  python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_verification_handles.py" validate \
    --repo "$ROOT"
  ```
  - Validation passes → report `preserved — registry current` and leave the file untouched.
  - Validation fails (schema mismatch / malformed / secret-bearing) → report the exact helper error
    and stop. Never overwrite the registry with the template to make the warning disappear; the
    operator's recipes must be preserved and repaired in-place.

### §B — Template-stamped files (everything else)

For each file approved for refresh (pristine-and-differing, operator-chose-replace,
restore-missing, or an absent `unrecorded` file being installed by the version migration):
**resolve its template source through the shared resolver — never guess the
template by basename or path-tail** — then render and write it, substituting the same tokens
`/idc:init` does — `{{PROJECT_NAME}}` (read from `WORKFLOW-config.yaml`) and, for the github
backend, `{{TRACKER_PROJECT_NUMBER}}` (read from `docs/workflow/tracker-config.yaml`). Record, per
file, what changed.
```bash
src="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_template_for.py" \
        --plugin-root "${CLAUDE_PLUGIN_ROOT}" "<dest-relative-to-repo-root>")"
```
The resolver is the single source of truth `idc_init_scaffold.sh` also uses, so the dest→template
mapping can't drift between scaffold and resync. It encodes exactly:

| Governed file (dest) | Template source |
|----------------------|-----------------|
| `WORKFLOW.md` | `templates/WORKFLOW.md` |
| `WORKFLOW-config.yaml` | `templates/WORKFLOW-config.yaml` |
| `docs/workflow/tracker-config.yaml` | `templates/tracker-config.yaml` |
| `docs/workflow/workflow-machine.yaml` | `templates/workflow-machine.yaml` |
| `docs/workflow/<rest>` (e.g. `README.md`, `code-reviews/…`, `pillar-matrices/…`, `intakes/.gitkeep`) | `templates/docs-tree/<rest>` |

This closes the docs-tree ambiguity: `docs/workflow/README.md` resolves to
`templates/docs-tree/README.md`, **never** the unrelated `templates/README.md` (which documents the
templates dir itself). `docs/workflow/workflow-machine.yaml` (the transition engine's legal-transition
table, v4 Phase 2) resolves to the top-level `templates/workflow-machine.yaml` (checked before the
docs-tree branch), **not** `templates/docs-tree/workflow-machine.yaml`. It is a **pristine** governed
file (no operator data), so it refreshes silently like `WORKFLOW.md` — a repo whose engine table
predates a plugin bump is brought current here, and a missing copy is restored. If the resolver exits
non-zero for a path, **STOP** — do not fall back to a guessed template.

Files the operator chose to keep are left exactly as-is. Update touches **only** stamped scaffold
files — never source, never tests. Its sole board action is the non-destructive `Stage`-option
append in Phase 3.

### §C — Ensure the obligations ledger is gitignored (additive, idempotent)

The per-session obligations ledger (`.idc-session-state.json`, v4 Phase 3) is transient working
state written only by hooks — never committed. A repo scaffolded before Phase 3 has no ignore for
it, so ensure it now (the ledger module owns the filename + the ignore rule; the step is
append-only and **never rewrites the operator's `.gitignore` lines**):
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_ledger.py" --cwd "$ROOT" ensure-gitignore
# The persisted drain verdict (.idc-drain-verdict.json, v4 Phase 3 Stage E2) — the same transient
# per-session sidecar (the drain writes it so the Stop gate reads the github board conjunct locally,
# zero GraphQL on the stop path). Ensure it is ignored too, identically additive + idempotent:
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_drain_verdict.py" --cwd "$ROOT" ensure-gitignore
# The persisted per-command diagnostic reports (.idc-<kind>-report.json, Task 6 wave 3) — /idc:doctor +
# /idc:janitor write their run's result there so the command contract re-reads the run's OWN report;
# transient per-session working state, never committed. Ensure it is ignored too (additive, idempotent):
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_command_report.py" --cwd "$ROOT" ensure-gitignore
# The transition-journal advisory-lock sidecar (docs/workflow/transition-journal.ndjson.lock, v4
# Phase 4 #150) — the runtime flock token rotation + journal_append create on a STABLE sidecar so the
# journal↔rotation lock survives os.replace. Working state, never committed; a repo scaffolded before
# #150 has no ignore for it, so its first rotation would strand an untracked .lock the janitor then
# flags as debris. Ensure it too (the janitor owns the lock-path convention + ignore rule):
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$ROOT" --ensure-gitignore
# The durable pause record (.idc-pause-state.json) — the local statement that this repo's pipeline run
# was deliberately paused (`/idc:pause`), cleared by `/idc:resume` or the next `/idc:autorun` preflight.
# Local run state, never committed; a repo scaffolded before pause/resume has no ignore for it. Ensure
# it too (the pause-state module owns the filename + ignore rule; additive, idempotent):
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$ROOT" ensure-gitignore
```
Idempotent: a no-op if the line is already present (report `ledger-gitignore-already-present` /
`drain-verdict-gitignore-already-present` / `journal-lock-gitignore-already-present`), otherwise
appends it (`…-added`). None is a stamped/receipt-tracked file, so they never appear in the Phase 1
drift classification — they are standing additives the same way the Phase 3 `Stage`-option append is.

### §D — Refresh the shared Path Gate git backstops

Re-install/verify the shared Path Gate pre-commit/pre-push hooks in the repository Git dir. This is
idempotent and preserves any pre-existing unmanaged hook by chaining it behind the IDC-managed wrapper:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_path_gate.py" install-hooks --repo "$ROOT" --plugin-root "${CLAUDE_PLUGIN_ROOT}"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_path_gate.py" verify-hooks  --repo "$ROOT" --plugin-root "${CLAUDE_PLUGIN_ROOT}"
```
If verification fails, STOP — the repo would otherwise claim guarded git backstops it does not have.

## Phase 3 — Board reconcile (one safe additive migration; everything else report-only)

Compare the live tracker against the installed version's expectation. Update performs exactly **one**
board mutation — appending a missing *required* `Stage` option, which is **non-destructive** — and
**reports** all other drift without touching it.
- `github` backend: read the board's fields (`gh project field-list <num> --owner <owner> --format
  json`) and compare against the v2 contract — five fields `Status` (`Blocked|Todo|In Progress|Done`),
  `Stage` (`Consideration|Planning|Buildable|Recirculation`), `Wave`, `Phase`, `Domain`. `Stage` is
  **additive** on two axes:
  - **(a) no `Stage` field at all** — a legacy 4-field board predates Stage. Report as informational
    drift, not a failure (an absent `Stage` reads as `Buildable`). Do **not** create the field here —
    creating a field from scratch is full provisioning, which is `/idc:init`'s job; point there.
  - **(b) a `Stage` field that exists but lacks the `Recirculation` option** — the board predates
    3.1.0, and this is the post-upgrade gap a user hits by running `/idc:update`. Update **fixes it in
    place** by appending the option **non-destructively** via the shared helper (the same recipe
    `/idc:init` uses): it re-sends every existing option *by node id* so GitHub preserves them and
    **item values are never touched**, and appends only the new option — it never replaces the option
    set (a replace re-IDs every option and wipes values). Idempotent + fail-closed; report
    `stage-recirc-appended` (or `stage-recirc-already-present` on a re-run).
    ```bash
    PID=$(gh project view <num> --owner "$OWNER" --format json --jq '.id')   # PVT_… project node id
    # GraphQL READ (a read query — ALLOWED by the mutation interlock; not `field-list`): the
    # non-destructive append must re-send each existing option's color + description, which
    # `gh project field-list` omits (it returns only id+name).
    STAGE_FIELD=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{field(name:"Stage"){... on ProjectV2SingleSelectField{id options{id name color description}}}}}}' -f p="$PID" --jq '.data.node.field')
    if [ -n "$STAGE_FIELD" ]; then
      # APPLY the append through the SANCTIONED PYTHON DOOR — `idc_stage_options.py apply` assembles
      # AND runs the `updateProjectV2Field` mutation via its OWN gh subprocess. Do NOT run the mutation
      # with a raw `gh api graphql -f query="$MUT"`: the interlock hard-DENIES a raw GraphQL mutation
      # during this active /idc:update command (only reads and the Python doors are allowed).
      printf '%s' "$STAGE_FIELD" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_stage_options.py" apply --ensure-option Recirculation --options-json - --repo "$(pwd)"; RC=$?
      case "$RC" in
        0) : ;;   # stage-recirc-appended (existing option ids + item values preserved)
        3) : ;;   # stage-recirc-already-present (idempotent no-op)
        *) echo "stage reconcile: could not apply the append (fail-closed) — record an operator action" ;;
      esac
    fi
    ```
- **Everything else is report-only.** Any *other* board drift — a missing/renamed/extra field, an
  unexpected `Status` option set, or anything that would need a **destructive** option-set replace —
  update **reports** and leaves for the operator to resolve via `/idc:init` (provisioning) or
  `idc:idc-tracker-github`. Update never performs a destructive or structural board mutation.
- If the board read **cannot run** (board unreachable, or `filesystem` backend — whose `Stage` is
  enum-validated in code, so it always accepts `Recirculation` and needs no append), report a
  distinct outcome — "board reconcile: could not verify (reason)" / "n/a (filesystem)" — never
  silently report "no drift".

## Phase 3b — Offer: enable delete-branch-on-merge (operator consent, surfaced not silent)

The same platform-level backstop `/idc:init` offers (belt-and-suspenders for the finisher's own
branch cleanup — see `idc:idc-finisher`'s git-finalization tail). Check, then **ask — never flip
it silently**:
```bash
gh repo view --json deleteBranchOnMerge --jq .deleteBranchOnMerge 2>/dev/null
```
- Already `true` → `skipped-existing`, no prompt.
- `false` → ask the operator's consent, the same question `/idc:init` does; on explicit **yes**
  run `gh repo edit --delete-branch-on-merge` → `enabled`; on **no**, or with no operator to ask (a
  headless/non-interactive run) → leave it untouched → `declined`; never auto-enable.
- The probe errors (no GitHub remote, or `gh` lacks repo-admin scope) → nothing to offer consent
  over, so **do not prompt**; leave it untouched and report `n/a (probe failed: <reason>)` — a
  distinct outcome from `declined`, never silently folded into it.

## Phase 3c — Baseline bootstrap handoff (one-time migration)

After the file/board refresh and before rewriting the install receipt, ensure the governed repo has a
durable adoption boundary:

- write / preserve `docs/workflow/reconciliation-baseline-required.json` (`baseline-pending`);
- delegate to `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_janitor.py" --repo "$ROOT" <board args> --bootstrap`;
- if bootstrap is interrupted or halts with blockers, **leave the marker present** and report the
  blockers honestly — the repo is explicitly baseline-pending, not falsely current;
- only a converged bootstrap clears the marker and writes `docs/workflow/reconciliation-adoption.json`
  last.

This marker is what blocks ordinary mutating workflow commands while still leaving `/idc:doctor`,
`/idc:update`, `/idc:janitor`, and recovery doors available.

## Phase 4 — Rewrite the receipt (end of a successful run only)

Once every approved refresh is applied, write a fresh receipt over the stamped set so the next
update and `/idc:uninstall` stay accurate. The receipt is v2: resolve the running plugin's own
version and pass it as `--plugin-version` — this is the value the stale-runtime guard in Phase 0
reads back on the next session, so it must always be **this session's real running version**,
never a guess. Pass the files the operator **kept customized** via `--customized` so the next
update asks again instead of silently re-stamping over them — this **always includes the two
operator-data configs** (preserved in Phase 2 §A), which keeps a pre-guard `state: stamped`
receipt from re-appearing. `docs/workflow/verification-handles.yaml` stays preserved by the helper's
fixed `always_ask` path even when it remains receipt-stamped plain, so its operator-authored recipes
are never silently refreshed:
```bash
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$ROOT" --out docs/workflow/install-receipt.yaml \
  --plugin-version "$PLUGIN_VERSION" --written-by idc:update \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  [--customized <other-kept-file> ...] <stamped-file> <stamped-file> ...
```
This graduates a pre-receipt repo to receipt-driven (and a v1 receipt to v2 — the `plugin_version`
requirement is satisfied from here on), and — because it runs only at the very end — guarantees a
partial update never leaves a receipt that claims more than was actually done. The receipt never
lists itself, `TRACKER.md`, or `.claude/settings.json` (the helper drops them).

If a receipt already existed and nothing changed this run, leave it untouched and report
`skipped-already-current`.

## Phase 5 — Summary

Print one table of every stamped file (`refreshed` / `preserved — config current` / `preserved — N
new optional key(s)` / `restored` / `skipped-already-current`), then:
- the board-reconcile outcome (one of: no drift / `stage-recirc-appended` /
  `stage-recirc-already-present` / other drift reported / could not verify),
- the gitignore-additive outcomes (`ledger-gitignore-added`/`-already-present`, and likewise for
  `drain-verdict-gitignore-` and `journal-lock-gitignore-`),
- the `deleteBranchOnMerge` outcome (`enabled` / `declined` / `skipped-existing` / `n/a`),
- the receipt status (`rewritten` / `graduated` / `skipped-already-current`),
- and the cache-refresh reminder if any newly-shipped command/skill files arrived with this update.

| File | Status |
|------|--------|

## Command lifecycle — verify at entry, close out honestly

The command entry gate opened this command's lifecycle record at expansion; verify it, and **close it
with a validated terminal status** before your final answer (the Stop closeout gate refuses a
walk-away from an open command). Update is a **resync/maintenance** command — no pipeline oracle
handoff:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" status \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --json
# … after Phase 4 rewrites the receipt …
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py" finish \
  --repo "$PWD" --session "$CLAUDE_CODE_SESSION_ID" --command update \
  --status <complete|blocked_external> --evidence-json '<envelope>'
```

- **`complete`** — the v2 receipt verifies **and** the running version equals the receipt version. The
  closeout **re-derives** this: it parses the install receipt (must be `receipt_version: 2`), reads the
  **running** plugin version live from `plugin.json` (refusing unless the receipt's `plugin_version`
  equals it), **and RUNS the real fingerprint verification** (every stamped file's bytes match its
  recorded SHA-256 — a modified/missing scaffold file fails closed) — **never two caller-typed
  versions**. Evidence refs: `refs:{}` (optionally `receipt:"<repo-rel receipt path>"` if non-default).
- **`blocked_external`** — an update failure the validator can RE-DERIVE by a read-only re-run: cite
  `idc_receipt_check.py` (the fingerprint re-run must actually find drift — an invalid receipt or a
  modified/missing stamped file): `blocker:{helper:"idc_receipt_check.py", exit (nonzero), diagnostic}`.
  A caller exit/diagnostic alone is never accepted.
