# Phase 4 — remaining work as three /fullauto-goal contracts (plain pi sessions)

The pi-team orchestration is retired for this effort. Everything left in Phase 4
(v4 deterministic-core refactor, plan §5) runs as **three sequential goals, one plain pi
session each**, at the repo root. No teams, no lead, no worktrees — the session edits and
commits directly on `te-integration/phase4-2026-07-06`. Never run two goal sessions at once.

**State when this plan was cut:** Wave 1 merged (`2ac2434` journal spine, `3355dc4`
machine-yaml + release gate); U2 is BUILT and waiting as **PR #149** (branch
`te/phase4-2026-07-06-u2-fix`); open issues #142 (U2), #145 (U5), #146 (U6). Full history:
`docs/dev/2026-07-06-phase4-wave1-handoff.md` + `~/.claude/team-execute-runs/phase4-2026-07-06/run-ledger.md`.

## One-time prep (copy-paste in any terminal, ~1 min)

```bash
# 1. retire the pi-team leftovers (safe: all work is pushed)
tmux kill-session -t pi-lead 2>/dev/null   # closes lead/dashboard/feed panes (close the cmux workspace too)
cd /Users/jeremy/dev/proj/idc-workflow
for w in .worktrees/*; do git worktree remove --force "$w" 2>/dev/null; done
git worktree prune && git branch | grep "team/" | xargs -n1 git branch -D 2>/dev/null
pkill -f "pi-minus-launcher" 2>/dev/null; true   # any stray workers

# 2. every goal session starts from here
git checkout te-integration/phase4-2026-07-06 && git pull --ff-only
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
```

A plain interactive `pi` has no launcher env-stripping and no specialist guard — the auth
mirror (`~/.pi/agent-phase4`) is NOT needed. Just launch `pi` at the repo root.

---

## GOAL 1 — land U2 (reconcile · rotation · replay), PR #149

Start `pi` at the repo root, paste:

```
/fullauto-goal
GOAL: PR #149 (branch te/phase4-2026-07-06-u2-fix, issue #142 "U2 reconcile-rotate-replay")
is reviewed, fixed to green, and squash-merged into te-integration/phase4-2026-07-06. U2 =
scripts/idc_git_janitor.py + commands/doctor.md reconcile board↔journal↔git; janitor rotates
closed-out journal segments; a replay helper rebuilds expected board end-state from
docs/workflow/transition-journal.ndjson and diffs against the actual board.

VERIFICATION SURFACE (all must pass before merge, run in a checkout of the PR branch):
  - bash scripts/lint-references.sh → exit 0
  - every test in tests/smoke/governance/*.sh passes (loop them; lib.sh is not a test)
  - the three U2 tests exist and are red-when-broken: journal-replay.sh (lifecycle ⇒ empty
    diff), journal-divergence-doctor.sh (hand-injected divergence ⇒ flagged; delete the
    reconcile branch in the janitor and watch it fail, then restore), journal-rotation.sh
    (terminal segment archived, live lines intact, single atomic rewrite)
  - codex review --base te-integration/phase4-2026-07-06 (run the codex CLI from the PR-branch
    checkout; fix every Blocker/Major finding in-session and re-run until it reports none —
    codex has found real bugs on every unit so far, do not skip)
  - after merging: bash scripts/lint-references.sh && bash tests/smoke/run-all.sh green on
    te-integration in THIS real checkout (phase8 needs bun on PATH)

CONSTRAINTS: journal stays append-only (rotation is the only rewrite, done atomically);
journal write failures stay fail-soft (loud stderr warn — plan §6; reconciliation is the
detector, do NOT make ops fail-closed on journal errors); janitor findings surface through
its existing --json report shape; doctor keeps its existing row/check idiom.

BOUNDARIES: touch scripts/idc_git_janitor.py, commands/doctor.md, scripts/idc_journal_replay.py
(or the helper the PR added), tests/smoke/governance/ (new files), tests/smoke/run-all.sh only
if new tests are not auto-discovered. Off-limits: everything else, main, live repos.

MERGE (the finish line, from the repo root on te-integration):
  git merge --squash origin/te/phase4-2026-07-06-u2-fix
  git commit -m "u2 reconcile-rotate-replay: board↔journal↔git reconciliation, janitor
  rotation, journal replay (closes #142) — gate receipts in body"
  git push origin te-integration/phase4-2026-07-06
  gh pr close 149 --comment "merged locally as <sha>; audit trail"
  gh issue close 142 --comment "merged to te-integration as <sha>"
  then delete the stray empty branch: git push origin :te/phase4-2026-07-06-u2

ITERATION POLICY: fix findings in-session and re-run the failing gate; loop to green.

BLOCKED-STOP: halt with evidence if journal replay exposes engine gaps requiring non-additive
rework of scripts/idc_transition.py (that is a Phase-2 contract question for the operator).
```

---

## GOAL 2 — U5 prose demotion (ablation-gated batches), issue #145

Fresh `pi` session at the repo root (after Goal 1 merged), paste:

```
/fullauto-goal
GOAL: sweep commands/ agents/ skills/ for imperative control-flow prose whose enforcement now
exists in code (transition legality + terminal close guards + drain fixpoint + persisted
verdicts + board coherence + journal/reconciliation — cite the enforcing gate file:line for
every deletion), deleting or demoting each to a one-line advisory pointer ("the engine/hook
enforces X; bypass is blocked"), in small logged batches, each batch proven safe by the gate.
Known target: commands/janitor.md "four dimensions" prose (deferred from Phase 0). Issue #145.

VERIFICATION SURFACE (the ablation gate, run after EVERY batch, all green or the batch is
reverted): bash scripts/lint-references.sh && bash tests/smoke/run-all.sh, plus the
tests/smoke/governance/ lane under both parsers (default python3 AND
`uv run --with pyyaml` on 2-3 representative engine tests). Batch log
docs/dev/phase4-demotion-log.md appended per batch: {batch #, files, prose removed (quoted),
enforcing gate file:line, gate result, keep/revert decision}.

CONSTRAINTS: JUDGMENT KNOWLEDGE STAYS — severity meanings, layer-impact thinking, disposition
guidance, review-rubric content; when in doubt demote (pointer) rather than delete, and say so
in the log. One theme or 2-4 files per batch; commit per batch
(refactor(u5-batch<K>): <theme>); revert = git revert of that batch commit. WORKFLOW.md
router semantics from Wave 1 stay intact.

BOUNDARIES: prose in commands/ agents/ skills/ only, plus the batch log. Off-limits: scripts/,
templates/workflow-machine.yaml semantics, tests (except none needed), main, live repos.

DONE WHEN: every shipped command/agent/skill file has been examined once (state this in the
log), all batches green-or-reverted, log complete, final full gate green, everything pushed to
te-integration/phase4-2026-07-06, and issue #145 closed with a comment linking the log.

ITERATION POLICY: record-and-vary — log {what changed, what the evidence showed, next
experiment} per batch.

BLOCKED-STOP: if the gate regresses with no safe deletion subset after 3 batch attempts, keep
the prose, close out with what passed, and report the stuck batches with evidence.
```

---

## GOAL 3 — U6 acceptance, sandbox e2e, release to main, issue #146

Fresh `pi` session at the repo root (after Goal 2), paste:

```
/fullauto-goal
GOAL: Phase 4 acceptance + release. The full verification surface below is green on
te-integration/phase4-2026-07-06; the CHANGELOG + version bump land; the branch is
squash-merged to main and pushed (merge-on-green to main is operator-authorized, 2026-07-06);
issue #146 closed; a phase-4 record written to docs/dev/. Issue #146.

VERIFICATION SURFACE (every item, receipts = exact command + observed output in the record):
  1. bash scripts/lint-references.sh → 0; PLUS red-when-broken spot check: seed
     "Stage: Wibble" into a commands/*.md, lint fails, remove it.
  2. bash tests/smoke/run-all.sh → ALL GREEN (PATH needs $HOME/.bun/bin for phase8).
  3. Governance lane under python3 AND `uv run --with pyyaml` (both-parser parity).
  4. bash scripts/run-evals.sh → clean exit (behavioral evalsets retired; clean = green).
  5. Journal replay: run a full engine lifecycle in a temp repo (create→claim→move→close via
     scripts/idc_transition.py, filesystem backend), then the replay helper ⇒ empty diff.
  6. Negative: hand-inject a journal/board divergence in that temp repo ⇒ doctor/janitor
     flags it.
  7. python3 scripts/idc_release_check.py --governance → red on a seeded failing governance
     scenario (use IDC_OVERRIDE_GOVERNANCE_LANE_DIR per release-gate-governance.sh), green
     clean; flag-less run unchanged.
  8. Sandbox e2e via CODEX (NOT nested claude — spend policy): follow CLAUDE.md §"Full
     GitHub-fidelity e2e" exactly (direct `codex exec --cd <sandbox>
     --dangerously-bypass-approvals-and-sandbox`, orchestrator prompt rules incl.
     PLUGIN_ROOT=<this checkout>, script-only board mutations, session-id exports; capture to
     /Users/jeremy/dev/sandbox/_idc-observability/):
     (a) install sandbox /Users/jeremy/dev/sandbox/ke-idc-test-repo-install — full lifecycle
     with journaling on: journal lines appear, replay empty;
     (b) update sandbox /Users/jeremy/dev/sandbox/ke-idc-test-repo-update — /idc:update
     migrates cleanly: WORKFLOW.md thin-router refresh lands, operator-owned data configs
     preserved, drift contract clean. ke-snap pre/post both. State the hook-fidelity caveat
     in the record (hooks do not fire under codex; assert via artifacts + piping synthetic
     payloads into the hook scripts).
  9. Final codex sweep: codex review --base main from this checkout (the whole phase-4 diff);
     fix Blocker/Major to green.
 10. CHANGELOG.md dated release section + version bump in .claude-plugin/plugin.json AND
     .claude-plugin/marketplace.json in lockstep (this repo releases by bump+CHANGELOG+push,
     no tags); python3 scripts/idc_release_check.py → 0 after.

RELEASE (only when 1-10 are green): from the repo root:
  git checkout main && git pull --ff-only
  git merge --squash te-integration/phase4-2026-07-06
  git commit -m "Phase 4: machine-as-data, transition journal + reconciliation, governance
  release gate, prose demotion (v4 deterministic-core §5 Phase 4) (closes #146)"
  git push origin main
  Then write docs/dev/2026-07-07-phase4-complete.md (what shipped, receipts, waivers:
  fail-soft journal per plan §6; combined u3+u4 merge) and commit+push it; close #146;
  delete the remote unit branches (git push origin :te/phase4-2026-07-06-u1 etc.).

CONSTRAINTS: live repos (knowledge-engine etc.) untouched — they pick the release up via
`claude plugin update` later; sandboxes are disposable, reset with git -C <sandbox> reset
--hard <baseline> if needed (see docs/dev/local-e2e-testing.md).

ITERATION POLICY: fix-and-rerun per failing item; the surface is done when all ten hold in
one final pass.

BLOCKED-STOP: halt with evidence if the codex-driven e2e cannot complete for environment
reasons (gh auth, sandbox drift) — name the exact blocker and what input you need.
```

---

## Notes

- Goals are strictly sequential; each starts from a clean `git status` on te-integration.
- If a pi session dies mid-goal, start a fresh one and re-paste the same contract — every
  gate is idempotent and the contract re-verifies before acting.
- The two desk waivers from Wave 1 are settled decisions, do not relitigate: fail-soft
  journal writes (plan §6, U2 reconciliation is the detector) and the combined u3+u4 merge.
