# Master Architectural Spec — IDC Workflow Plugin

**Upstream trace:** §2 foundations are seeded from `docs/architecture.md` (pre-IDC architecture doc); §3 lifecycle architecture is admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12). Realizes PRD requirements R1–R3 and the §6 cross-cutting safety requirement (`docs/prd/prd.md`).

> First architectural spec authored for this repository (chain-bootstrap admission). §2 restates the existing IDC architecture compactly so the spec is self-contained; the new material is §3 (the plugin-lifecycle architecture).

## 1. Scope

This spec governs the IDC Workflow plugin's architecture: the role chain and write-authority model it already ships (§2, absorbed from `docs/architecture.md`), and the **plugin-lifecycle substrate** this admission adds (§3) — the committed install receipt and the install/upgrade/uninstall commands that produce and consume it. The receipt is a new **shared substrate**, so its contract (location, fingerprint method, entry semantics, writers, failure postures) is fixed here at the architectural layer; per-command implementation detail is deferred to subphase/pillar plans.

## 2. Foundations (absorbed from `docs/architecture.md`)

Compact restatement; `docs/architecture.md` is the long-form source.

- **Role chain.** Five roles run as a chain — Think → Plan → Sequence → Build — with **Ripple** as the drift escape hatch triggerable from any role. The canonical document chain is PRD → architecture spec → master implementation plan → subphase plans → pillar plans → TRACKER.
- **Write-authority boundaries.** Each role is the **sole writer** of its surface and edits nothing upstream of it. A lower role that finds a higher layer wrong does not fix it; it files a Ripple and pauses. (Authority table: `docs/architecture.md §Write-authority boundaries`.)
- **Engineer Gate.** PRD / arch-spec edits need operator approval before drafting **and** before merge; master/subphase/pillar plan edits need approval before merge; subphase plans, pillar plans, clash evidence, and the planning manifest are autonomous.
- **Two edit pipelines.** A `codebase` pipeline (Think → Plan → Sequence → Build) and a lighter `governance` pipeline (Audit → Plan → PR); every change order declares its `Pipeline:`.
- **Tracker contract.** Sequence and Build coordinate through a tracker selected by `backend:` in `docs/workflow/tracker-config.yaml` — `github` (Projects v2 board, **eight canonical fields**: `Status`, `ClaimState`, `Wave`, `Phase`, `Track`, `Lane`, `Domain`, `Pillar trace key`) or `filesystem` (a root `TRACKER.md`). The backend is hidden behind `idc:idc-skill-tracker-adapter`.
- **Composition.** Commands (`commands/*.md`) are slash entry points; agents (`agents/*.md`) are orchestrators + teammates; skills (`skills/*/SKILL.md`) are reusable procedures. `${CLAUDE_PLUGIN_ROOT}` resolves to the install path inside command/agent/skill bodies (it is text-substituted, **not** a shell env var).
- **Required trace.** Subphase plans record their upstream master §Domain/§Phase; pillar plans record their upstream subphase + tracker trace key; tracker edits cite a pillar-derived unit.

## 3. Plugin-lifecycle architecture (this admission)

### 3.1 The install receipt — shared substrate

The install receipt is a **committed scaffold file** that records every file `/idc:init` stamps, each with a content fingerprint of the file **as written** (post token-substitution, not the template) (per consideration §Named Ideas: install receipt; §Engineering Implications).

- **Canonical location (RESOLVED).** `docs/workflow/install-receipt.yaml` — a sibling of the existing `docs/workflow/tracker-config.yaml`, inside the governance tree `/idc:init` already scaffolds. Rationale: committed (travels with clones), discoverable next to the other per-project IDC config, YAML to match repo convention (`WORKFLOW-config.yaml`, `tracker-config.yaml`), and naturally covered by the clean-git preflight and removed inside uninstall's single revertable commit. The receipt is the manifest of the scaffold; it does not need to fingerprint-gate its own removal (it is removed as part of the scaffold it lists).
- **Fingerprint method (RESOLVED).** A **SHA-256 hex digest of the file's as-written bytes**. Chosen because the repo has no pre-existing hashing convention to inherit (per consideration §Next Role Questions; nothing in the repo hashes files today), and because the same method must be computed identically by `/idc:init` (write), `/idc:upgrade` (compare), and `/idc:uninstall` (compare) — a single fixed method is what makes the compare surface trustworthy. The exact YAML key names and serialization are pillar-level (see master plan deferrals).
- **Entry semantics (RESOLVED).** Each receipt entry records: the repo-relative `path`, the `fingerprint` (SHA-256 of the as-written bytes), and a `state` marker ∈ `{stamped, customized}`:
  - `stamped` — IDC authored the file; the fingerprint is IDC's render. Upgrade MAY silently re-stamp this file **iff** the on-disk fingerprint still matches.
  - `customized` — the operator kept their own version at a `/idc:upgrade` diff-and-ask; the fingerprint is the **operator's kept-content bytes** (not the template fingerprint, not excluded). Upgrade MUST NOT silently re-stamp a `customized` file; it re-enters diff-and-ask when a newer template render is available, and detects further operator edits by recomputing against the recorded kept-content fingerprint. Recording the template fingerprint would make a kept customization indistinguishable from a pristine file (silent-restamp risk); excluding the file would lose drift detection. This same marking is written identically at **receipt graduation** and at the **end-of-run rewrite**, satisfying the consideration's "same answer for graduation and the end-of-run rewrite" requirement (consideration §Open Decisions).
- **Writers (RESOLVED).** The receipt is written by `/idc:init` and `/idc:upgrade` **only**. Runtime-created footprints (notably `TRACKER.md` under the filesystem backend) are **not** added to the receipt — `/idc:init` never writes `TRACKER.md`, so it cannot fingerprint it, and routing receipt mutations through the tracker adapter would put a Build/Sequence-time surface inside an init/upgrade-owned artifact. Such runtime-created footprints are instead covered permanently by `/idc:uninstall`'s **hardcoded footprint list** — which is therefore a permanent complement to the receipt, not merely a pre-receipt fallback (consideration §Open Decisions: runtime-created footprints).
- **Rewrite timing.** The receipt is written **once** by `/idc:init` at the end of a successful install, and rewritten by `/idc:upgrade` **only at the end of a successful run** — so a half-done run can never leave a receipt that masquerades as finished (per consideration §Named Ideas: re-run to repair).

### 3.2 The safety-critical compare surface

`/idc:upgrade` and receipt-driven `/idc:uninstall` both recompute on-disk fingerprints and compare them against the receipt. **Invariant (load-bearing):** this compare MUST **fail toward asking** — show-diff-and-ask on upgrade, confirm-before-remove on uninstall — and MUST NEVER fail toward a silent re-stamp or a silent delete (per consideration §Engineering Implications; PRD §6). Every ambiguity in the compare resolves to the more conservative, operator-confirming branch.

### 3.3 Provenance-gated destructive operations

Destructive lifecycle operations are gated on **provenance** — acting only on what IDC demonstrably created — mirroring the pattern already shipped in `/idc:init`'s Status-field reconciliation (board created this run → safe to mutate; linked board already matching → no-op; linked board with items → fail closed to the snapshot/rebuild SOP) (per `commands/init.md`; `CHANGELOG.md` Unreleased).

- **"Only delete what you created."** `/idc:uninstall`'s removal set is the receipt (the manifest of what init wrote) plus the hardcoded footprint list for runtime-created files. The in-repo precedent is `scripts/install-codex.sh --revert`, which records pre-install state and only ever deletes symlinks it created, failing loudly rather than touching unrecorded data (per consideration §Context Notes; `scripts/install-codex.sh`).
- **Single revertable commit.** All repo footprint removals land in **one** commit — scaffold, configs, `TRACKER.md` (filesystem backend only), and the `enabledPlugins["idc@idc-workflow"]` key stripped from `.claude/settings.json` while preserving every other key (the inverse of `/idc:init` Phase 5's `jq` write).
- **GitHub default-untouched.** `/idc:uninstall` leaves GitHub alone unless the operator opts in: `--close-issues` (reversible) and `--delete-board` (permanent, typed confirmation). Issue deletion is never offered.
- **Work products preserved.** Before removal, work products are archived to an untracked repo-root `idc-archive-<date>.tar.gz`, path always announced.

### 3.4 Idempotency vocabulary

All lifecycle commands carry `/idc:init`'s idempotency contract — each step checks current state, present targets are left untouched — extended with two new statuses (per `commands/init.md`; consideration §Engineering Implications):

| Status | Meaning | Used by |
|--------|---------|---------|
| `created` | target written this run | init, upgrade |
| `skipped-existing` | target already present, left untouched | init |
| `skipped-absent` | target already gone, nothing to remove | uninstall re-runs |
| `skipped-already-current` | target already matches the current template | upgrade re-runs |

### 3.5 Failure-path postures (never silent) — spec invariants

The following failure paths have **fixed, non-silent postures** (per consideration §Open Decisions: failure-path postures):

- **Receipt present but invalid/corrupt.** Never silently degrade to the hardcoded fallback. The command announces the invalidity and requires **explicit operator confirmation** before any fallback path runs — for `/idc:uninstall`, before falling back to the hardcoded footprint list; for `/idc:upgrade`, before treating the install as pre-receipt (diff-and-ask everything once). Consistent with §3.2 (fail toward asking).
- **Board read fails at `/idc:uninstall` preflight.** The in-flight check is reported as an **explicit "could not verify in-flight items" outcome requiring confirmation** to proceed — not a silent skip and not an automatic hard block. (Default GitHub-untouched posture means proceeding does not delete issues; the residual risk is orphaning unseen in-flight items, which the operator confirms knowingly.)
- **Board drift check cannot run at `/idc:upgrade`.** The drift check has exactly **three** reportable outcomes — `no drift`, `drift detected (enumerated)`, and `could not verify` — and the third is always distinct from "no drift". Upgrade never reports "no drift" when the check did not execute.

### 3.6 Board-drift detection (upgrade, report-only)

`/idc:upgrade` is **files-only** and never mutates the board. It compares the live board's schema against the new plugin version's expected eight-field contract (per §2 tracker contract) and reports drift explicitly per §3.5. No board-migration machinery exists (rejected — real risk to live issues and in-flight waves; per consideration §Named Ideas: upgrade scope).

### 3.7 Version/stamp markers — current absence

No version or install-stamp markers exist in stamped files today; `templates/WORKFLOW-config.yaml`'s `workflow.version` is a **schema** version, not an install stamp (per consideration §Context Notes). The install receipt is therefore the **first** install-provenance artifact in the repo; upgrade's "is the running plugin the newest version" question is answered by the cache-refresh advisory (PRD R3), not by a stamp comparison in v1.

## 4. Downstream-sync & fence obligations

Enumerated in the companion side-files `ripple-targets-spec.md` and `fitness-fences-spec.md` (this admission). The lifecycle architecture is realized by Build, per pillar plans, under the master plan's §Domain: plugin-lifecycle (this admission) — the spec fixes invariants; it authors no source, tests, or command bodies.
