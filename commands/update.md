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
data-bearing configs. Idempotent: a re-run with nothing stale reports `skipped-already-current` and
the option append is a no-op. The receipt is rewritten **only at the very end of a fully successful
run**, so a half-finished update can never masquerade as complete.

## Phase 0 — Preconditions

1. **Git repo + scaffold present.** `git rev-parse --show-toplevel`; confirm `WORKFLOW.md` and
   `docs/workflow/` exist (else this repo isn't initialized — point at `/idc:init`). A clean tree
   is recommended so the refreshed files are reviewable as a discrete change.
2. **Stale-session guard (HALT if stale).** Claude Code caches this command's markdown at session
   start and runs it from a **version-keyed cache** dir. If the plugin was updated *this session*,
   a newer version sits in the cache but the body executing now may be the OLD one — running stale
   update logic against a newer install can re-introduce just-fixed bugs. Check before doing
   anything:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_plugin_freshness.py" --plugin-root "${CLAUDE_PLUGIN_ROOT}"
   ```
   If it prints `verdict stale` (exit 4), **STOP immediately** and tell the operator: a newer IDC
   version is installed than the one this session loaded — run `/reload-plugins` (or restart the
   session) and re-run `/idc:update`. Do **not** proceed on stale logic. `verdict current` or
   `unknown` (e.g. a `--plugin-dir` dev load) → proceed. A plugin update may also ship new
   commands/skills an already-running session won't see until reload — same fix.
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
  The JSON's `always_ask` list names the **data-bearing configs** (`WORKFLOW-config.yaml`,
  `docs/workflow/tracker-config.yaml`). These are **operator-owned data files**: `/idc:init` seeds
  them from a blank stub template, then fills them with this repo's data (`domains`, `field_ids`,
  `project_number`, the `prd` path, …). Because the template is a stub by design, a filled config
  *always* differs from it byte-wise — that difference is the operator's data, **not drift**. So
  update **never overwrites a data-bearing config and never offers a destructive keep/replace.**
  Handle every `always_ask` file **present on disk** with the **structure-only rule (Phase 2 §A)**
  regardless of its drift class or recorded `state`; this takes precedence over the rules below (and
  subsumes the old legacy-receipt guard — a `state: stamped` data config is preserved, never silently
  re-stamped). The one exception is a `missing` data config (the operator deleted it): there is no
  data on disk to preserve and no file for §A's structure check to read, so it follows the `missing`
  rule below — restore as the blank stub, default leave-removed — which §A also points to.
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
  If the receipt is present but **invalid** (the helper exits non-zero), STOP and report the parse
  error — do not silently treat files as untouched.
- **No receipt (pre-receipt install):** this is the one-time graduation. **Diff-and-ask for every
  scaffold file** (treat them all as possibly-customized), apply what the operator approves, then
  Phase 4 writes the repo's first receipt. The two data-bearing configs are the exception even here:
  apply the **structure-only rule (Phase 2 §A)** — preserve, never offer to overwrite their data.

## Phase 2 — Apply the approved refreshes (files only)

### §A — Data-bearing configs (`always_ask`): preserve, structure-only advisory, never overwrite

For each `always_ask` file **present on disk**, **leave the file exactly as-is** — it holds the
operator's data. (A `missing` data config — the operator deleted it — has no data to preserve and no
file for the check below to read; do **not** run the structure helper against a nonexistent path —
follow the Phase 1 `missing` rule instead: restore as the blank stub, default leave-removed.) Check
*only* whether the installed template introduced **new structure** worth adopting: resolve + render
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

This is the same notion of "structure" `/idc:init` seeds, so a data config can be brought into
structural alignment without ever risking the `domains`, `field_ids`, `project_number`, or `prd`
values it carries.

### §B — Template-stamped files (everything else)

For each file approved for refresh (pristine-and-differing, operator-chose-replace, or
restore-missing): **resolve its template source through the shared resolver — never guess the
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
| `docs/workflow/<rest>` (e.g. `README.md`, `code-reviews/…`, `pillar-matrices/…`) | `templates/docs-tree/<rest>` |

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
```
Idempotent: a no-op if the line is already present (report `ledger-gitignore-already-present`),
otherwise appends it (`ledger-gitignore-added`). This is not a stamped/receipt-tracked file, so it
never appears in the Phase 1 drift classification — it is a standing additive the same way the
Phase 3 `Stage`-option append is.

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
    # GraphQL read (not field-list): the non-destructive append must re-send each existing option's
    # color + description, which `gh project field-list` omits (it returns only id+name).
    STAGE_FIELD=$(gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{field(name:"Stage"){... on ProjectV2SingleSelectField{id options{id name color description}}}}}}' -f p="$PID" --jq '.data.node.field')
    if [ -n "$STAGE_FIELD" ]; then
      MUT=$(printf '%s' "$STAGE_FIELD" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_stage_options.py" append --ensure-option Recirculation --options-json -); RC=$?
      case "$RC" in
        0) gh api graphql -f query="$MUT" >/dev/null ;;   # stage-recirc-appended (existing ids + item values preserved)
        3) : ;;                                            # stage-recirc-already-present (idempotent no-op)
        *) echo "stage reconcile: could not assemble the append (fail-closed) — record an operator action" ;;
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

## Phase 4 — Rewrite the receipt (end of a successful run only)

Once every approved refresh is applied, write a fresh receipt over the stamped set so the next
update and `/idc:uninstall` stay accurate. Pass the files the operator **kept customized** via
`--customized` so the next update asks again instead of silently re-stamping over them — this
**always includes the two data-bearing configs** (preserved in Phase 2 §A), which keeps a
pre-guard `state: stamped` receipt from re-appearing:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$ROOT" --out docs/workflow/install-receipt.yaml --written-by idc:update \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  [--customized <other-kept-file> ...] <stamped-file> <stamped-file> ...
```
This graduates a pre-receipt repo to receipt-driven, and — because it runs only at the very end —
guarantees a partial update never leaves a receipt that claims more than was actually done. The
receipt never lists itself, `TRACKER.md`, or `.claude/settings.json` (the helper drops them).

If a receipt already existed and nothing changed this run, leave it untouched and report
`skipped-already-current`.

## Phase 5 — Summary

Print one table of every stamped file (`refreshed` / `preserved — config current` / `preserved — N
new optional key(s)` / `restored` / `skipped-already-current`), then:
- the board-reconcile outcome (one of: no drift / `stage-recirc-appended` /
  `stage-recirc-already-present` / other drift reported / could not verify),
- the ledger-gitignore outcome (`ledger-gitignore-added` / `ledger-gitignore-already-present`),
- the `deleteBranchOnMerge` outcome (`enabled` / `declined` / `skipped-existing` / `n/a`),
- the receipt status (`rewritten` / `graduated` / `skipped-already-current`),
- and the cache-refresh reminder if any newly-shipped command/skill files arrived with this update.

| File | Status |
|------|--------|
