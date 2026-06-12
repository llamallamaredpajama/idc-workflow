---
role: plan
next_role: plan
auto_advance_eligible: false
auto_advance_reason: mid-run operator interrupt — Plan run incomplete; pre-merge Engineer Gate not yet captured
open_questions: 1
blocking_todos: 0
pipeline: codebase
---

# Handoff — plan/lifecycle-uninstall-upgrade (MID-RUN INTERRUPT) — 2026-06-12 15:13 local

**Run:** `/idc:plan` chain-bootstrap admission · run-id `2026-06-12-lifecycle` ·
**Branch:** `idc-plan/lifecycle-uninstall-upgrade` (worktree `.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade/`, base `95d7ab4` = main) · **Status:** Interrupted by operator; resume in a NEW session (Codex via the `codex-idc-plan` adapter skill, or Claude via `/idc:plan`).

## Pick up here

1. Open the resuming session **in the worktree** `.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade/` (do NOT work on `main`). In Codex, load the `codex-idc-plan` skill; in Claude, invoke `/idc:plan` and identify as a resume of this handoff.
2. Verify scratch: primary at `/tmp/idc-plan/2026-06-12-lifecycle/` (volatile). If missing, restore from the durable snapshot `<repo>/.sandbox/idc-plan-2026-06-12-lifecycle-scratch/` (identical 25 files).
3. Execute the unfinished recovery tasks in `briefs/bundle-finisher.md` (scratch): (a) verify the 4 subphase/pillar drafts against `idc-skill-pillar-plan-shape` / `idc-skill-rough-pillars-section` / `idc-skill-pillar-resource-ownership` and patch in place; (b) cross-pillar clash analysis (shared-surface candidates: `commands/init.md`, receipt path, `docs/installing.md`, CHANGELOG) — emit clash evidence only if a true write-surface clash exists (the known `1.2 blocks_on 1.1` edge alone is dependency, not clash); (c) complete the manifest rows (→ `status: drafted`, fill `pillar_plan_paths`, constraints) + write the missing 1.2 shard; (d) synthesize `draft-matrix-plugin-lifecycle-phase-1.yaml` + 3 derived siblings (`idc-skill-pillar-matrix-synth`).
4. Phase 3 review, two lenses against the frozen draft set: custom lens = `idc-skill-plan-review`; adversarial lens = codex-native adversarial review of the drafts (in Codex, run it directly; map severities critical→Blocker, high→Major, medium→Minor, low→Nit). Blocker∪Major → `idc-skill-plan-patch-from-findings`, ≤3 loops; Minor∪Nit folded into the final patch pass.
5. Admission audit: `idc-skill-canonical-admission-audit` `mode: audit-write` → `docs/workflow/audits/2026-06-12-lifecycle-uninstall-upgrade-planning-admission-audit.md` (commit lands before the PR opens).
6. Phase 4 land on THIS branch: move drafts to canonical paths (map below); `git mv docs/considerations/2026-06-12-plugin-lifecycle-uninstall-upgrade-considerations.md docs/considerations/archived-considerations/` in the same commit; open the admission PR (body must declare: highest affected layer = PRD+spec+master chain bootstrap; downstream ripple plan; fitness obligations = "no tests/test_arch_*.py harness — operative fence is ci.yml template smoke-render"; consideration absorbed+archived; manifest path + planning_scope: phase-wide; gates exercised).
7. **PRE-MERGE ENGINEER GATE (the 1 open question): operator approval is REQUIRED before merging the admission PR** (PRD + arch-spec + master plan all new). Pre-drafting approval was captured 2026-06-12 (chain bootstrap, all three docs). Do not merge without the pre-merge approval.
8. After merge: final §A6 Plan handoff (next_role: sequence), Variant A worktree cleanup. Next chain role: `/idc:sequence` admits the polished pillars to board #4.

## What just landed (this session)

- **Nothing on `main`.** All work is scratch + this handoff commit on the run branch.
- Scratch inventory (25 files, both locations): bootstrap packet + triage (Ready) + governance audit (UNADMITTED → chain-bootstrap path, expected) + prior-art read; 9 canonical-doc artifacts (`draft-prd.md` / `draft-spec.md` / `draft-master.md` + 6 ripple-targets/fitness-fences side-files); subphase bundles `1.1` (install receipt: subphase + 1 pillar draft + shard) and `1.2` (uninstall: subphase + 1 pillar draft, shard MISSING); manifest scaffold (rows still `pending`); briefs.
- Canonical landing map: `draft-prd.md → docs/prd/prd.md` · `draft-spec.md → docs/specs/master-architectural-spec.md` · `draft-master.md → docs/plans/master-implementation-plan.md` · `draft-subphase-1-1.md → docs/plans/subphases/plugin-lifecycle-phase-1-subphase-1-install-receipt-plan.md` · `draft-subphase-1-2.md → docs/plans/subphases/plugin-lifecycle-phase-1-subphase-2-uninstall-command-plan.md` · pillars → `docs/plans/pillars/plugin-lifecycle-phase-1-subphase-<n>-pillar-1-<slug>-plan.md` · manifest → `docs/workflow/phase-planning/plugin-lifecycle-phase-1-planning-manifest.yaml` · matrix → `docs/workflow/pillar-matrices/plugin-lifecycle-phase-1-matrix.yaml` (+3 siblings).
- Spec-level resolutions already drafted (binding on downstream): receipt at `docs/workflow/install-receipt.yaml`; SHA-256 of as-written bytes; customized-file receipt rule; TRACKER.md via hardcoded list (outside receipt); 3 never-silent failure postures.

## Open questions / operator decisions pending

- Pre-merge Engineer Gate approval for the chain-bootstrap admission PR (PRD + spec + master plan). Everything else was operator-settled in the consideration (15 decisions) or resolved at spec layer.

## Verification (drift detection for resume)

- main HEAD: `95d7ab4 "think: plugin-lifecycle-uninstall-upgrade (#12)"` (origin/main == local main == worktree base)
- Last PR merged: #12 (2026-06-12T13:29Z)
- Worktrees expected: `.claude/worktrees/idc-plan-lifecycle-uninstall-upgrade` [idc-plan/lifecycle-uninstall-upgrade] — KEEP; resume works here
- Alive teammates expected: none (team `idc-plan-lifecycle-uninstall-upgrade` deleted at interrupt; a mid-run cmux Teams wipe earlier today killed 4 teammates silently — see Notes)
- Uncommitted edits: none beyond this handoff (committed on the run branch)
- Tracker board #4: zero items (Sequence has admitted nothing)
- Fitness fences: `bash scripts/lint-references.sh` last ran CLEAN this session; ci.yml green on main

## Notes for resume

- **Teams-wipe incident (lesson + candidate consideration):** ~13:53–13:59Z two planner teammates wrote their bundles, then the cmux Teams state was wiped (session restart); they died before reporting and the orchestrator waited ~3h on telegrams that could never arrive. Resume sessions should liveness-check teammates after long silences. Candidate `/idc:think` consideration: orchestrator liveness/watchdog discipline in the plugin's role playbooks.
- **Sequence pre-req (for the run AFTER this one):** board #4's `Wave`/`Phase` single-selects are seeded `Wave 0`/`Phase 0` only; first admit needs new options — safe to mutate now ONLY because the board has zero items (destructive option-replacement wipes values on existing items; see `idc-skill-github-tracker-implementation` SOP).
- Operator decisions binding on pillar content (from the archived-on-land consideration): issues are closed, never deleted; `--delete-board` requires typed confirmation; archive tarball path always announced; machine-global surfaces (Codex adapters, plugin cache) out of uninstall scope; re-runs report `skipped-absent`; receipt graduation on first upgrade; re-run-to-repair posture.
- Phase 2 (Train 2: `/idc:upgrade` + installing.md Updating section) rows exist in `draft-master.md` marked deferred-to-later-plan-run — do NOT expand them this run.
- The interrupted run's team name was `idc-plan-lifecycle-uninstall-upgrade`; scratch briefs reference it. A Codex resume has no Teams — run the bundle-finisher/review work inline or via Codex subagents per the adapter skill.
