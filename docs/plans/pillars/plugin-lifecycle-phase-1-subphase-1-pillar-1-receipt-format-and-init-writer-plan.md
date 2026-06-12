# plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer

**Upstream Subphase:** `docs/plans/subphases/plugin-lifecycle-phase-1-subphase-1-install-receipt-plan.md`
**Upstream Master Plan Domain/Phase:** §Domain: plugin-lifecycle / §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall`
**§Rough Pillars Source:** `### receipt-format-and-init-writer` (§Rough Pillars, upstream subphase plan)
**Highest Affected Layer:** pillar
**Tracker Trace Key:** plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer
**No Higher-Layer Impact Rationale:** Pillar polish derives from the admitted §Rough Pillars entry; every serialization decision below is explicitly deferred to this layer by the master plan's deferral list — no PRD/spec/master-plan/subphase edits required.
**Admission Status:** ready

## Goal

Make the install receipt real: fix the exact YAML serialization of `docs/workflow/install-receipt.yaml` (semantics already pinned at spec §3.1) and extend `commands/init.md` with a receipt-writing phase that fingerprints every file init created this run — SHA-256 of final as-written bytes, computed at the end of a successful run — while keeping the `ci.yml` template smoke-render honest about init's new write surface.

## Scope

- **Receipt serialization (resolves master deferral "exact YAML key names"):**

  ```yaml
  receipt_version: 1
  fingerprint_method: sha256        # SHA-256 hex digest of the file's as-written bytes (post token-substitution)
  written_by: idc:init              # idc:init | idc:upgrade (upgrade is Phase 2 scope)
  written_at: 2026-06-12T14:00:00Z  # UTC ISO-8601, end of the successful run
  files:                            # sorted by path for deterministic diffs
    - path: WORKFLOW.md             # repo-relative
      fingerprint: 3a91c2…(64-char lowercase hex)
      state: stamped                # stamped | customized (spec §3.1 enum; init only ever writes stamped)
  ```

  Entry keys are exactly `path` / `fingerprint` / `state`, matching spec §3.1's vocabulary verbatim. The receipt never lists itself (it is the manifest of the scaffold, removed with it — spec §3.1) and never lists `TRACKER.md` (runtime-created; covered permanently by uninstall's hardcoded list — spec §3.1 writers).

- **Resolves master deferral "template vs init-generated": fully init-generated.** Fingerprints are computed per-install values, not substitutable tokens; a `templates/` receipt would carry either fabricated entries or placeholders the smoke-render's no-surviving-`{{`-tokens check can't meaningfully exercise. No new file lands in `templates/`.

- **New `commands/init.md` "Phase 7 — Write the install receipt"** (current "Phase 7 — Summary" renumbers to Phase 8):
  - Runs only after Phases 2–5 (and 6 when `--codex`) complete successfully — end-of-successful-run-only timing per spec §3.1.
  - Computes each fingerprint from **final on-disk bytes** (after Phase 4's late project-number substitution), e.g. `shasum -a 256 "$f"` / `sha256sum "$f"`.
  - **Coverage rule:** entries = every file Phase 2/3 marked `created` this run. Fresh install → receipt lists the full stamped set, all `state: stamped`. Gap-fill re-run with an existing receipt → existing entries preserved byte-for-byte, entries appended only for files created this run; nothing created → receipt untouched, reported `skipped-existing` (spec §3.4 vocabulary).
  - **Pre-receipt posture (non-silent):** receipt absent AND nothing created this run → init does **not** fabricate a receipt from files it cannot prove it wrote (provenance unproven → fail toward not-claiming, spec §3.2); it reports `install-receipt.yaml: not-written (pre-receipt install — run /idc:upgrade to graduate a receipt)` in the summary.
  - Receipt status (`created` / `skipped-existing` / the explicit not-written line) appears in the Phase 8 summary table.

- **`ci.yml` sync (master row's explicit obligation):** audit confirms the receipt phase adds **no new template tokens or substitutions** (receipt content is computed, not rendered), so the smoke-render substitution set is unchanged; update the smoke-render sync comment to also name the receipt phase ("init Phase 7 writes the computed receipt — no token substitution; nothing to render") and verify the comment's `Phase 3 + Phase 4` references stay accurate against the renumbered `commands/init.md`.

- **`CHANGELOG.md ## Unreleased`** entry documenting the receipt substrate (prose bullet with rationale, matching house style).

## Non-scope

- `/idc:uninstall` (subphase 1.2) and `/idc:upgrade` + receipt graduation + `docs/installing.md` "Updating" (Phase 2).
- `/idc:doctor` receipt awareness (master row admits init + ci sync only).
- Fingerprinting files init did not create this run; any `state: customized` write (upgrade-only per spec §3.1).
- `TRACKER.md`, board/tracker mutations, `templates/` additions, new evalsets under `evals/` (rationale in upstream subphase Non-scope).

## Work Packets

### receipt-format-and-init-writer-task-1 — Receipt format + init receipt-writing phase

Author the receipt serialization block (exact keys above, with a rendered example) inside the new `commands/init.md` Phase 7, plus the phase's procedure: fingerprint computation over final bytes, coverage rule, append-on-gap-fill, `skipped-existing` re-run posture, explicit pre-receipt not-written line, and the Phase 8 summary-table row. Renumber the Summary phase and sweep `commands/init.md` (and any in-repo references to "init Phase 7") for stale phase numbers.

**File surfaces:** commands/init.md
**Test targets:** bash scripts/lint-references.sh; bash scripts/materialize-sandbox.sh (sandbox artifact check per Exit criteria)
**Acceptance criteria:** A fresh-sandbox init run produces `docs/workflow/install-receipt.yaml` that passes the Exit-criteria YAML assertion and a `shasum -a 256` spot-check; re-run with no gaps reports `skipped-existing` for the receipt; pre-receipt simulation (receipt deleted, scaffold intact) reports the explicit not-written line; `lint-references.sh` exits 0.

### receipt-format-and-init-writer-task-2 — ci.yml smoke-render sync + CHANGELOG

Audit init's post-task-1 substitution set against the `ci.yml` smoke-render (expected result: unchanged set, comment updated to name the receipt phase and to keep `Phase 3 + Phase 4` references accurate against renumbering); add the `CHANGELOG.md ## Unreleased` entry.

**File surfaces:** .github/workflows/ci.yml, CHANGELOG.md
**Test targets:** ci.yml smoke-render step body executed locally; jq manifest checks; bash -n scripts/*.sh
**Acceptance criteria:** Smoke-render step body run locally exits 0 with "rendered YAML parses"; `grep -n "install-receipt" CHANGELOG.md` exits 0 within `## Unreleased`; no `ci.yml` comment references a stale init phase number.

## Dependencies

**Within-pillar:**
- `receipt-format-and-init-writer-task-2` serializes after `receipt-format-and-init-writer-task-1` (the sync audit needs task-1's final substitution surface).

**Cross-pillar:**
- (none — sole pillar in subphase 1.1.)

**Cross-subphase:**
- (none upstream — this pillar is the Train-1 substrate.) Downstream: every `plugin-lifecycle-phase-1-subphase-2` pillar blocks on this pillar (receipt format = 1.2's removal-manifest input). `commands/init.md` is a master-level shared-surface candidate resolved as read-only consumption by 1.2; `CHANGELOG.md` is the actual shared append-only surface. 1.2's pillar plans carry the matching `Blocks on:` directives.

## Parallel-safety markers

- `parallel-safe-with: (none — sole pillar in subphase 1.1; no intra-subphase pairs exist)`
- `union-with: plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command` for append-only `CHANGELOG.md ## Unreleased`, wave-ordered by the downstream blocks-on edge.
- Downstream constraint (declared for the matrix, enforced via 1.2's `serial-after`/`Blocks on:` directives): subphase-1.2 pillars serialize after this pillar because 1.2 consumes the receipt format fixed here; `CHANGELOG.md` is an append-only shared union surface recorded in pair-wise clash evidence.

## Pillar Resource Ownership

| Resource Kind | Resource ID | Ownership | Parallel-safe with |
|---------------|-------------|-----------|--------------------|
| file | commands/init.md | exclusive | safe-with-all-non-overlapping; subphase-1.2 consumes init behavior read-only through `commands/uninstall.md` and serializes after this pillar for the receipt substrate |
| file | .github/workflows/ci.yml | exclusive | safe-with-all-non-overlapping |
| file | CHANGELOG.md | shared | plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command (append-only `## Unreleased` union; wave-ordered after receipt substrate dependency) |
| governance | install-receipt-format | exclusive | this pillar defines the contract; subphase-1.2 uninstall + phase-2 upgrade consume it read-only |

Wave: wave-1 | Train-1 substrate — must land before any subphase-1.2 pillar admits (receipt format is their removal-manifest input).

## Test obligations

- `no-test-added: repo has no tests/ harness (no tests/test_arch_*.py); verification rides the CI fences (lint-references, manifest jq, template smoke-render, bash -n) plus the runnable sandbox artifact check named in Exit criteria.`

## Operator gates

(none — pillar plans are autonomous; the master-plan pre-merge gate is exercised by the parent Plan run.)

## Exit criteria

- `bash scripts/lint-references.sh` exits 0 (new `commands/init.md` references resolve; any deliberate lint-allow is tracked in `docs/dev/known-debts.md`).
- The `ci.yml` "Template smoke-render" step body, run locally as a script, exits 0 and prints "rendered YAML parses".
- `for s in scripts/*.sh; do bash -n "$s"; done` exits 0; `jq empty .claude-plugin/plugin.json && jq empty .claude-plugin/marketplace.json` exits 0.
- Sandbox artifact check exits 0: `bash scripts/materialize-sandbox.sh /tmp/idc-receipt-sandbox --fresh`, execute init's scaffold + receipt phases against it per `commands/init.md` (Phases 2–3 + Phase 7; board provisioning stubbed with a fixed project number), then:
  `python3 -c "import yaml; d=yaml.safe_load(open('docs/workflow/install-receipt.yaml')); assert d['receipt_version']==1 and d['fingerprint_method']=='sha256' and d['files'], 'header'; [e for e in d['files'] if not ({'path','fingerprint','state'} <= set(e) and len(e['fingerprint'])==64 and e['state'] in ('stamped','customized'))] == [] or (_ for _ in ()).throw(AssertionError('entry shape'))"` exits 0,
  one entry spot-checked with `shasum -a 256 <path>` matching its `fingerprint`, and `WORKFLOW.md`'s entry fingerprint reflecting post-Phase-4 bytes (substituted project number), and no entry for `install-receipt.yaml` itself or `TRACKER.md`.
- `grep -n "install-receipt" CHANGELOG.md` exits 0 (entry under `## Unreleased`).
- `[CONSTRAINTS]` don't-regress: existing init behavior is preserved for all current targets — Phase 0–6 procedures, idempotency vocabulary, and the Phase 3/4 substitution set are untouched (no new template tokens); no writes outside this pillar's owned surfaces (`commands/init.md`, `.github/workflows/ci.yml`, `CHANGELOG.md`); no edits to canonical docs, `templates/`, `scripts/`, uninstall/upgrade surfaces, or evalsets; all four existing CI steps stay green.

## Conflict Resolution

- **Paired pillar:** `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command`
  **Clash evidence:** `docs/workflow/pillar-conflicts/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-pillar-conflicts.md`
  **Resolution:** `union`

## Dispatch-grade work-unit IDs

- receipt-format-and-init-writer-task-1
- receipt-format-and-init-writer-task-2
