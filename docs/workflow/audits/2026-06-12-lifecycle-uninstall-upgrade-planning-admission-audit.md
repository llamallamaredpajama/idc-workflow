---
audit_kind: planning-admission-audit
role: plan
run_id: 2026-06-12-lifecycle
slug: lifecycle-uninstall-upgrade
audit_date: 2026-06-12
authored_in_branch: idc-plan/lifecycle-uninstall-upgrade
lands_in_pr_branch: true
considerations_absorbed_count: 1
drafts_count: 9
reviewer_findings_total: 2
fixer_loops_run: 1
ripple_stubs_count: 0
operator_gates_exercised_count: 2
---

# Planning admission audit — lifecycle-uninstall-upgrade

## 1. Run inputs

- run_id: `2026-06-12-lifecycle`
- branch/worktree: `idc-plan/lifecycle-uninstall-upgrade` at `.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade/`
- consideration absorbed: `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md`
- proposed canonical edits:
  - PRD: yes — new `docs/prd/prd.md`
  - Master architectural spec: yes — new `docs/specs/master-architectural-spec.md`
  - Master implementation plan: yes — new `docs/plans/master-implementation-plan.md` with `§Domain: plugin-lifecycle` and Phase 1/2 train split
  - Subphase plans: yes — Phase 1 subphase 1.1 + 1.2
  - Pillar plans: yes — two Phase 1 pillars
  - Phase planning manifest: yes — `docs/workflow/phase-planning/plugin-lifecycle-phase-1-planning-manifest.yaml`
  - Matrix: yes — `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml` plus DAG / parallel-safety / waves siblings
  - Clash evidence: yes — append-only `CHANGELOG.md` union evidence for the two Phase 1 pillars

## 2. Governance verdict

The consideration is `Ready`; the fresh repo's canonical PRD/spec/master chain was absent, so this run is a chain-bootstrap admission. Pre-drafting Engineer Gate approval was captured before the interrupted session wrote the PRD/spec/master drafts; pre-merge Engineer Gate approval remains pending and blocks merge.

### Considerations admissibility packet

```markdown
---
review_kind: considerations-admissibility
triage_scope: engineer-admission
file_path: /Users/jeremy/dev/proj/idc-workflow/.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade/docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md
verdict: Ready
domain: plugin-lifecycle-uninstall-upgrade
authored_date: 2026-06-12
---

# Considerations admissibility — plugin-lifecycle-uninstall-upgrade

## 1. Verdict + rationale

**Ready.** The consideration is structurally complete for admission: ~15 settled design decisions with rejected alternatives named, explicit engineering implications, source pointers into the live repo, and a clear two-train sequencing preference. Its three open-decision clusters are enumerated with concrete options and are exactly the decisions the Engineer Gate conversation resolves before/while drafting — none blocks starting authorship. Caveat: this is a **chain-bootstrap admission** — no PRD, architectural spec, or master plan exists in the repo (`docs/prd/`, `docs/specs/`, `docs/plans/` all absent), so every recommended anchor below is a section in a NEW canonical doc, and the Engineer Gate fires at full strength (approval before drafting AND before merge for PRD + spec). No supersession: `docs/workflow/audits/` and `docs/workflow/ripple/` are empty (`.gitkeep` only).

## 2. Open questions still pending operator decision

- "Receipt schema internals: field shape, fingerprint method, exact filename/path within the scaffold; what a receipt entry records for files the operator kept customized at diff-and-ask (mark customized / template fingerprint / exclude) — same answer for graduation and the end-of-run rewrite, else the next upgrade treats kept customizations as 'untouched' and silently re-stamps them." (§Open Decisions)
- "Runtime-created footprints (TRACKER.md): does the tracker adapter append them to the receipt on first write, or does the hardcoded list permanently cover them (making it more than a pre-receipt fallback)?" (§Open Decisions)
- "Failure-path postures, never silent: receipt present but invalid (abort loudly vs announce-and-confirm fallback); board read fails at uninstall preflight (hard block vs explicit 'could not verify in-flight items' confirm); board drift check cannot run (third explicit outcome, distinct from 'no drift')." (§Open Decisions)
- "Operator sequencing preference for Plan to weigh (preference, not a verdict): two trains, uninstall first — Train 1 = /idc:init receipt-writing + /idc:uninstall; Train 2 = /idc:upgrade + installing.md updating section. Rejected by operator: one combined train (bigger, slower, riskier)." (§Next Role Questions)
- "Should the receipt fingerprint method follow an existing repo hashing convention, and where exactly should the receipt live in the scaffold?" (§Next Role Questions)
- "How should upgrade surface the cache-refresh quirk to operators (preflight note vs docs-only)?" (§Next Role Questions)

## 3. Cross-domain references

- `commands/init.md` — /idc:init gains a new write surface (the receipt) + fingerprinting of stamped files; existing idempotency vocabulary (`created`/`skipped-existing`) and the `enabledPlugins` jq write are mirrored/inverted by uninstall. (Same repo, installer domain — coupling, not a foreign canonical doc.)
- `scripts/install-codex.sh` — `--revert` recorded-state manifest is the in-repo precedent for "only delete what you created" (read-only precedent).
- `docs/installing.md` — Train 2 adds an "Updating" section (doc surface today has none).
- `idc:idc-skill-tracker-adapter` / tracker skills — uninstall preflight needs a board in-flight read; upgrade needs a board-schema drift compare; open decision on whether the adapter appends runtime-created TRACKER.md to the receipt.
- No cross-domain canonical anchors exist to collide with — the repo has no other admitted domains (fresh chain).

## 4. Recommended canonical-doc anchor landings (all NEW docs — chain bootstrap)

| # | Consideration finding | Recommended anchor | Doc layer |
|---|------------------------|---------------------|-----------|
| 1 | Install receipt as shared committed substrate (manifest + content fingerprints) | PRD §Install receipt substrate; arch-spec §Receipt schema & fingerprint compare | prd + arch-spec |
| 2 | /idc:uninstall — phased idempotent mirror of init; archive tarball; one revertable commit; receipt-driven removal with hardcoded fallback | PRD §/idc:uninstall; arch-spec §Uninstall removal pipeline | prd + arch-spec |
| 3 | Uninstall preflight, two layers (git-clean w/ archive exemption + board in-flight warn-and-confirm) | arch-spec §Uninstall preflight | arch-spec |
| 4 | /idc:upgrade — receipt-only detection v1; silent re-stamp only on proven-untouched; diff-and-ask otherwise | PRD §/idc:upgrade; arch-spec §Upgrade detection | prd + arch-spec |
| 5 | Upgrade scope: files only + board-drift detection (report-only, never mutate) | arch-spec §Board schema drift check | arch-spec |
| 6 | Receipt graduation (first upgrade on pre-receipt repo writes fresh receipt) + re-run-to-repair idempotency (receipt rewritten only at end of successful run) | arch-spec §Idempotency & receipt lifecycle | arch-spec |
| 7 | Two-train sequencing (Train 1: init receipt + uninstall; Train 2: upgrade + installing.md) | master plan §Domain: plugin-lifecycle, §Phase 1 / §Phase 2 | master-plan |
| 8 | Status vocabulary extension: skipped-absent, skipped-already-current | arch-spec §Idempotency vocabulary | arch-spec |
| 9 | GitHub opt-in teardown flags (--close-issues reversible, --delete-board typed confirmation) | PRD §/idc:uninstall (flags) | prd |

## 5. Triage-scope-specific notes (engineer-admission)

Structurally the consideration spans all three canonical shapes at once — PRD-shape (product behavior of two new commands + flags + operator-facing postures), arch-spec-shape (receipt schema, fingerprint compare as the safety-critical surface, failure-path postures, idempotency contract), and master-plan-shape (two-train phasing with uninstall first). Because the canonical chain is entirely absent, admission means **authoring PRD + arch-spec + master plan as new documents** seeded partly by the pre-IDC `docs/architecture.md` (which covers the existing plugin: role chain, write authority, tracker contract, command/agent/skill composition — useful spec seed but contains nothing about lifecycle commands). The Engineer Gate fires twice: approval before drafting AND before merge (PRD/spec); pre-merge only for the master plan. The open decisions in §2 should be put to the operator at the before-drafting gate so PRD/spec sections lock with answers, not placeholders.
```

### Governance trace audit packet

```markdown
# Governance Trace Audit — plugin-lifecycle-uninstall-upgrade (no master_section_id supplied)

**Subphase slug being drafted:** `(not yet derivable — chain-bootstrap run; proposed domain slug: plugin-lifecycle)`
**Verdict:** UNADMITTED
**Audit timestamp:** 2026-06-12T13:35:47Z

> Input-shape caveat: the operator supplied NO `--master-section` (brief: `master_section: (none supplied)`), and `docs/plans/master-implementation-plan.md` does not exist. The path-missing condition is not treated as a procedural `BLOCKED` because the absence of the master plan IS the audited fact: this is a fresh IDC install with the entire canonical chain absent (`docs/prd/`, `docs/specs/`, `docs/plans/` — all missing). `BLOCKED` semantics (upstream contradiction) do not apply; `UNADMITTED` is the faithful verdict.

## Verbatim trace declaration text

The drafter MUST NOT fabricate a trace declaration. No master-plan §Domain/§Phase heading exists to quote — the master implementation plan has not been authored. After the chain-bootstrap admission (PRD → arch spec → master plan) lands, re-run this audit against the new master plan's verbatim §Domain/§Phase heading to compose:

```
Upstream Master Plan Domain/Phase: <verbatim heading from the NEW docs/plans/master-implementation-plan.md>
```

## Cross-subphase dependency map

| Sibling subphase (path) | Dependency direction | Anchor (H2 or H3) | Notes |
|--------------------------|----------------------|-------------------|-------|
| (none) | (n/a) | (n/a) | `docs/plans/subphases/` does not exist; this run will create the first subphase plans in the repo |

## Architectural-fitness obligations triggered

| Fence file | Test name | Why this §Phase triggers it | Drafter must declare |
|------------|-----------|------------------------------|----------------------|
| (none) | (n/a) | (n/a) | (n/a) — repo has no `tests/` dir and no `test_arch_*.py` fences. CI-level fences that pillar plans should treat as fitness obligations instead: `scripts/lint-references.sh` (reference-integrity lint over `agents/ skills/ commands/ templates/ *.md`), `.github/workflows/ci.yml` (manifest validation, template smoke-render kept in sync with `commands/init.md` Phase 3+4 substitutions, shell-syntax check over `scripts/*.sh`) |

## Ripple change orders touching this section

| Change order file | Status | Highest affected layer | Open question for Develop |
|-------------------|--------|-------------------------|----------------------------|
| (none) | (n/a) | (n/a) | (n/a) — `docs/workflow/ripple/` contains only `.gitkeep` |

## Verdict rationale

`docs/plans/master-implementation-plan.md` is absent, as are `docs/prd/prd.md` and `docs/specs/master-architectural-spec.md` — there is no admitted §Domain/§Phase anywhere in the repo, so no subphase or pillar plan can carry a valid `Upstream Master Plan Domain/Phase` trace yet. This is the **expected chain-bootstrap path** for a fresh IDC install (board #4 provisioned 2026-06-12, zero tracker items), not a surprise halt. The run must admit master-plan scope first: author PRD + master architectural spec + master implementation plan as new canonical docs under the Engineer Gate (operator approval before drafting AND before merge for PRD/spec per WORKFLOW.md §4.2), seeding the spec partly from the pre-IDC `docs/architecture.md`. Only after the master plan lands can subphase plans declare their trace and this audit return `ADMITTED`.

## Halt routing (verdict ≠ ADMITTED)

- **UNADMITTED:** No master plan exists; no §Domain/§Phase anchor list to match against. Route: the Plan run itself performs the chain-bootstrap admission (Plan absorbed the Engineer role — WORKFLOW.md §4.2) — operate the Engineer Gate, author PRD + arch spec + master plan with a `§Domain: plugin-lifecycle` section and two-train phases (Train 1: init receipt + /idc:uninstall; Train 2: /idc:upgrade + installing.md), then re-run this audit before drafting subphase plans. Evidence of absence: `find docs/plans docs/prd docs/specs` → no such directories (2026-06-12, worktree @ 95d7ab4).
```

## 3. Drafted canonical documents (final stripped forms)

### 3a. PRD — `docs/prd/prd.md`

```markdown
# Product Requirements — IDC Workflow Plugin

**Upstream trace:** lifecycle requirements (§4 below) are admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12). The v0.1.0 baseline (§3) is summarized from `README.md` and `CHANGELOG.md`, not re-litigated.

> This is the first PRD authored for this repository (chain-bootstrap admission). It states what the IDC Workflow plugin is, who it serves, the existing shipped surface as a fixed baseline, and the new plugin-lifecycle requirements this admission adds.

## 1. Purpose

The IDC Workflow plugin packages **IDC** — the Iterative Development Chain — as an installable [Claude Code](https://claude.com/claude-code) plugin: a governed, tracker-driven, multi-agent workflow that carries software work from a raw idea to merged, reviewed code (per `README.md`). Its defining property is **traceability**: every line of built code walks back through a pillar plan, a master plan, an architecture spec, and a product requirement, and nothing in the plan drifts silently out of sync (per `README.md`; `docs/architecture.md §Required trace`).

The product's job is to install that workflow **cleanly and per-project** into a target repository and to keep it auditable over the repository's life. Today the plugin can be installed (`/idc:init`) but has **no exit path and no update path** (per consideration §Frame). This PRD adds those two lifecycle capabilities plus the shared substrate they require.

## 2. Users

The plugin's users are **operators** — the engineer who installs IDC into a repository and runs the role commands. Operators are not the plugin's developers; they consume the shipped commands, agents, and skills. The product's lifecycle obligations are written from the operator's seat:

- An operator must be able to install IDC into a repo, **remove it cleanly later**, and **update it safely** after a new plugin version ships, without hand-editing scaffold files or guessing which files IDC owns.
- Destructive steps must never surprise the operator: removals are announced, reversible where possible, and gated on explicit confirmation where permanent (per consideration §Named Ideas: uninstall).

## 3. Existing surface — v0.1.0 baseline (summarized, not re-litigated)

The shipped v0.1.0 surface is the fixed baseline this admission builds on. It is **not** reopened here (per `CHANGELOG.md` 0.1.0; `README.md`):

- **8 commands** — five role entry points (`/idc:think`, `/idc:plan`, `/idc:sequence`, `/idc:build`, `/idc:ripple`) plus `/idc:autorun`, `/idc:init` (idempotent per-repo scaffold + tracker provisioning), and `/idc:doctor` (read-only five-check verifier).
- **23 agents** and **38 skills** — role orchestrators, teammate roleplayers, and the reusable `idc-skill-*` substrate, including Codex-native adapters.
- **Per-project install model** — `/idc:init` scaffolds `WORKFLOW.md` + `docs/workflow/` from `templates/`, provisions (or links) a GitHub Projects v2 board with the eight IDC tracker fields, and enables the plugin **for that project only** by writing `enabledPlugins["idc@idc-workflow"]=true` into `.claude/settings.json` (per `commands/init.md`; `docs/installing.md`).
- **Two tracker backends** — `github` (Projects v2 board) and `filesystem` (a root `TRACKER.md`), hidden behind the tracker-adapter dispatch skill (per `docs/architecture.md §The tracker contract`).
- **Codex runtime support** — five `codex-idc-*` adapters wired by `scripts/install-codex.sh`, which records prior state and offers `--revert` (per `README.md §Codex support`).

`/idc:init` already carries an **idempotency contract** (anything present is left untouched and reported `skipped-existing`) that the new lifecycle commands inherit and extend (per `commands/init.md`).

## 4. Lifecycle requirements (this admission)

All requirements below are admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md`. Operator sequencing preference (consideration §Next Role Questions) is **two trains, uninstall first**; the master plan realizes this as Phase 1 (R1 + R2) and Phase 2 (R3 + R4).

### R1 — Install receipt (shared substrate)

`/idc:init` MUST write a **committed repo file** that lists every file it stamps plus a content fingerprint of each file **as written** (post token-substitution, not the template) (per consideration §Named Ideas: install receipt; §Engineering Implications). The receipt is the shared substrate both later commands consume: `/idc:upgrade` uses it to prove a file untouched; `/idc:uninstall` uses it as the removal manifest ("only delete what you created"). A committed file (rejected alternative: an untracked machine-local file) is required so the substrate travels with clones and is covered by git state checks.

### R2 — `/idc:uninstall`

A new command MUST remove all of IDC's repo footprints safely (per consideration §Named Ideas: uninstall):

- **Phased, idempotent mirror of `/idc:init`.** Re-runs report `skipped-absent`; nothing is half-removed.
- **Work products archived first** to an untracked repo-root `idc-archive-<date>.tar.gz`, whose path is always announced.
- **All repo footprints removed in ONE revertable commit** — scaffold, configs, `TRACKER.md` (filesystem backend only), and the `enabledPlugins` key stripped while preserving every other key in `.claude/settings.json`. The removal list is **receipt-driven**, with a hardcoded footprint list as fallback.
- **GitHub untouched by default.** Opt-in `--close-issues` (reversible) and `--delete-board` (permanent; requires typed confirmation). **Issue deletion is never offered.**
- **Two-layer preflight.** (a) Clean git state for tracked files, exempting prior `idc-archive-*.tar.gz` so re-runs don't self-block; (b) a board in-flight check that reports orphaning plainly and requires explicit confirmation (warn-and-confirm, not a hard block).
- **Machine-global surfaces are out of scope.** The closing summary names `claude plugin uninstall` and `scripts/install-codex.sh --revert` for the operator to run separately (per consideration §Context Notes).

### R3 — `/idc:upgrade`

A new command MUST refresh stamped files after a plugin update, safely (per consideration §Named Ideas: upgrade):

- **Receipt-only detection (v1).** Silently re-stamp ONLY files the receipt proves untouched; any customized file gets **show-diff-and-ask**. Pre-receipt installs get diff-and-ask for every file, **one time**, then the run ends by writing a fresh receipt (**receipt graduation**).
- **Files only; never mutates the board.** Upgrade MUST compare the live board schema against the new plugin version's expected schema and **report drift explicitly** — never silently, and never via board-migration machinery (rejected).
- **Re-run to repair.** Each step checks current state; re-runs report `skipped-already-current`. The receipt is rewritten ONLY at the end of a successful run, so a half-done upgrade can never look finished.
- **Surfaces the plugin cache-refresh advisory.** Upgrade MUST NOT silently assume the running plugin is the newest version; it surfaces the known cache quirk (a repo-edited plugin needs `claude plugin uninstall && install` because the install cache does not track the working tree — per `docs/dev/2026-06-12-v0.1.0-release-report.md` line ~140).

### R4 — `docs/installing.md` "Updating" section

`docs/installing.md` has no updating section today (per consideration §Context Notes). This admission's Train 2 MUST add one documenting `/idc:upgrade` and the cache-refresh advisory.

## 5. Out of scope

- Machine-global plugin removal and Codex-link revert (operator runs `claude plugin uninstall` / `install-codex.sh --revert` separately — per consideration §Context Notes).
- Board **migration** machinery — upgrade reports schema drift but does not mutate the live board (real risk to in-flight waves; rejected — per consideration §Named Ideas: upgrade scope).
- GitHub issue **deletion** — never offered by uninstall.
- Compare-against-prior-version-templates and layered all-three upgrade detection — rejected for v1 (per consideration §Named Ideas: upgrade).

## 6. Cross-cutting safety requirement

The fingerprint compare that both upgrade and receipt-driven uninstall depend on is **safety-critical**: it MUST fail toward **asking** (show-diff-and-ask / confirm), never toward a silent re-stamp or silent delete (per consideration §Engineering Implications). The architectural invariants that make this true — receipt location, fingerprint method, customized-file semantics, and failure-path postures — are specified in `docs/specs/master-architectural-spec.md §3` (this admission).
```

### 3b. Master architectural spec — `docs/specs/master-architectural-spec.md`

```markdown
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
```

### 3c. Master implementation plan — `docs/plans/master-implementation-plan.md`

```markdown
# Master Implementation Plan — IDC Workflow Plugin

**Upstream trace:** admitted from `docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md` (merged at `main` 95d7ab4, PR #12). Realizes `docs/prd/prd.md` (R1–R4) against the architecture in `docs/specs/master-architectural-spec.md §3` (this admission).

> First master implementation plan authored for this repository (chain-bootstrap admission). It admits one §Domain and two §Phase rough seeds. Per RFD, each §Phase carries a module sketch and a subphase **decomposition table only** — no subphase subsections, no candidate-pillar names. Subphase plans are Develop's authority (Phase 1 in this Plan run's continuation; Phase 2 in a later Plan run).

## §Domain: plugin-lifecycle

**Owns:** the lifecycle of an IDC install in a governed repo — installing, removing, and updating IDC's repo footprints — plus the committed **install receipt** substrate (`docs/specs/master-architectural-spec.md §3.1`) that ties the three operations together. The domain's organizing invariant is the safety-critical fingerprint compare (`spec §3.2`): every destructive or re-stamping action acts only on provenance IDC can prove, and ambiguity always fails toward asking.

**Does NOT own:** the IDC role chain itself (Think/Plan/Sequence/Build/Ripple behavior), tracker semantics beyond the schema-drift read, or machine-global plugin state (`claude plugin uninstall`, Codex link revert) — those are out of scope per PRD §5.

**Operator sequencing (admitted):** two trains, uninstall first (consideration §Next Role Questions). The §Phase split below mirrors that decision exactly.

---

### §Phase 1 — Train 1: install-receipt substrate (`/idc:init` receipt-writing) + `/idc:uninstall`

**Module sketch.** Phase 1 establishes the receipt substrate and the first command that consumes it. It owns two tightly-coupled deliverables: (a) making `/idc:init` fingerprint every file it stamps and write the committed `docs/workflow/install-receipt.yaml` at the end of a successful run (`spec §3.1`), and (b) a new `/idc:uninstall` command — a phased, idempotent mirror of `/idc:init` that uses the receipt as its removal manifest (with the hardcoded footprint list covering runtime-created files), archives work products to an announced `idc-archive-<date>.tar.gz`, removes all repo footprints in one revertable commit, and leaves GitHub untouched by default (opt-in `--close-issues` / `--delete-board`).

**Intentionally NOT in scope for Phase 1:** `/idc:upgrade` and the `docs/installing.md` "Updating" section (Phase 2); board migration; any silent destructive path (`spec §3.2`, `§3.5`).

**Exit criteria.** `/idc:init` writes a valid `docs/workflow/install-receipt.yaml` covering every stamped file (SHA-256 of as-written bytes); the CI template smoke-render is updated to match init's new write surface and CI is green; `/idc:uninstall` cleanly removes a fresh install in one revertable commit, reports `skipped-absent` on re-run, honors both preflight layers and their non-silent failure postures (`spec §3.5`), and its destructive GitHub options behave per `spec §3.3`.

**Subphase decomposition (rough seed — Develop polishes; this Plan run's continuation):**

| Subphase id | Name | One-line scope | Status |
|-------------|------|----------------|--------|
| `plugin-lifecycle-phase-1-subphase-1` | Install receipt substrate + `/idc:init` receipt-writing | Define the committed `docs/workflow/install-receipt.yaml` format (SHA-256 of as-written bytes; `path`/`fingerprint`/`state` entries) and make `/idc:init` fingerprint every stamped file and write the receipt at the end of a successful run; keep the `ci.yml` template smoke-render in sync with init's new write surface. | ready-for-subphase-planning |
| `plugin-lifecycle-phase-1-subphase-2` | `/idc:uninstall` command | New idempotent mirror-of-init command: receipt-driven removal manifest + hardcoded fallback for runtime-created footprints, announced archive tarball, two-layer preflight (clean-git exempting `idc-archive-*.tar.gz` + board in-flight warn-and-confirm), single revertable commit (scaffold/configs/`TRACKER.md`/`enabledPlugins` strip), GitHub opt-in `--close-issues`/`--delete-board`, `skipped-absent` re-runs. | ready-for-subphase-planning |

> Dependency note (for Develop/Sequence, not a pillar claim): `plugin-lifecycle-phase-1-subphase-2` consumes the receipt format and writer defined in `plugin-lifecycle-phase-1-subphase-1`; subphase-1 is the upstream substrate. `commands/init.md` is a shared-surface **candidate** for the subphase/pillar layer to evaluate because uninstall mirrors init's `enabledPlugins` and idempotency vocabulary, but the preferred decomposition is read-only consumption from `commands/uninstall.md`; any actual shared write surface must be declared and serialized at the subphase/pillar layer.

---

### §Phase 2 — Train 2: `/idc:upgrade` + `docs/installing.md` "Updating" section

**Module sketch.** Phase 2 adds the update path on top of the receipt substrate Phase 1 establishes. It owns the `/idc:upgrade` command — receipt-only detection that silently re-stamps only receipt-proven-untouched files, shows-diff-and-asks on customized files, treats pre-receipt installs as diff-and-ask-once then graduates a fresh receipt, rewrites the receipt only at the end of a successful run, and reports board-schema drift (report-only, three explicit outcomes; `spec §3.5`–`§3.6`) — plus the new `docs/installing.md` "Updating" section documenting the command and the plugin cache-refresh advisory.

**Intentionally NOT in scope for Phase 2:** board mutation/migration (report-only — `spec §3.6`); changing the receipt format set in Phase 1; any silent re-stamp (`spec §3.2`).

**Exit criteria.** `/idc:upgrade` re-stamps only `stamped` receipt entries whose on-disk fingerprint matches, diff-and-asks otherwise, graduates a receipt on a pre-receipt install, rewrites the receipt only on success, reports drift with the three distinct outcomes, surfaces the cache-refresh advisory, and reports `skipped-already-current` on re-run; `docs/installing.md` carries an "Updating" section; CI green.

**Subphase decomposition (rough seed — DEFERRED to a later Plan run per the two-train sequencing):**

| Subphase id | Name | One-line scope | Status |
|-------------|------|----------------|--------|
| `plugin-lifecycle-phase-2-subphase-1` | `/idc:upgrade` command | New command: receipt-only re-stamp detection, show-diff-and-ask for customized/pre-receipt files, receipt graduation + end-of-run-only rewrite, board-drift report-only with three explicit outcomes, cache-refresh advisory surfacing, `skipped-already-current` re-runs. | deferred-to-later-plan-run |
| `plugin-lifecycle-phase-2-subphase-2` | `docs/installing.md` "Updating" section | Author the missing "Updating" section documenting `/idc:upgrade` and the plugin cache-refresh advisory (`docs/dev/2026-06-12-v0.1.0-release-report.md` line ~140). | deferred-to-later-plan-run |

---

## Canonical-layer resolutions & explicit pillar-level deferrals (no silent gaps)

The consideration's open decisions are dispositioned here so nothing is silently dropped.

**Resolved at the canonical (spec) layer** — see `docs/specs/master-architectural-spec.md §3`:

- Receipt **location**: `docs/workflow/install-receipt.yaml` (`spec §3.1`).
- Receipt **fingerprint method**: SHA-256 of as-written bytes (`spec §3.1`).
- Receipt **entry semantics** incl. the customized-file rule (record kept-content fingerprint + `customized` marker; identical at graduation and end-of-run rewrite) (`spec §3.1`).
- Runtime-created footprints (`TRACKER.md`): covered permanently by uninstall's hardcoded list, not appended to the receipt (`spec §3.1` writers).
- Failure-path postures (invalid receipt; uninstall board-read failure; upgrade drift-check-can't-run) (`spec §3.5`).

**Deferred to subphase/pillar engineering (explicit — Build authors under Develop/Deconflict plans):**

- Exact YAML key names and on-disk serialization of `docs/workflow/install-receipt.yaml` entries (semantics fixed at `spec §3.1`; field spelling is pillar-level).
- Whether a receipt template lives in `templates/` or is fully init-generated (no version/stamp markers exist today — `spec §3.7`).
- The internal layout of the `idc-archive-<date>.tar.gz` work-product archive.
- Exact preflight command sequences (the clean-git check, the `idc-archive-*.tar.gz` exemption mechanism, the board in-flight query).
- How `/idc:upgrade` surfaces the cache-refresh advisory operationally (preflight note vs docs-only — PRD R3 fixes that it MUST surface; the surfacing form is pillar-level; the `docs/installing.md` "Updating" section in Phase 2 is the documentation half).
- Whether the lifecycle commands warrant new evalsets under `evals/` (dev tooling, not CI-required; planner judgment call per codebase-context packet).
```

## 4. Reviewer findings

### 4a. Initial custom review

### custom-phase3-review.md

```markdown
# IDC Plan Review — phase-wide — 2026-06-12-1535

**Target:** `/tmp/idc-plan/2026-06-12-lifecycle/`
**Brief:** `/tmp/idc-plan/2026-06-12-lifecycle/briefs/phase3-plan-review.md`
**Mode:** admission+subphase+pillar sweep
**Severity counts:** 0 Blockers · 1 Major · 0 Minor · 0 Nit

---

## Dimension coverage

| # | Dimension | Findings | Status |
|---|-----------|----------|--------|
| 1 | RFD / §Phase boundary kept | 0 | clean — master stops at domain/phase rows; Phase 2 rows remain deferred |
| 2 | Governance obligations addressed | 0 | clean — pre-drafting approval captured, pre-merge approval pending |
| 3 | Consideration open decisions resolved | 0 | clean — receipt location/fingerprint/runtime footprint/failure postures dispositioned |
| 4 | Ripple/downstream targets explicit | 0 | clean — downstream Sequence admission and Phase 2 deferral named |
| 5 | Fitness fences flagged | 0 | clean — no `tests/` harness; CI smoke-render/lint/bash-n named |
| 6 | Trace declarations complete | 0 | clean — subphase and pillar trace fields present |
| 7 | Authority boundaries respected | 1 | Major × 1 — scratch-only admission context remains at top of canonical-doc drafts |
| 8 | Rough-pillar / ownership schema | 0 | clean — rough sections present, ownership rows populated, shared `CHANGELOG.md` co-owner parity present |
| 9 | Clash / matrix coherence | 0 | clean — only `CHANGELOG.md` true shared write surface; resolution=union; P2 blocks_on P1 |
| 10 | Review evidence / stop gates | 0 | clean — pre-merge gate remains a stop condition |

---

## Blockers

None.

## Major

### Strip scratch-only admission context before canonical landing
- **Dimension:** Authority boundaries respected
- **Location:** `/tmp/idc-plan/2026-06-12-lifecycle/draft-prd.md:1`, `/tmp/idc-plan/2026-06-12-lifecycle/draft-spec.md:1`, `/tmp/idc-plan/2026-06-12-lifecycle/draft-master.md:1`
- **Confidence:** 95
- **What:** The first three canonical-doc drafts still include `<!-- ADMISSION CONTEXT — strip this block before committing ... -->` scaffolding. Landing those comments in `docs/prd/prd.md`, `docs/specs/master-architectural-spec.md`, or `docs/plans/master-implementation-plan.md` would violate the drafts' own instruction and expose scratch-only gate/injection text as canonical content.
- **Why it matters:** The PRD/spec/master docs must be canonical operator-facing documents, not Plan scratch packets. Keeping the scaffold would create stale references (including historical role names) and make future Plan/Ripple readers treat scratch instructions as canonical truth.
- **Suggested fix:** Before copying to canonical paths, strip each leading `<!-- ADMISSION CONTEXT ... <!-- END ADMISSION CONTEXT -->` block and the following separator from `draft-prd.md`, `draft-spec.md`, and `draft-master.md`; rerun structural validation.

## Minor

None.

## Nit

None.

---

## Scope detail

Consulted: handoff, `briefs/bundle-finisher.md`, PRD/spec/master drafts, both subphase bundles, both manifest shards, phase manifest, matrix YAML/siblings, clash evidence draft, `WORKFLOW.md`, `codex-idc-plan`, and shape skills (`idc-skill-rough-pillars-section`, `idc-skill-pillar-plan-shape`, `idc-skill-pillar-resource-ownership`, `idc-skill-pillar-matrix-synth`).
```

### 4b. Initial adversarial review

### codex-phase3-adversarial-review.md

```markdown
# IDC Plan Adversarial Review — plan — 2026-06-12-1535

**Target:** `/tmp/idc-plan/2026-06-12-lifecycle/`
**Brief:** `/tmp/idc-plan/2026-06-12-lifecycle/briefs/phase3-plan-review.md`
**Codex command:** inline Codex-native adversarial review (no `/codex:adversarial-review` command available in this harness)
**Severity counts:** 0 Blockers · 1 Majors · 0 Minors · 0 Nits

---

## Blockers

None.

## Major

### Canonical docs still contain scratch scaffolding that says to strip itself
- **Location:** `/tmp/idc-plan/2026-06-12-lifecycle/draft-prd.md:1`, `/tmp/idc-plan/2026-06-12-lifecycle/draft-spec.md:1`, `/tmp/idc-plan/2026-06-12-lifecycle/draft-master.md:1`
- **Codex severity (raw):** high
- **IDC bucket:** Major
- **Challenge:** If these files are copied verbatim per the handoff's landing map, the PR will canonize the scratch-only admission context block, including the explicit instruction to strip it and stale historical authority text.
- **Why it matters:** Future readers and automated lint/review passes will not be able to distinguish canonical requirements from Plan-run scaffolding.
- **Suggested resolution:** Strip the admission-context preamble from PRD/spec/master before canonical landing, then rerun structure/lint checks.

## Minor

None.

## Nit

None.

---

## Raw Codex output

Inline adversarial pass because `/codex:adversarial-review` is not exposed as an executable command in this Pi harness. Challenge focus: canonical-doc landing safety; Plan authority boundaries; Phase 1/2 scope separation; tracker mutation and pre-merge gate. Finding: one high-severity landing hazard, mapped to IDC Major above.
```

### 4c. Fixer dispositions

### phase3-fixer-dispositions.md

```markdown
# Phase 3 fixer dispositions — lifecycle Plan run

| Loop | Blocker in | Major in | Blocker out | Major out | Draft path out |
|------|------------|----------|--------------|-----------|----------------|
| 1 | 0 | 1 | 0 | 0 | `/tmp/idc-plan/2026-06-12-lifecycle/draft-prd.md`; `/tmp/idc-plan/2026-06-12-lifecycle/draft-spec.md`; `/tmp/idc-plan/2026-06-12-lifecycle/draft-master.md` |

## Applied fixes

- Stripped leading `<!-- ADMISSION CONTEXT ... <!-- END ADMISSION CONTEXT -->` blocks and following separator from the PRD, spec, and master-plan drafts before canonical landing.
- Reran `python3 /tmp/idc-plan/2026-06-12-lifecycle/validate-plan-scratch.py`; it printed `scratch structural validation: PASS`.
```

### 4d. Final custom re-review

### custom-phase3-review-final.md

```markdown
# IDC Plan Review — phase-wide — 2026-06-12-1545

**Target:** `/tmp/idc-plan/2026-06-12-lifecycle/`
**Brief:** `/tmp/idc-plan/2026-06-12-lifecycle/briefs/phase3-plan-review.md`
**Mode:** admission+subphase+pillar sweep
**Severity counts:** 0 Blockers · 0 Major · 0 Minor · 0 Nit

---

## Dimension coverage

| # | Dimension | Findings | Status |
|---|-----------|----------|--------|
| 1 | RFD / §Phase boundary kept | 0 | clean |
| 2 | Governance obligations addressed | 0 | clean — pre-merge gate pending and explicit |
| 3 | Consideration open decisions resolved | 0 | clean |
| 4 | Ripple/downstream targets explicit | 0 | clean |
| 5 | Fitness fences flagged | 0 | clean |
| 6 | Trace declarations complete | 0 | clean |
| 7 | Authority boundaries respected | 0 | clean — admission context stripped before canonical landing |
| 8 | Rough-pillar / ownership schema | 0 | clean |
| 9 | Clash / matrix coherence | 0 | clean |
| 10 | Review evidence / stop gates | 0 | clean |

---

## Blockers

None.

## Major

None.

## Minor

None.

## Nit

None.

---

## Scope detail

Final re-review after applying `phase3-findings-union.json` and `phase3-fixer-dispositions.md`. Fresh structural validation command: `python3 /tmp/idc-plan/2026-06-12-lifecycle/validate-plan-scratch.py` → `scratch structural validation: PASS`.
```

### 4e. Final adversarial re-review

### codex-phase3-adversarial-review-final.md

```markdown
# IDC Plan Adversarial Review — plan — 2026-06-12-1545

**Target:** `/tmp/idc-plan/2026-06-12-lifecycle/`
**Brief:** `/tmp/idc-plan/2026-06-12-lifecycle/briefs/phase3-plan-review.md`
**Codex command:** inline Codex-native adversarial re-review (no `/codex:adversarial-review` command available in this harness)
**Severity counts:** 0 Blockers · 0 Majors · 0 Minors · 0 Nits

---

## Blockers

None.

## Major

None.

## Minor

None.

## Nit

None.

---

## Raw Codex output

Inline adversarial re-review after patch. Checked canonical-doc landing safety, Plan authority boundaries, Phase 1/2 scope separation, tracker mutation exclusion, `commands/init.md` candidate resolution, `CHANGELOG.md` union evidence, and pre-merge Engineer Gate stop. No Blocker/Major/Minor/Nit findings remain.
```

## 5. Fixer disposition summary

| Loop | Blocker in | Major in | Blocker out | Major out | Disposition |
|------|------------|----------|--------------|-----------|-------------|
| 1 | 0 | 1 | 0 | 0 | Stripped scratch-only admission context from PRD/spec/master drafts before canonical landing. |

## 6. Ripple-downstream obligations identified

| # | Affected layer | Affected doc | Disposition | Ripple change-order pointer |
|---|----------------|--------------|-------------|------------------------------|
| 1 | Sequence/tracker order | GitHub Project #4 / future tracker issues | Downstream Sequence admits the two polished Phase 1 pillars after this Plan PR merges; no Ripple needed. | n/a |
| 2 | Phase 2 lifecycle upgrade train | Future Plan run | Deferred by master plan rows (`deferred-to-later-plan-run`); no same-PR Ripple. | n/a |

## 7. Architectural-fitness fences flagged

### fitness-fences-prd.md

```markdown
# Fitness fences — PRD (`docs/prd/prd.md`)

> **Architectural-fitness fence obligation.** Per root `CLAUDE.md §Architectural Fitness`, when a PR edits a load-bearing root-CLAUDE.md or subdir-CLAUDE.md directive OR adds a new auth surface / Cloud Run image / per-corpus embed pipeline / observability surface, add or update a `tests/test_arch_*.py` in the same commit. Reviewer-enforced; no pre-commit hook. Drafter emits a `fitness-fences-{prd,spec,master}.md` side-file naming every fence the diff would trigger. Reviewer verifies the side-file exists and that every triggered fence is either added/updated in the diff (Build's authority for the actual test code; Engineer flags the obligation) OR explicitly declared `no fence trigger` with rationale.

| Fence | Reason | New or Updated | Surface anchor |
|-------|--------|----------------|----------------|
| (none) | **No fence trigger.** This repo has no `tests/` directory and ships no `tests/test_arch_*.py` harness (per governance-trace audit, deliverable 3). A PRD edit under `docs/prd/` adds no auth surface, Cloud Run image, embed pipeline, or observability surface, and touches no CLAUDE.md directive. `docs/prd/` is outside the reference-integrity lint scope (`scripts/lint-references.sh` scans `agents skills commands templates` only). | — | — |

**Note for Build (Phase 1, not this layer):** the operative architectural-fitness fence in this repo is **CI-level**, not `tests/test_arch_*.py`. When Phase 1 changes `/idc:init`'s write surface (receipt-writing), the `.github/workflows/ci.yml` template smoke-render — which must stay in sync with `commands/init.md` Phase 3/4 substitutions — becomes load-bearing and must be updated in the same PR. That obligation is flagged at the spec and master-plan layers (`fitness-fences-spec.md`, `fitness-fences-master.md`); it does not trigger at the PRD layer.
```

### fitness-fences-spec.md

```markdown
# Fitness fences — Master Architectural Spec (`docs/specs/master-architectural-spec.md`)

> **Architectural-fitness fence obligation.** Per root `CLAUDE.md §Architectural Fitness`, when a PR edits a load-bearing root-CLAUDE.md or subdir-CLAUDE.md directive OR adds a new auth surface / Cloud Run image / per-corpus embed pipeline / observability surface, add or update a `tests/test_arch_*.py` in the same commit. Reviewer-enforced; no pre-commit hook. Drafter emits a `fitness-fences-{prd,spec,master}.md` side-file naming every fence the diff would trigger. Reviewer verifies the side-file exists and that every triggered fence is either added/updated in the diff (Build's authority for the actual test code; Engineer flags the obligation) OR explicitly declared `no fence trigger` with rationale.

| Fence | Reason | New or Updated | Surface anchor |
|-------|--------|----------------|----------------|
| (none — `tests/test_arch_*.py`) | **No Python arch-fitness harness exists.** This repo has no `tests/` directory (per governance-trace audit, deliverable 3). The spec edit adds architectural invariants but no auth surface / Cloud Run image / embed pipeline / observability surface, and edits no CLAUDE.md directive. The `test_arch_idc_workflow.py::test_role_boundaries_are_documented` fence referenced by the authority-boundary injects pins the **upstream** IDC role-authority table in root `CLAUDE.md`; this admission does not change that table, so the fence is not triggered. | — | — |

## Operative CI-level fences flagged for Build (Phase 1)

This repo enforces architectural fitness at **CI level** (`.github/workflows/ci.yml`), not via `tests/test_arch_*.py`. The §3 lifecycle architecture makes the following CI fences load-bearing for Build; Build authors/updates them in the implementing PRs (Engineer flags only):

- **Template smoke-render (`ci.yml`)** — must stay in sync with `commands/init.md` Phase 3/4 token substitutions. §3.1 adds a new `/idc:init` write surface (the receipt). When Phase 1 changes init's substitution/write set, the smoke-render must be updated in the same PR or CI fails. **This is the primary fence the receipt substrate trips.**
- **Reference-integrity lint (`scripts/lint-references.sh`)** — scans all `*.md` under `agents skills commands templates`. The new `commands/uninstall.md` (Phase 1) and `commands/upgrade.md` (Phase 2) are auto-in-scope; any new cross-references must resolve or carry a `lint-allow` comment tracked in `docs/dev/known-debts.md`.
- **Plugin manifest validation + `bash -n` over `scripts/*.sh`** — unaffected by the spec invariants unless Phase 1/2 adds a shell script; flagged for completeness.

**Rationale for surfacing at spec layer:** the safety-critical compare (§3.2) and provenance-gated destructive ops (§3.3) are exactly the kind of invariants a `tests/test_arch_*.py` fence would pin if this repo had one. It does not. Recommending the repo adopt such a harness is **out of scope** for this admission (a governance Ripple decision); the CI fences above are the realistic enforcement surface for v1 and are named so no fence obligation is silently dropped.
```

### fitness-fences-master.md

```markdown
# Fitness fences — Master Implementation Plan (`docs/plans/master-implementation-plan.md`)

> **Architectural-fitness fence obligation.** Per root `CLAUDE.md §Architectural Fitness`, when a PR edits a load-bearing root-CLAUDE.md or subdir-CLAUDE.md directive OR adds a new auth surface / Cloud Run image / per-corpus embed pipeline / observability surface, add or update a `tests/test_arch_*.py` in the same commit. Reviewer-enforced; no pre-commit hook. Drafter emits a `fitness-fences-{prd,spec,master}.md` side-file naming every fence the diff would trigger. Reviewer verifies the side-file exists and that every triggered fence is either added/updated in the diff (Build's authority for the actual test code; Engineer flags the obligation) OR explicitly declared `no fence trigger` with rationale.

| Fence | Reason | New or Updated | Surface anchor |
|-------|--------|----------------|----------------|
| (none — `tests/test_arch_*.py`) | **No fence trigger at the master-plan layer.** The master plan is a planning document (§Domain + two §Phase rough seeds); it edits no CLAUDE.md directive, adds no auth/Cloud Run/embed/observability surface, and authors no source or tests. This repo has no `tests/` harness (per governance-trace audit, deliverable 3). Build authors any per-pillar fences when it implements Phase 1/2. | — | — |

## CI-level fences Build will trip when implementing the phases (flagged, not authored here)

These are the operative fences for the implementation work the phases admit. Build owns them; the master plan flags them so subphase/pillar planners scope the same-PR obligation:

- **Phase 1 — template smoke-render (`.github/workflows/ci.yml`)**: `plugin-lifecycle-phase-1-subphase-1` changes `/idc:init`'s write surface (the receipt). The smoke-render must stay in sync with `commands/init.md` Phase 3/4 substitutions, so it must be updated in the same PR as the receipt-writing change or CI fails. **Load-bearing for Phase 1.**
- **Phase 1 & 2 — reference-integrity lint (`scripts/lint-references.sh`)**: the new `commands/uninstall.md` (Phase 1) and `commands/upgrade.md` (Phase 2) are auto-in-scope (`agents skills commands templates`). New cross-references must resolve or carry a tracked `lint-allow` comment.
- **Phase 1 & 2 — `bash -n` over `scripts/*.sh`**: trips only if a phase adds/edits a shell script; flagged for completeness.
- **Plugin manifest validation**: unaffected unless a phase edits `.claude-plugin/plugin.json`; not expected.

**Standing recommendation (out of scope for this admission):** the safety-critical compare (`spec §3.2`) and provenance-gated destructive ops (`spec §3.3`) are the kind of invariants a `tests/test_arch_*.py` harness would pin. This repo has none. Adopting such a harness is a separate governance-pipeline decision (Ripple), not part of this codebase-pipeline admission — recorded here so the absence is explicit, not a silent gap.
```

## 8. Operator gates exercised

| Gate | Mode | Action | Operator response | ISO timestamp |
|------|------|--------|-------------------|---------------|
| Engineer Gate | engineer | drafting (PRD + spec + master chain bootstrap) | approved | 2026-06-12 (captured before interrupted draft session) |
| Engineer Gate | engineer | pre_merge (PRD + spec + master chain bootstrap) | approved | 2026-06-12T21:58:08Z |

## 9. Phase-wide planning artifacts audited

- Manifest: `docs/workflow/phase-planning/plugin-lifecycle-phase-1-planning-manifest.yaml`
- Matrix: `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml`
- Matrix siblings: `plugin-lifecycle-phase-1-dag.mmd`, `plugin-lifecycle-phase-1-parallel-safety.md`, `plugin-lifecycle-phase-1-waves.md`
- Clash evidence: `docs/workflow/pillar-conflicts/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-pillar-conflicts.md`
- Phase 1 wave order: receipt substrate pillar in `wave-1`; uninstall command pillar in `wave-2` and `blocks_on` the receipt substrate pillar.

## 10. Verification evidence at audit-write time

- `python3 /tmp/idc-plan/2026-06-12-lifecycle/validate-plan-scratch.py` → `scratch structural validation: PASS`.
- Final Phase 3 custom review: 0 Blockers · 0 Major · 0 Minor · 0 Nit.
- Final Phase 3 adversarial review: 0 Blockers · 0 Majors · 0 Minors · 0 Nits.

## 11. Cross-references

- Run ledger / loop log: `/tmp/idc-plan/2026-06-12-lifecycle/fullauto-goal-loop.md`
- Cleanup manifest: `/tmp/idc-plan/2026-06-12-lifecycle/codex-cleanup-manifest.md`
- Final handoff path: `docs/workflow/handoffs/phases/<YYYY-MM-DD-HHMM>-lifecycle-uninstall-upgrade-plan-handoff.md`
