# plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command

**Upstream Subphase:** `docs/plans/subphases/plugin-lifecycle-phase-1-subphase-2-uninstall-command-plan.md`
**Upstream Master Plan Domain/Phase:** §Domain: plugin-lifecycle / §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall` (master row id: `plugin-lifecycle-phase-1-subphase-2`)
**§Rough Pillars Source:** `### uninstall-command` (sole entry in the upstream subphase plan's `## §Rough Pillars`)
**Highest Affected Layer:** pillar
**Tracker Trace Key:** plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command
**No Higher-Layer Impact Rationale:** Pillar polish derives from the admitted §Rough Pillars entry; no PRD/spec/master-plan/subphase edits required — the two master-plan pillar-level deferrals it resolves (tarball layout, preflight command sequences) were explicitly delegated downward by the master plan.
**Admission Status:** ready

## Goal

Author `commands/uninstall.md` — a phased, idempotent mirror of `commands/init.md` that removes every IDC repo footprint in one revertable commit, receipt-driven with a hardcoded fallback, behind a two-layer preflight, archiving work products to an announced tarball, GitHub untouched by default — plus the folded operator docs (installing.md "Uninstalling" section, README mention, CHANGELOG entry).

## Scope

- New `commands/uninstall.md` (full command body; init.md conventions: phases, idempotency vocabulary, summary table, fix hints).
- Receipt consumption AS SPECIFIED in spec §3.1 (location `docs/workflow/install-receipt.yaml`; SHA-256 of as-written bytes; `path`/`fingerprint`/`state` entries) — cited, never redefined.
- Hardcoded footprint list (pillar-level resolution of the master-plan deferral; see UNINSTALL.2).
- Archive tarball internal layout (pillar-level resolution; see UNINSTALL.2).
- Exact preflight command sequences (pillar-level resolution; see UNINSTALL.1).
- `docs/installing.md` "Uninstalling" section, `README.md` mention, `CHANGELOG.md` `## Unreleased` entry.

## Non-scope

- `commands/init.md` — deliberately untouched (master-level shared-surface candidate resolved as read-only consumption; uninstall.md points at the receipt file + spec §3 instead).
- The receipt format definition, `/idc:init` receipt-writing, `ci.yml` smoke-render sync — all subphase-1.
- `/idc:upgrade`, installing.md "Updating" section — Phase 2.
- Machine-global surfaces (`claude plugin uninstall`, `install-codex.sh --revert`) — named in the closing summary only, never run.
- Board migration; issue deletion (never offered); any silent destructive path (spec §3.2/§3.5).
- New evalsets under `evals/` (explicitly deferred — dev tooling, not CI-required; revisit after Phase 2 so one evalset covers the whole lifecycle).

## Work Packets

### UNINSTALL.1 — Command skeleton + two-layer preflight

`commands/uninstall.md` frontmatter (description + argument-hint `[--close-issues] [--delete-board]`), idempotency preamble mirroring init.md, Phase 0 preconditions (git repo; `gh` auth only when the board check or GitHub flags are in play), then the two preflight layers. Layer 1 — clean git for **tracked** files (`git status --porcelain` filtered to tracked entries must be empty), with prior runs' untracked `idc-archive-*.tar.gz` explicitly exempt so re-runs never self-block. Layer 2 — board in-flight check through `idc:idc-skill-tracker-adapter` (backend from `docs/workflow/tracker-config.yaml`); in-flight = items with `Status` ∈ {`Active`, `Blocked`} or `ClaimState` ∈ {`Claimed`, `Running`, `RetryQueued`}; report plainly ("N items still in progress — uninstalling orphans them") behind an explicit warn-and-confirm gate. Board read fails → the explicit **"could not verify in-flight items"** confirm posture (spec §3.5): never a silent skip, never a hard block.

**File surfaces:** commands/uninstall.md
**Test targets:** no-test-added: no pytest harness in this repo; verified by `bash scripts/lint-references.sh` (exit 0) + sandbox preflight check (exit criteria)
**Acceptance criteria:** In a `scripts/materialize-sandbox.sh` sandbox: dirty tracked file → preflight blocks; leftover `idc-archive-*.tar.gz` only → preflight proceeds; both postures scripted and exiting 0. Doc text contains the could-not-verify confirm posture verbatim-equivalent to spec §3.5.

### UNINSTALL.2 — Removal manifest + archive tarball

The removal manifest is the union of (a) receipt entries read from `docs/workflow/install-receipt.yaml` per spec §3.1, and (b) the **hardcoded footprint list**, resolved here per the master-plan deferral: `WORKFLOW.md`, `WORKFLOW-config.yaml`, the `docs/workflow/` tree (scaffold + runtime work products inside it — archived first), `TRACKER.md` (filesystem backend only), and the `.claude/settings.json` `enabledPlugins["idc@idc-workflow"]` key (strip-not-delete; handled in UNINSTALL.3). The hardcoded list permanently covers runtime-created footprints (spec §3.1 writers) and doubles as the operator-confirmed fallback. Role-authored canonical docs (`docs/prd/`, `docs/specs/`, `docs/plans/`, `docs/considerations/`) are **not** in the manifest — init never created them ("only delete what you created", spec §3.3). Fingerprint compare per spec §3.2: any mismatch or unprovable entry fails toward confirm-before-remove, with the enumerated set shown. Invalid/corrupt receipt → announce + explicit confirmation before the fallback runs (spec §3.5), never silent degradation. Archive (resolves the deferral): before any removal, tar every manifest path that exists, at its repo-relative location, into untracked repo-root `idc-archive-<date>.tar.gz`; the path is **always announced**.

**File surfaces:** commands/uninstall.md
**Test targets:** no-test-added: no pytest harness; verified by sandbox enumeration check (exit criteria) + `bash scripts/lint-references.sh` (exit 0)
**Acceptance criteria:** Sandbox with a receipt fixture: the enumeration phase lists exactly the receipt's files plus present hardcoded-list entries (diff against expected list exits 0); the archive step runs before removal and the announced path exists; invalid-receipt fixture → doc instructs announce-and-confirm, never auto-fallback.

### UNINSTALL.3 — Single revertable commit + GitHub opt-ins + summary

One commit removes every manifest path and strips the enablement key — `jq 'del(.enabledPlugins["idc@idc-workflow"])'` preserving every other key (the inverse of init Phase 5's merge write; never delete `.claude/settings.json` itself). GitHub untouched by default; `--close-issues` closes (never deletes) board-linked issues, reversible; `--delete-board` is permanent and requires a **typed confirmation** (operator types the board title back); issue deletion is never offered anywhere. Re-runs report `skipped-absent` per target and produce no second commit. Closing summary: init-style status table (`removed` / `skipped-absent` / `archived`), the archive path, the revert hint (`git revert <sha>`), and the machine-global steps the operator runs separately (`claude plugin uninstall`, `bash scripts/install-codex.sh --revert`).

**File surfaces:** commands/uninstall.md
**Test targets:** no-test-added: no pytest harness; verified by sandbox re-run check + `jq` strip check (exit criteria)
**Acceptance criteria:** Sandbox: completed uninstall yields exactly one new commit; re-run yields zero new commits and `skipped-absent` for every target; `jq` equality check confirms all non-IDC settings keys survive the strip (exits 0); doc grep finds the typed-confirmation gate and the never-delete-issues statement (exits 0).

### UNINSTALL.4 — Operator docs fold-in

`docs/installing.md` gains an "Uninstalling" section (between "Set up a second machine" and the doctor troubleshooting section) documenting the command, the archive announcement, the GitHub flags + their gates, and the machine-global follow-ups. `README.md` gains a one-line command mention alongside init/doctor. `CHANGELOG.md` `## Unreleased` gains a prose bullet with rationale (repo convention).

**File surfaces:** docs/installing.md, README.md, CHANGELOG.md
**Test targets:** no-test-added: prose-only surfaces; verified by `bash scripts/lint-references.sh` (exit 0 — templates/commands scan) and CI manifest/template jobs passing unchanged
**Acceptance criteria:** Installing section present and consistent with the final uninstall.md phase names; CHANGELOG entry appended without touching existing entries; `bash scripts/lint-references.sh` exits 0.

## Dependencies

**Within-pillar:**
- UNINSTALL.2 after UNINSTALL.1; UNINSTALL.3 after UNINSTALL.2 (same file, phase order); UNINSTALL.4 after UNINSTALL.3 (docs describe the final command shape).

**Cross-pillar:**
- (none — single pillar in this subphase)

**Cross-subphase:**
- `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` — blocks-on: the receipt substrate (format + `/idc:init` writer, spec §3.1) must merge before Build dispatches this pillar.

## Parallel-safety markers

- `serial-after: plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` (cross-subphase blocks-on; receipt substrate consumed as removal manifest)
- `union-with: plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` for append-only `CHANGELOG.md ## Unreleased`, wave-ordered by the blocks-on edge.
- `parallel-safe-with: any pillar not writing commands/uninstall.md, docs/installing.md, README.md, or CHANGELOG.md` — command/docs surfaces are exclusive to this pillar; `CHANGELOG.md ## Unreleased` is the one shared append-only union surface with subphase-1 (cross-subphase evidence in Conflict Resolution)

## Pillar Resource Ownership

| Resource Kind | Resource ID | Ownership | Parallel-safe with |
|---------------|-------------|-----------|--------------------|
| file | commands/uninstall.md | exclusive | safe-with-all-non-overlapping (new file; no other pillar writes it) |
| doc | docs/installing.md | exclusive | safe-with-all-non-overlapping within this subphase; cross-subphase watch — if a subphase-1 pillar also edits installing.md, parent clash pass decides union (disjoint sections) vs serialize |
| file | README.md | exclusive | safe-with-all-non-overlapping (one-line mention) |
| file | CHANGELOG.md | shared | plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer (append-only `## Unreleased` union; wave-ordered after receipt substrate dependency) |

Blocks on: plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer | receipt substrate (format + `/idc:init` writer, spec §3.1) must merge before this pillar is dispatched
Wave: phase-1-wave-2 | sequencing hint only — uninstall consumes the receipt substrate that subphase-1's pillars land in the prior wave

## Test obligations

- no-test-added: this repo ships no pytest harness (`tests/` absent); the architectural fences are CI-level — `scripts/lint-references.sh` (reference integrity over `agents skills commands templates`), `.github/workflows/ci.yml` (manifests, template smoke-render, `bash -n scripts/*.sh`) — plus the sandbox behavior checks named per work packet and in Exit criteria.

## Operator gates

- Standard pre-merge review on the Build implementation PR (no PRD/spec/master-plan edits originate here, so no Engineer Gate fires).
- Runtime gates shipped INSIDE the command (behavior, not Plan/Build gates): board in-flight warn-and-confirm; invalid-receipt fallback confirm; `--delete-board` typed confirmation.

## Exit criteria

- `bash scripts/lint-references.sh` exits 0 with all four written surfaces in place.
- Every `.github/workflows/ci.yml` job passes with **zero edits to ci.yml** (this pillar changes no templates, no init substitutions, no scripts).
- Sandbox check A (enumeration): in a `scripts/materialize-sandbox.sh` sandbox with a receipt fixture, the manifest enumeration lists exactly receipt files ∪ present hardcoded entries — diff vs expected exits 0.
- Sandbox check B (idempotency): post-uninstall re-run reports `skipped-absent` for every target and creates no second commit — `git rev-list --count HEAD` unchanged, check exits 0.
- Sandbox check C (preflight): dirty tracked file blocks; leftover `idc-archive-*.tar.gz` does not block — both scripted, exit 0.
- Settings strip: `jq` equality comparison shows every non-IDC key preserved — exits 0.
- Doc-posture greps over `commands/uninstall.md` (typed confirmation for `--delete-board`; archive path announced; could-not-verify confirm; issue deletion never offered) each exit 0.
- **[CONSTRAINTS]** don't-regress: `commands/init.md`, `templates/`, `.github/workflows/ci.yml`, `scripts/`, `evals/` untouched; `bash scripts/lint-references.sh` stays exit 0 repo-wide (not just on new files); existing `CHANGELOG.md` entries preserved verbatim (append-only); no new dependencies; init's template substitution set unchanged.

## Conflict Resolution

- **Paired pillar:** `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer`
  **Clash evidence:** `docs/workflow/pillar-conflicts/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-pillar-conflicts.md`
  **Resolution:** `union`

## Dispatch-grade work-unit IDs

- UNINSTALL.1
- UNINSTALL.2
- UNINSTALL.3
- UNINSTALL.4
