# plugin-lifecycle-phase-1-subphase-2 — `/idc:uninstall` command

**Upstream Master Plan Domain/Phase:** §Domain: plugin-lifecycle / §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall` (master row id: `plugin-lifecycle-phase-1-subphase-2`; source: `draft-master.md` staged for `docs/plans/master-implementation-plan.md`)
**Highest Affected Layer:** subphase
**No Higher-Layer Impact Rationale:** This subphase realizes an already-admitted master-plan row (`plugin-lifecycle-phase-1-subphase-2`) against spec invariants fixed in `docs/specs/master-architectural-spec.md §3` (staged); no PRD, spec, or master-plan edits are required — every scope item below traces to the row text, the spec resolutions, or the binding operator decisions in the absorbed consideration.
**Absorbed considerations:** `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12)
**Subphase trace key:** `plugin-lifecycle-phase-1-subphase-2`
**Canonical landing path:** `docs/plans/subphases/plugin-lifecycle-phase-1-subphase-2-uninstall-command-plan.md`

## Goal

Ship `/idc:uninstall` — a new command doc at `commands/uninstall.md` that is a phased, idempotent **mirror of `/idc:init`**: it removes every repo footprint IDC can prove it owns, in one revertable commit, after archiving work products to an announced tarball, behind a two-layer preflight, with GitHub left untouched by default — plus the operator-facing docs for it (an "Uninstalling" section in `docs/installing.md`, a `README.md` mention, a `CHANGELOG.md` Unreleased entry).

## Scope

- **New `commands/uninstall.md`** following `commands/init.md` conventions: phased structure (Phase 0 preconditions → preflight → archive → removal → summary), `created`/`skipped-*` idempotency vocabulary, summary table, fix hints, operator arguments line.
- **Receipt-driven removal manifest** — the removal set is the receipt (`docs/workflow/install-receipt.yaml`, per spec §3.1 — cited, not redefined here) **plus the hardcoded footprint list**, which permanently covers runtime-created footprints (notably `TRACKER.md` under the filesystem backend) and serves as the operator-confirmed fallback for pre-receipt or invalid-receipt installs (spec §3.1 writers, §3.5).
- **Announced archive tarball** — before any removal, work products are archived to an untracked repo-root `idc-archive-<date>.tar.gz`; the path is **always announced** (binding operator decision).
- **Two-layer preflight** — (a) clean git state for tracked files, **exempting** prior runs' untracked `idc-archive-*.tar.gz` so re-runs don't self-block; (b) board in-flight check with **warn-and-confirm** (never hard block, never silent skip); board-read failure surfaces the explicit "could not verify in-flight items" confirm posture (spec §3.5).
- **Single revertable commit** — scaffold, configs, `TRACKER.md` (filesystem backend only), and the `enabledPlugins["idc@idc-workflow"]` key stripped from `.claude/settings.json` while preserving every other key (the inverse of `commands/init.md` Phase 5's `jq` write).
- **GitHub opt-in destructive flags** — `--close-issues` (reversible) and `--delete-board` (permanent, **typed confirmation**); issue deletion is **never offered** (binding operator decisions; spec §3.3).
- **`skipped-absent` re-runs** — full idempotency per spec §3.4 vocabulary.
- **Failure postures (spec §3.5, cited)** — invalid/corrupt receipt: announce + explicit operator confirmation before the hardcoded fallback runs, never silent degradation; board read fails: explicit could-not-verify confirm.
- **Operator docs** — `docs/installing.md` "Uninstalling" section, `README.md` mention, `CHANGELOG.md` `## Unreleased` entry (folded into the single pillar; see §Rough Pillars rationale).

## Non-scope

- `/idc:upgrade` and the `docs/installing.md` "Updating" section (Phase 2, per master plan).
- Machine-global surfaces — `claude plugin uninstall` and `scripts/install-codex.sh --revert` are named in the closing summary for the operator to run separately, never run by the command (binding operator decision; PRD R2).
- Editing `commands/init.md` — uninstall points at the receipt file and spec §3 directly instead of cross-editing init's doc, resolving the master-level shared-surface candidate as read-only consumption (see Dependencies).
- The receipt **format itself** — defined by subphase-1 per spec §3.1; this subphase consumes it AS SPECIFIED and never redefines key names or fingerprint method.
- Board migration, issue deletion, any silent destructive path (spec §3.2, §3.5).
- New evalsets under `evals/` — explicitly dispositioned as deferred, not silently dropped: evals are dev tooling, not CI-required (per codebase-context packet; master-plan deferral list); a lifecycle evalset is better authored once after Phase 2 lands so one set covers install/uninstall/upgrade together.

## Dependencies

- **blocks_on: `plugin-lifecycle-phase-1-subphase-1`** (install-receipt substrate). Uninstall consumes the receipt as its removal manifest; the receipt format and `/idc:init` writer must land first. This subphase cites the receipt contract from spec §3.1 (location `docs/workflow/install-receipt.yaml`, SHA-256 of as-written bytes, `path`/`fingerprint`/`state` entries) and does not block on subphase-1's *pillar-level* key-spelling decisions — the command doc references the receipt file by path and defers exact-key reads to Build, which runs after subphase-1's pillars are merged.
- **Shared surfaces watched cross-subphase** (recorded for the parent's phase-wide clash analysis; not resolvable locally because subphase-1's pillar trace keys do not exist yet):
  - `commands/init.md` — subphase-1 edits it (receipt-writing); this subphase deliberately does NOT touch it (see Non-scope). No clash exists; if review forces an init.md cross-reference edit here, Resolution: serialize (subphase-1 first).
  - `CHANGELOG.md` `## Unreleased` — both subphases append entries. Append-only union surface; Resolution recommendation: union.
  - `docs/installing.md` — this subphase adds an "Uninstalling" section; if subphase-1 also edits installing.md (receipt mention), Resolution recommendation: union (disjoint sections), serialize if same-section.

## Spec resolutions binding on this subphase (cited, never redefined)

Per `draft-spec.md` (staged for `docs/specs/master-architectural-spec.md`) §3: receipt location + entry semantics (§3.1); compare surface fails toward asking (§3.2); provenance-gated destruction, single revertable commit, GitHub default-untouched, work-products archive (§3.3); idempotency vocabulary incl. `skipped-absent` (§3.4); the three failure postures (§3.5). Binding operator decisions from the consideration: issues never deleted (close only); `--delete-board` needs typed confirmation; archive path always announced; machine-global surfaces out of scope.

## Exit criteria

- `bash scripts/lint-references.sh` exits 0 with `commands/uninstall.md` present (new command docs are auto-in-scope of the reference-integrity lint).
- All `.github/workflows/ci.yml` jobs pass unchanged — this subphase touches no templates, no init substitutions, no scripts, so the template smoke-render must stay green without modification.
- Sandbox behavior checks (via `scripts/materialize-sandbox.sh` patterns): with a receipt fixture present, uninstall's enumeration phase lists exactly the receipt's files plus present hardcoded-list entries; a second run reports `skipped-absent` for every removed target; preflight blocks on a dirty tracked file but does NOT block on a leftover `idc-archive-*.tar.gz`. Each check scripted to exit 0.
- The `.claude/settings.json` strip preserves every non-IDC key (`jq` equality check exits 0).

## §Rough Pillars

> Recursive Fractal Distillation handoff — Deconflict polishes each subsection into a canonical pillar plan at `docs/plans/pillars/<subphase_id>-pillar-<n>-<pillar_slug>-plan.md`. Rough pillars live INLINE in this subphase plan; never as separate files. Per the folded `idc-develop` orchestrator (now `idc:idc-plan`) anti-pattern line 252, omitting this section makes the subphase plan non-canonical.

> *Pillar-count rationale (brief candidate split (a)+(b)):* the docs surface (installing.md section + README mention + CHANGELOG entry) is folded into the command-doc pillar rather than split out — it has no independent verification surface beyond the same lint, it would hard-serialize behind the command doc anyway (docs must describe the final command shape), and a second writer on a derived-prose surface is a drift risk with zero parallelism gain. One pillar.

### uninstall-command

**Rough scope:** Author `commands/uninstall.md` as a phased idempotent mirror of `commands/init.md` — two-layer preflight (clean-git exempting `idc-archive-*.tar.gz`; board in-flight warn-and-confirm with the could-not-verify posture), receipt-driven removal manifest with the hardcoded fallback and the invalid-receipt confirm posture, announced archive tarball, single revertable commit including the `enabledPlugins` strip, opt-in `--close-issues`/`--delete-board` (typed confirmation), `skipped-absent` re-runs — plus the folded operator docs (installing.md "Uninstalling" section, README mention, CHANGELOG Unreleased entry). Acceptance: `bash scripts/lint-references.sh` exits 0; sandbox enumeration matches the receipt exactly; second run reports `skipped-absent` throughout; settings strip preserves all other keys.

**File surfaces (write paths):**

| Path | Role | Co-owners |
|------|------|-----------|
| commands/uninstall.md | exclusive | (n/a) |
| docs/installing.md | exclusive | (n/a) |
| README.md | exclusive | (n/a) |
| CHANGELOG.md | shared | plugin-lifecycle-phase-1-subphase-1:receipt-format-and-init-writer |

**Dependencies:**

- Within-subphase: (none)
- Cross-subphase: `plugin-lifecycle-phase-1-subphase-1:receipt-format-and-init-writer` (refined blocks-on: receipt substrate; parent phase-wide clash pass resolves this to polished trace key `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer`)

**Parallel-safety hints:** serializes after `plugin-lifecycle-phase-1-subphase-1` pillars because uninstall consumes the receipt format + `/idc:init` writer that subphase lands; safe alongside any pillar not writing `commands/uninstall.md`, `docs/installing.md`, `README.md`, or the shared append-only `CHANGELOG.md` section. `CHANGELOG.md` `## Unreleased` is append-only across the two subphases (union recorded in phase clash evidence); `commands/init.md` is deliberately untouched by this pillar to avoid a shared write with subphase-1.

> *Note for polish:* the master plan defers two uninstall internals to pillar level — the tarball's internal layout and the exact preflight command sequences. The polished pillar resolves both (see pillar plan work packets); neither requires upstream edits.

## Wave-Orchestrator Handoff

### Work Units

| Work unit | Source pillar (§Rough Pillars) | Blocks on | Notes |
|-----------|-------------------------------|-----------|-------|
| `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command` | `uninstall-command` | `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer` (receipt substrate) | single pillar; docs folded in |

### Gates And Operator Decisions

- Subphase/pillar plans + clash evidence land autonomously; the parent Plan run's admission PR carries the standard pre-merge operator approval (WORKFLOW.md §4.2 — master-plan-only tier; no PRD/spec edits originate here).
- Binding operator decisions enforced in the pillar (from the absorbed consideration): issues never deleted (close only); `--delete-board` requires typed confirmation; archive path always announced; machine-global surfaces out of scope.
- Runtime operator gates inside the shipped command (not Plan-time gates): board in-flight warn-and-confirm; invalid-receipt fallback confirm; `--delete-board` typed confirmation.

### Canonical Ripple Notes

(none — no `ripple_flags` raised; all scope traces to the admitted master row, staged spec §3, and the absorbed consideration)
