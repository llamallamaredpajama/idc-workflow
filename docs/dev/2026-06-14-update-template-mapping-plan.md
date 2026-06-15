# Plan — `/idc:update` template-path hardening (+ legacy-receipt clobber guard)

**Branch:** `fix/update-template-mapping` · **Targets:** `2.1.3` (2.1.2 was taken by PR #42's board-mutation gate)
**Status:** IMPLEMENTED — B1 (pinned map in `update.md`), B2 (`scripts/idc_template_for.py`, shared
with `idc_init_scaffold.sh`), and A-hardening (`always_ask` in `idc_receipt_check.py` +
legacy-receipt guard in `update.md`) all shipped; two new smoke cases
(`phase7-update-template-mapping.sh`, `phase7-update-legacy-receipt-guard.sh`) green.

## Context

While running the 2.1.1 board-link e2e against the **update** sandbox (github-backed, board #6),
`/idc:update` surfaced two suspected `/idc:update` defects. On code review, **one is already fixed in
current code** and the other is a **real latent footgun**. This plan scopes the real work and records
why the first needs no change.

## Finding A — silent-clobber of data-bearing configs → **ALREADY GUARDED (no code change)**

The sandbox run reported that a default `/idc:update` would silently overwrite `WORKFLOW-config.yaml`
(`domains`) and `docs/workflow/tracker-config.yaml` (`field_ids` + `project_number`) from the
template, wiping init-generated data.

**Current code already prevents this.** `commands/init.md` Phase 7 "Data-loss guard" (lines 157–165)
stamps both files `--customized` at install time:
```
--customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml
```
`/idc:update` Phase 1 routes any `state: customized` entry to **show-diff-and-ask** (update.md
lines 47–49), so those values are never silently lost.

**Why the sandbox still showed it:** the sandbox's receipt was written by the **PR#23 baseline init,
which predates this guard** — so its configs are `state: stamped`, not `customized`. The finding is an
artifact of a **stale test baseline**, not a current-code bug. (Now mitigated operationally: the lead
re-syncs the sandbox baseline to current production before testing — see root `CLAUDE.md` e2e section.)

**Residual risk (optional hardening, low urgency):** repos installed by a *pre-guard* plugin carry
`state: stamped` receipts for these two files, so their *first* `/idc:update` after upgrading could
still clobber them. Belt-and-suspenders fix in scope below.

## Finding B — docs-tree template-path ambiguity → **REAL (latent), fix this**

- The governed `docs/workflow/README.md` is scaffolded from **`templates/docs-tree/README.md`**
  (`scripts/idc_init_scaffold.sh` lines 32–37 copy `templates/docs-tree/*` → `docs/workflow/`).
- But **`templates/README.md` also exists** — it documents the templates dir itself (different
  content).
- `commands/update.md` Phase 2 (lines 58–64) only says *"render the installed plugin's template …
  The templates live under `${CLAUDE_PLUGIN_ROOT}/templates/`"* with **no explicit dest→template
  map** (confirmed: `grep -c docs-tree commands/update.md` → 0). An agent resolving
  `docs/workflow/README.md` by basename/path-tail can pick the **wrong** `templates/README.md` and
  **clobber the governed README** with the templates-dir doc. Same loose-derivation root cause for
  every `docs/workflow/*` file.
- In the e2e it happened to be safe (on-disk README was byte-identical to the correct template, so it
  `skipped-already-current`) — i.e. latent, not yet triggered.

**Root cause (shared with A):** `update.md` re-derives where each stamped file's template lives,
instead of reusing the single mapping the scaffold helper already encodes.

## Fixes

1. **B-primary — pin the dest→template map in `update.md`.** State it explicitly in Phase 1/2,
   mirroring the scaffold helper exactly:
   - `WORKFLOW.md` ← `templates/WORKFLOW.md`
   - `WORKFLOW-config.yaml` ← `templates/WORKFLOW-config.yaml`
   - `docs/workflow/tracker-config.yaml` ← `templates/tracker-config.yaml`
   - `docs/workflow/<rest>` ← `templates/docs-tree/<rest>`  ← **the fix for the README collision**
2. **B-durable (recommended) — one source of truth.** Add `scripts/idc_template_for.py <dest>` →
   prints the template source path for a governed dest path, and have **both**
   `idc_init_scaffold.sh` and `update.md` resolve templates through it, so the mapping can't drift
   again. (The helper currently encodes the map implicitly via the `docs-tree/` copy loop; factor it
   out.)
3. **A-hardening (optional) — legacy-receipt guard.** `update.md` always routes
   `WORKFLOW-config.yaml` + `docs/workflow/tracker-config.yaml` to **show-diff-and-ask regardless of
   receipt `state`**, protecting repos whose receipts predate the Phase 7 guard.

## Tests (reproduce-first / TDD)

- **`tests/smoke` — docs-tree mapping:** stamp a repo where `docs/workflow/README.md` differs from
  `templates/docs-tree/README.md`; assert the update template resolution picks `docs-tree/README.md`,
  **not** `templates/README.md` (fails before B-fix).
- **`tests/smoke` — legacy-receipt guard:** a receipt marking the two configs `state: stamped` with
  real `domains`/`field_ids` present; assert update does **not** silently overwrite them (treats as
  ask/keep). (fails before A-hardening; passes trivially today for `customized` receipts.)
- Full `bash tests/smoke/run-all.sh` green; `bash scripts/lint-references.sh` exit 0.
- **Live e2e (programmatic, per CLAUDE.md):** re-sync the update sandbox to a *current-init* baseline,
  then `/idc:update` and confirm `docs/workflow/README.md` stays correct + configs preserved.

## Files

- `commands/update.md` — pin the mapping (B1); optional always-ask for the two configs (A-hardening).
- `scripts/idc_template_for.py` (new) + `scripts/idc_init_scaffold.sh` — shared mapping (B2).
- `tests/smoke/` — the two new cases above.
- `.claude-plugin/plugin.json` · `marketplace.json` · `CHANGELOG.md` — `2.1.1 → 2.1.2` lockstep.

## Sequencing

Branch from `main`; this ships as **2.1.2**. **Rebase after PR #40 (2.1.1) merges** so the version
bump + CHANGELOG don't conflict. Independent of the board-link fix otherwise.

## Out of scope

Board migration (provisioning a missing `Stage` field on legacy boards) — separate concern, owned by
`idc:idc-tracker-github`, unrelated to update's file-resync path.
