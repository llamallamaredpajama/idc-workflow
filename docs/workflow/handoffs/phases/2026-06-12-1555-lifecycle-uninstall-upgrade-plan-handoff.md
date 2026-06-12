---
role: plan
next_role: sequence
auto_advance_eligible: false
auto_advance_reason: pre-merge Engineer Gate approval is still required for PRD + spec + master chain-bootstrap admission; run Sequence only after the admission PR is approved and merged
open_questions: 1
blocking_todos: 0
pipeline: codebase
---

# Handoff — plan/lifecycle-uninstall-upgrade — 2026-06-12 15:55 local

**Run:** `/idc:plan` chain-bootstrap admission · run-id `2026-06-12-lifecycle`
**Branch/worktree:** `idc-plan/lifecycle-uninstall-upgrade` · `.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade/`
**Status:** Plan artifacts landed on the admission branch; PR open/merge is gated by pre-merge Engineer Gate approval.

## What landed in this Plan branch

- New canonical PRD: `docs/prd/prd.md`.
- New master architectural spec: `docs/specs/master-architectural-spec.md`.
- New master implementation plan: `docs/plans/master-implementation-plan.md` with `§Domain: plugin-lifecycle`, Phase 1 (install receipt + uninstall), and Phase 2 (upgrade + Updating docs) deferred to a later Plan run.
- Phase 1 subphase plans:
  - `docs/plans/subphases/plugin-lifecycle-phase-1-subphase-1-install-receipt-plan.md`
  - `docs/plans/subphases/plugin-lifecycle-phase-1-subphase-2-uninstall-command-plan.md`
- Phase 1 pillar plans:
  - `docs/plans/pillars/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plan.md`
  - `docs/plans/pillars/plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-plan.md`
- Phase-wide planning manifest: `docs/workflow/phase-planning/plugin-lifecycle-phase-1-planning-manifest.yaml` (`planning_scope: phase-wide`, both rows `status: drafted`).
- Matrix substrate + siblings:
  - `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml`
  - `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-dag.mmd`
  - `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-parallel-safety.md`
  - `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-waves.md`
- Pair-wise clash evidence: `docs/workflow/pillar-conflicts/plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer-plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command-pillar-conflicts.md`.
- Planning admission audit: `docs/workflow/audits/2026-06-12-lifecycle-uninstall-upgrade-planning-admission-audit.md`.
- Absorbed consideration archived: `docs/considerations/archived-considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md`.

## Review / fix summary

- Bundle-finisher verification patched the cross-subphase resource model: `commands/init.md` is exclusive to the receipt pillar and consumed read-only by uninstall; `CHANGELOG.md ## Unreleased` is the only true shared write surface, resolved as append-only `union` in clash evidence.
- Phase 3 custom + adversarial review found one Major: scratch-only admission context blocks remained at the top of PRD/spec/master drafts.
- Fix loop 1 stripped those context blocks before canonical landing.
- Final custom re-review: 0 Blockers · 0 Major · 0 Minor · 0 Nit.
- Final adversarial re-review: 0 Blockers · 0 Majors · 0 Minors · 0 Nits.

## Verification surface

Run from the worktree root:

1. `python3 /tmp/idc-plan/2026-06-12-lifecycle/validate-plan-scratch.py` — expected `scratch structural validation: PASS`.
2. Canonical structural validation script (recorded in the run log) — expected `canonical structural validation: PASS`.
3. `bash scripts/lint-references.sh`.
4. CI-equivalent checks from `.github/workflows/ci.yml`: manifest `jq` checks, template smoke-render, and `bash -n scripts/*.sh`.
5. `git diff --check`.

## Operator gate / open question

- **Open question (blocking merge):** pre-merge Engineer Gate approval for the chain-bootstrap PRD + spec + master admission. Pre-drafting approval was captured before this resume; pre-merge approval is still pending.
- Do **not** merge the admission PR until the operator explicitly approves the pre-merge Engineer Gate.

## Sequence pickup after merge

After the admission PR is merged:

1. Refresh main and ensure this branch's commit is reachable from `origin/main`.
2. Run `/idc:sequence` (or `codex-idc-sequence`) against `docs/workflow/phase-planning/plugin-lifecycle-phase-1-planning-manifest.yaml` and `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml`.
3. Board #4 currently has zero items. First Sequence admit must pre-seed new Wave/Phase/Domain options before setting Project fields (WORKFLOW.md §6.3 enum-extension SOP); safe now only because the board has zero items.
4. Admit the two Phase 1 pillars in wave order:
   - wave-1: `plugin-lifecycle-phase-1-subphase-1-pillar-1-receipt-format-and-init-writer`
   - wave-2: `plugin-lifecycle-phase-1-subphase-2-pillar-1-uninstall-command` (blocks on wave-1 pillar)

## Cleanup

Codex cleanup manifest: `/tmp/idc-plan/2026-06-12-lifecycle/codex-cleanup-manifest.md`. Cleanup is **not** complete until the admission PR is merged and the worktree branch is removed per `WORKFLOW.md §9.2` / `codex-idc-plan` cleanup discipline.
