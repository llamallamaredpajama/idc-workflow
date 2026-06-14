# Install-function test audit — PR #37 (`cc7130b`), 2026-06-14

**Source of truth:** the first from-scratch install test run in the `ke-idc-test-repo-install`
sandbox. Raw evidence in `/Users/jeremy/dev/sandbox/_idc-observability/ke-idc-test-repo-install/`
(snapshots `003-baseline-d84d537b` → `004-auto-596cc1bf`, the session transcript, and
`FINDINGS-install-test-pr37.md`). This audit was produced by re-reading that raw data and
**verifying every claim against the live plugin source** at `cc7130b` — not by trusting the
sandbox's own FINDINGS file (which was itself written from stale code; see F0).

> **Headline:** the test *appeared* to PASS (doctor 5/5), but it was run against **stale
> cached plugin code**, so the PASS is not trustworthy and PR #37's actual behaviour was never
> exercised. The root cause (F1) is a one-line release bug that has wide blast radius. Fixing
> F1 + F2 is the priority; F3–F5 are real but smaller; F6 is optional.

---

## F0 — Why the test was invalid (context, not a fix target itself)

`/idc:init` and all `scripts/*` run from `${CLAUDE_PLUGIN_ROOT}`, which resolves to the
**version-keyed cache** `~/.claude/plugins/cache/idc-workflow/idc/2.0.0/` — a copy Claude Code
maintains **per version string**. The tester ran `claude plugin marketplace update` (which
fast-forwarded the *marketplace clone* to `cc7130b`) and assumed that meant the install path was
current. It was not: because the version string never changed (`2.0.0` → `2.0.0`), the cache for
`2.0.0` was **never invalidated**, so `/idc:init` copied **pre-#37 templates and ran a pre-#37
doctor**.

Hard evidence (verified this session):
- `templates/tracker-config.yaml`: **dev = FIVE fields** (Status, Stage, Wave, Phase, Domain) ·
  **marketplace clone = FIVE** · **cache = FOUR** (no `Stage`; mtime Jun 14 02:02).
- The doctor that ran in-session had **5 checks** and an old `1 — Plugin enabled` check; current
  dev `commands/doctor.md` has **6 checks** and the `1 — Plugin scoped to this repo (no global
  leak)` check that *is the whole point of PR #37*. So the hardening under test was absent from
  the code that ran.

This is both a **plugin bug** (F1, below) and a **test-process bug** (handled separately, in the
sandbox repo — not in this audit's scope).

---

## Scope for this work unit

**Core (do all):** F1 (+F1b, now core), F2, F3, F4, F5, **F7, F8, F9** (the `/idc:update`-test
addendum at the bottom of this file — read it; F8 is HIGH and pairs with F3).
**Optional stretch (only if cheap + fully tested):** F6.
Keep every change **surgical** — touch only what each finding names. This is shipped-file work:
`scripts/lint-references.sh` MUST exit 0, and `tests/smoke/run-all.sh` MUST stay green. Honour
the repo conventions in `CLAUDE.md` (namespacing, `${CLAUDE_PLUGIN_ROOT}` is not a shell var,
no personal paths in shipped files).

**Delivery:** work on a new branch, then **push and open a PR** for the user to review. **Do not
merge** (the user's standing rule: never auto-merge). Lint + smoke evidence go in the PR body.

---

## F1 — [HIGH] Plugin version frozen at 2.0.0 → stale version-keyed cache + dead `update` path

**What:** `.claude-plugin/plugin.json` is `2.0.0` and has stayed `2.0.0` across PR #23 → PR #37
(multiple shipped changes). `marketplace.json`'s plugin entry carries **no** version at all.
Because Claude Code caches the plugin under `…/cache/<mkt>/idc/<version>/`, an unchanged version
means the cache is never refreshed on update, and `claude plugin update` (version-keyed) no-ops —
so an existing user can silently keep running old `/idc:*` code, templates, and scripts. This is
the root cause of F0.

**Fix:**
1. Bump `.claude-plugin/plugin.json` `version` to **`2.1.0`** (a real feature/hardening release:
   per-repo opt-in, lifecycle commands, Stage field, etc.).
2. Convert the `## Unreleased` block in `CHANGELOG.md` to `## 2.1.0 — 2026-06-14` (keep an empty
   `## Unreleased` above it for future work).
3. Verify whether `marketplace.json`'s plugin entry should carry/echo a `version` for a local
   (`"source": "./"`) marketplace; if Claude Code reads it from `plugin.json` for local sources,
   leave `marketplace.json` alone and note that in the PR. Don't add a field that does nothing.

**F1b (optional stretch):** add a guard to `scripts/lint-references.sh` (or a tiny new script it
calls) that FAILs when shipped files changed but `plugin.json` `version` matches the latest
`CHANGELOG.md` release heading — i.e. "you shipped without bumping." Only do this if it's small
and you can prove it green; otherwise leave a one-line note in `docs/dev/known-debts.md` instead.

**Verify:** `lint-references.sh` exit 0; `plugin.json` shows `2.1.0`; CHANGELOG has the dated
heading.

---

## F2 — [HIGH] `Stage` rollout incomplete in `commands/doctor.md` (four-field vs five-field drift)

**What:** Every surface is on the **five-field** board contract (Status, **Stage**, Wave, Phase,
Domain) — `templates/WORKFLOW.md` §3.1 ("Board schema — **five** fields"),
`templates/tracker-config.yaml` (has a `Stage:` slot), `commands/init.md` Phase 4 (provisions
Stage), `scripts/idc_tracker_fs.py` (`FIELDS = (… 5 …)`), and all `skills/idc-tracker-*`. But
`commands/doctor.md` was never updated by the Stage PR (#33):
- line 2 (description): "the **4-field** tracker board"
- check 3 note (≈ line 54): "any of the **four** `field_ids` (`Status`, `Wave`, `Phase`,
  `Domain`)" — **omits `Stage`**, so doctor will never flag a board missing its `Stage` field id.

**Fix:** bring `commands/doctor.md` to the five-field contract:
- description → "5-field" (or just "tracker board" to avoid future count drift).
- check 3 note → include `Stage` in the `field_ids` completeness list.
- Honour `Stage`'s **additive** promise (see `templates/WORKFLOW.md` §3.1 and
  `skills/idc-tracker-github/SKILL.md`): a legacy board with an empty/absent `Stage` is **not** a
  FAIL — at most an informational note, consistent with how the rest of the system treats absent
  Stage as `Buildable`.

**Verify:** `grep -n "four\|4-field" commands/doctor.md` returns nothing stale; doctor's field
list matches `templates/tracker-config.yaml::field_ids`; `lint-references.sh` exit 0.

---

## F3 — [HIGH/MED] `/idc:init` Phase 7 hand-rolls the receipt instead of the shipped `stamp` helper

**What:** `commands/init.md` Phase 7 tells the agent to compute SHA-256s with `shasum -a 256`
(macOS) / `sha256sum` (Linux) and **hand-write** `install-receipt.yaml`. But the repo already
ships a deterministic writer: `scripts/idc_receipt_check.py stamp` (`--repo`, `--out`,
`--written-by`, `--customized`, positional `paths`; it sorts, excludes self/settings/TRACKER.md,
and atomic-writes). Hand-rolling is a recurring agent-error surface (sort order, wrong hash tool,
YAML typos) and is inconsistent with how `verify`/`update` already work. In the test it happened
to verify clean — luck, not design.

**Fix:** rewrite Phase 7 to call the helper, e.g.:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_receipt_check.py" stamp \
  --repo "$(git rev-parse --show-toplevel)" \
  --out docs/workflow/install-receipt.yaml \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/README.md \
  docs/workflow/code-reviews/.gitkeep docs/workflow/tracker-config.yaml
```
(the path list = whatever Phase 2/3 actually created).

**Important nuance — preserve gap-fill semantics:** `cmd_stamp` rewrites the receipt from the
paths you pass; it does **not** append to an existing receipt. Phase 7's current prose promises
"on a gap-fill re-run, preserve existing entries byte-for-byte and append only newly-created
files." To keep that true with `stamp`: on a re-run, pass the **full** final receipt-listed set
(unchanged files re-fingerprint to the same bytes, so they're preserved), and carry forward any
`state: customized` entries via `--customized <path>` read from the existing receipt. Update the
Phase 7 prose to describe the helper-based flow accurately. Read `cmd_stamp`
(`scripts/idc_receipt_check.py:75`) before editing so the wording matches the code.

**Verify:** `tests/smoke/run-all.sh` green (the init/receipt phase, incl. any idempotent re-run
case) and `idc_receipt_check.py verify` clean after a smoke init.

---

## F4 — [MED] Non-portable `sed -i ''` in `commands/init.md` Phase 4 (breaks on Linux)

**What:** Phase 4's "cache the contract" step uses `sed -i '' -e "s|…|…|g"
docs/workflow/tracker-config.yaml` — the **BSD/macOS** in-place flavour. On Linux, `sed -i ''`
treats `''` as the script and errors. The plugin ships cross-platform; the scaffold script
(`scripts/idc_init_scaffold.sh`) deliberately avoids this with a temp-file pattern and even
comments why ("portable: temp file, no `sed -i` flavor split").

**Fix:** replace the `sed -i ''` usage in `commands/init.md` Phase 4 with the same portable
temp-file substitution pattern used in `idc_init_scaffold.sh` (write to `$(mktemp)`, then `mv`),
so token substitution of `project_number` / field ids works on Linux and macOS alike.

**Verify:** read-through; `grep -n "sed -i ''" commands/init.md` returns nothing; `lint`
exit 0. (Note for the PR: the GitHub-board path is **not** covered by the filesystem-backend
smoke suite, so this change is validated by inspection, not by smoke.)

---

## F5 — [LOW] `commands/doctor.md` check 4 prose vs implementation mismatch

**What:** check 4 prose says `docs/workflow/` must contain "**exactly** its two v2 subdirectories
`pillar-matrices` and `code-reviews`," but the implementation is `ls WORKFLOW.md
WORKFLOW-config.yaml docs/workflow/pillar-matrices docs/workflow/code-reviews` — which only tests
that those paths **exist**. A foreign `docs/workflow/phase-planning/` (and foreign files inside
`pillar-matrices/`) coexisted in the sandbox and doctor PASSed. Tolerating extra dirs is arguably
correct (init is idempotent and preserves foreign content); the prose just overstates the check.

**Fix:** soften the check 4 prose to "contains (at least) its two v2 subdirectories …" so prose
matches behaviour. (Optionally, note unexpected extra subdirs as an informational aside — do
**not** turn it into a FAIL.)

**Verify:** read-through; `lint` exit 0.

---

## F6 — [LOW, optional] `idc_receipt_check.py verify --json` has no top-level pass/fail

**What:** `verify --json` emits `{missing, modified, unchanged}` with no `ok` boolean or summary,
so every consumer must derive pass/fail from "missing and modified are both empty." In the test,
the agent's first `jq` guessed `.ok/.drift/.summary` and got all-`null` before discovering the
real schema — a small ergonomics tax that the observability harness pays too.

**Fix (only if you also touch this file for F3 and it stays trivial):** add `"ok": <bool>` (true
iff `missing` and `modified` are both empty) and a `"summary"` count line to the `--json` output,
**without** changing the existing keys (keep `missing`/`modified`/`unchanged` for back-compat).
If it risks the smoke suite's expectations, skip it and leave a `known-debts.md` note instead.

**Verify:** `tests/smoke/run-all.sh` green (confirm nothing parses the old JSON shape strictly).

---

---

## Addendum — `/idc:update` test (`ke-idc-test-repo-update` sandbox @ `272ce9f8`, a genuine PR#23 install)

A second sandbox test exercised the **update** path (install a real prior version, then update to
latest). It independently confirmed F1 & F2 with sharper evidence and surfaced three new items.
All claims below were re-verified against the live source this session.

### F1 (enriched)
Update test confirmed the no-op directly: `claude plugin update idc@idc-workflow --scope project`
→ "✔ already at the latest version (2.0.0)", cache **not** rebuilt; cached `WORKFLOW.md` = 181
lines vs marketplace = 200 lines. Add to the F1 fix:
- bump the matching `marketplace.json` plugin entry version in lockstep with `plugin.json` (first
  verify whether a local `"source": "./"` marketplace reads version from `plugin.json`; if so a
  PR note suffices — but make the two agree either way);
- **F1b is now CORE:** add a release check that FAILs when `CHANGELOG.md` has `## Unreleased`
  content but `plugin.json` `version` wasn't bumped (wire into `lint-references.sh` or a small
  script it calls);
- if `claude plugin tag` is a real command in this Claude Code version, document it for
  plugin.json/marketplace agreement — **verify it exists before referencing it**; don't cite a
  command that doesn't exist;
- document (docs/installing.md or release notes) that main-branch merges don't reach users until a
  version bump + republish.

### F2 (expanded — the Stage half-migration is broader than doctor.md)
- `commands/update.md` Phase 3 board-drift (lines ~64–67) **also** hardcodes the four-field
  contract ("four fields `Status`, `Wave`, `Phase`, `Domain`") and is Stage-blind → bring to five
  fields. It is **report-only** (must not add/migrate the field); just report a missing `Stage` as
  drift, honouring Stage's additive promise.
- `templates/WORKFLOW.md` (lines ~76–78) claims `Stage` is provisioned by "`/idc:init` (or
  `/idc:doctor`)" — but `/idc:doctor` is **read-only by contract** and cannot provision anything.
  Reconcile the wording: only `/idc:init` provisions; doctor at most *flags* a missing `Stage`.
- (unchanged) `commands/doctor.md` description + check-3 field-id list → add `Stage`.

### F7 — [MED, CONFIRMED] scope-blind update error
`claude plugin update idc@idc-workflow` with no `--scope` errors `Plugin 'idc' is not installed at
scope user` for a project-scope install. Fix: `/idc:update` Phase 0 (and/or `/idc:doctor`) detects
the install scope and prints the exact `claude plugin update idc@idc-workflow --scope project`
command; add a line to `docs/installing.md`.

### F8 — [HIGH, CONFIRMED dry-run] `/idc:update` silently wipes operator data (data loss)
`/idc:init` writes **operator/runtime data** into two scaffold files *after* copying the template,
then fingerprints them `state: stamped`:
- `WORKFLOW-config.yaml` → the derived `domains:` list (5 entries in the test)
- `docs/workflow/tracker-config.yaml` → `project_number` + the `field_ids` board node IDs
`/idc:update` Phase 1 classifies `unchanged + state: stamped` = pristine → Phase 2 refreshes them
silently (re-substituting only `{{PROJECT_NAME}}` / `{{TRACKER_PROJECT_NUMBER}}`), **wiping**
`domains` → `[]` and `field_ids` → empty. Confirmed by dry-run (`commands/update.md` is
byte-identical PR#23↔#37). This destroys the board wiring on every update.

**Fix (a) — verified viable, folds into F3:** have `/idc:init` record those two files as
`state: customized` in the receipt. `update.md` Phase 1 (lines 38–40) already routes
`state: customized` to **show-diff-and-ask** ("Never silently overwrite a customization"), and
Phase 4 already re-stamps kept files with `--customized`, so `customized` is first-class. Concretely:
when F3 switches Phase 7 to `idc_receipt_check.py stamp`, pass
`--customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml`. (Options (b)
structured-merge and (c) always-ask are heavier; (a) is the minimal root-cause fix. Follow-up,
out of scope: letting a future update add the new `Stage:` field_ids slot without clobbering values
— (a) stops the data loss; operator re-runs init/doctor to populate Stage.)
**Verify:** extend the smoke suite — init a repo (writes `domains` into WORKFLOW-config.yaml), run
update non-interactively, assert `domains` survives (diff-and-ask defaults to keep). The
filesystem backend exercises the receipt-state logic even without a real board.

### F9 — [LOW] methodology doc note (this repo's `docs/dev/local-e2e-testing.md`)
Add a note: the marketplace clone auto-pulls main HEAD but the runtime **cache does not follow
it**; `${CLAUDE_PLUGIN_ROOT}` can resolve to the stale cache for one command and the fresh
marketplace for another in the same session; only `claude --plugin-dir <checkout>` reliably loads
uncached latest code. (This is the deferred methodology note — now in scope since you own this
repo's tree.)

---

## What is explicitly OUT of scope here (don't touch)

- The observability harness (`ke-snap*`, the sandbox `.git/hooks`) and the test methodology —
  those are fixed in the **sandbox** repo, not the plugin repo.
- `Stage` itself — it is correct and intentional (five-field is the live contract). Do **not**
  remove it. F2 brings the *one straggler* (doctor) up to it; it does not relitigate the design.
- Any broad refactor of `/idc:init` beyond F3/F4. No new abstractions.

---

## Addendum 2 — reconciliation against the relayed root-cause task (2026-06-14, post-PR-open)

A third relayed task (from a sandbox session) restated the stale-cache root cause and asked for
prevention-in-the-plugin. Cross-checked item-by-item; most was already in PR #38. Closed the
remaining gaps:

- **F10 — [NEW] `/idc:doctor` cache-freshness advisory (Fix 3 — "make staleness user-detectable").**
  Added doctor **check 7**: a read-only, **fail-open** (never FAIL) check that surfaces the running
  version (`${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`) and, best-effort, compares it to the
  marketplace clone (`$HOME/.claude/plugins/marketplaces/idc-workflow/...`), warning when the cache
  is stale with the exact `claude plugin update … --scope project` + re-enable fix. Reimplemented
  the comparison in-plugin (mirrors the sandbox `ke-preflight` idea; no dependency on the sandbox).
- **Release guard (Fix 2) — already present, choice flagged.** `scripts/idc_release_check.py`
  exists and runs in CI via `lint-references.sh` (ci.yml line 30 → Rule H). It uses a **git-free**
  mechanism (manifest lockstep + CHANGELOG-`## Unreleased`-content-without-bump) rather than the
  relayed task's git-diff "shippable-surface-changed-since-last-release." Deliberate: git-diff in a
  stdlib lint script breaks on shallow CI checkouts and risks false positives. The git-free guard
  catches the actual bug (the 2026-06-14 unreleased block with no bump). Known residual hole: a code
  change with *no* CHANGELOG entry at all won't trip it — relies on changelog discipline. Kept as-is;
  noted for a possible future git-aware CI-only variant.
- **Release-discipline doc (Fix 4) — strengthened.** `docs/dev/local-e2e-testing.md` now states the
  imperative ("every shippable change MUST bump the version") + the post-merge empirical check.
- **`verify --json` schema (secondary) — documented** in the `--json` arg help
  (`{unchanged, modified, missing, ok, summary}`).
- **Step 0 (empirical cache rebuild) — confirmed read-only, full proof is post-merge.** The cache IS
  version-keyed (`~/.claude/plugins/cache/idc-workflow/idc/` holds `0.1.0` + `2.0.0` dirs; the
  `2.0.0` cache still carries the stale 4-field template). The "fresh `idc/2.1.0/` cache appears"
  loop can only run once `2.1.0` is on `origin/main` (the clone tracks main), i.e. **after this PR
  merges** — recipe documented in `local-e2e-testing.md`.
