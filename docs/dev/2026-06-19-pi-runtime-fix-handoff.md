# Handoff — Pi-runtime alignment fix + corrected merge-gate direction — 2026-06-19

**Branch:** `main` (the open work is on `pi-guard-fix` / PR #71) · **Status:** Active — one simplification + re-validate + merge remains.

This session ran three tracks. Tracks 1 and 2a are **done and merged**. Track 2b (Pi runtime
alignment fix) is a **draft PR (#71)** that needs ONE direction correction before it can land. Read
the "Corrected direction" section first — it dissolves most of the open complexity.

---

## Pick up here (the fresh session's job)

**Track 2b only.** Everything else is shipped.

1. **Simplify PR #71 to the corrected direction (below): drop the MG-B hard merge-interlock; make Pi's
   merge-on-green BEHAVIORAL (prompt-level), mirroring the production Claude IDC; make ZERO GitHub
   changes.** Concretely, in the `pi-guard-fix` worktree (`runtime/pi/extensions/idc-role-harness.ts`):
   - REMOVE the hard verdict-interlock (the guard blocking `gh pr merge <N>` unless
     `pr-<N>.verdict.json` = PASS), the `REVIEW_VERDICT_ALLOWED` / verdict-dir write-restriction
     machinery, `readMergeVerdict`, and the MG-B-specific test cases.
   - KEEP: build-finish gets role-scoped `gh pr merge` authority (so it *can* merge); the
     merge-on-green + PASS-verdict decision lives in the **prompt** (`build-finisher.md`), exactly
     like Claude `agents/idc-finisher.md`. Behavioral, trust-the-agent — Pi matches Claude's standard.
2. **KEEP the rest of PR #71 — it's all good and validated:**
   - The 7-prompt rewrite to the current **5-field-board** contract (Status/Stage/Wave/Phase/Domain +
     blocked-by; retired claim-state/lane/track/bookend vocab; Plan idempotent + sets fields + matrix,
     Plan→Stage=Planning, Sequence→Buildable+Wave, build-impl claims-before-work, recirculator binary
     gate model). Independent review confirmed the prompts are clean.
   - The **general guard hardening** (pure defense-in-depth, keep regardless of MG-B): B-1 parent-dir
     block, **B-2 git no longer bypasses the file-write ACL**, B-5 `git -c` / unknown-git-verb
     fail-closed (closes a real arbitrary-shell evasion), gh-api-write classification, glob-`rm`
     refusal. The adversarial reviewer confirmed **zero over-blocks** on the legit lifecycle.
3. **Re-validate** the simplified PR: `bash scripts/lint-references.sh` (0) + `bash tests/smoke/run-all.sh`
   (all green) in the worktree; then the **Pi e2e harness** (see Artifacts) for the behavioral proof.
4. **Merge** PR #71 to main; clean up the `pi-guard-fix` worktree + branch.
5. **Decide #66:** the autonomy here grants per-role *authority + behavior*. Pi still lacks the
   self-driving runtime (parallel pool + headless drain loop) — that stays **#66 L1/L4**, flagged not built.

---

## Precise MG-B remove-vs-keep map (from pi-e2e-fixer — surgical simplification guide)

PR #71's latest commit is `05d87dd` (round-4, analyzer class-exhaustive). To strip the MG-B hard
interlock while keeping the validated alignment + defense-in-depth, the fixer left this exact map:

**REMOVE (the MG-B machinery — defends a guarantee Pi doesn't need):**
- `runtime/pi/extensions/idc-role-harness.ts`: the `readMergeVerdict()` function; the
  `if (role === "build-finish") { … verdict check … }` block inside `evaluateGhForRole`'s `merge`
  case (KEEP the surrounding `MERGE_ROLES` scope + `--auto`/`--admin` denials); the
  `REVIEW_VERDICT_ALLOWED` const + build-review's verdict-dir write policy (revert build-review's path
  policy to `readOnly: true`); the `docs/workflow/code-reviews/**` line added to `BUILD_BLOCKED`.
- `runtime/pi/scripts/idc-pi`: revert build-review `role_tools` to `read,bash,grep,find,ls,coms`
  (drop the added `write`).
- `build-reviewer.md`: revert `tools:` frontmatter (drop `write`); remove "sole author of the
  PR-keyed verdict" / verdict-file-writing language → read-only reviewer sending findings via coms-net.
- `build-finisher.md`: KEEP "merge ONLY on green + PASS verdict" (behavioral); drop the "pass the
  explicit `<PR-NUMBER>` for the verdict lookup" sentence (plain `gh pr merge <PR> --squash --delete-branch`).
- `tests/smoke/phase8-pi-guard-acl.ts`: remove the `[MGB]`-tagged cases + the `[MGB-symlink]` block +
  the verdict-fixture setup.

**KEEP (validated, reviewer-confirmed zero over-blocks — alignment + pure defense-in-depth):**
- All 7 prompts' 5-field-board alignment (minus the build-reviewer verdict specifics above).
- Guard hardening: B-1 subshell/brace recursion, B-2 git path-ACL (`gitTouchedPaths`), M-1 cmdsubst
  recursion, M-3 case-fold, the gh-op classifier + gh-api-write handling, M-5/M-6 glob refusal,
  **B-5 inline-`-c`/unknown-verb git safelist** (highest-value general fix — closes a `git -c
  alias='!shell'` arbitrary-shell evasion that defeats the whole guard for *all* roles incl.
  read-only), B-6 `--pathspec-from-file`, m-1 destructive-push, m-2 `--admin`, force-push/`--auto`
  blocks, `isAncestorOfBlockedSurface` (general parent-dir protection), the role-scoped merge grant.

**Net after removal:** build-finish keeps role-scoped merge authority + merges behaviorally on
green+PASS (mirroring `agents/idc-finisher.md`); build-review is read-only again; alignment + general
hardening stand. The gh-api "dangerous-write" denial harmlessly forces merges through `gh pr merge`
(keep as DiD). (Ignore `PLAN.md §10` — the architectural backstop is mooted by the corrected direction.)

---

## Corrected direction (the key insight — read this)

The operator clarified: **their production Claude IDC merges on green by trusting the agent — a
behavioral rule (the finisher's contract), NO hard lock, NO GitHub branch protection — and that is
their accepted standard.** Earlier in the session the operator picked a "hard interlock" merge gate
("MG-B"), and the lead (me) had the fixer build Pi to be *stricter than the production Claude runtime*.
That was over-engineering. It triggered a 4-round adversarial-review saga trying to make a HARD
"unreviewed code can't merge" guarantee enforceable inside the bash-command guard — which the reviewer
correctly proved **impossible** (`git -c alias.x='!shell'` runs arbitrary shell, evading any
command-analyzer). The reviewer's escalation recommendation was a GitHub-level backstop (scoped tokens
+ branch protection).

**Resolution: don't build the backstop, drop the hard interlock. Pi mirrors Claude's behavioral
gate. No GitHub changes** (the operator explicitly does not want GitHub changes that affect their
other repos, just for the experimental Pi runtime). This is Pi-runtime-only; the Claude runtime is
untouched throughout.

---

## What's done + merged this session

- **Track 1 — the 13 "leftover issues" backlog: DONE (PR #69, squashed to `4e8e5ca`).**
  Triage found **9 of 13 already-resolved/stale** (the v2 rebuild deleted the surfaces). Real work was
  only #5 (lint MIN-9 hardening + test), #6 (codex mirror prune + doctor drift + test), #66 L2 (Pi
  model-doc truth). Closed **12 issues** with evidence (#1,2,3,4,5,6,7,8,9,10,16,17); **#66 stays open**
  (L1/L3/L4 Pi maturity, needs a live multi-provider runtime — blocked-stop). `known-debts.md`
  reconciled (GUARD-RAIL preserved). lint CLEAN + smoke ALL GREEN.

- **Track 2a — first real Pi-runtime e2e: DONE (PR #70, `9d74185`).**
  First captured green real-`pi` + real-Gemini Think→Plan→Build drain on `ke-idc-test-repo-pi`
  (verify 7/7, artifact runs, per-resident trace audited, no orphans). Honest limitations documented:
  the harness bridges the git/PR steps (the Pi roles can't open PRs — by glass-wall design); fleet
  mode is interactive-only headlessly (clean blocked-stop). Doc: `docs/dev/local-e2e-testing.md`.
  Empirically confirmed the #66 L2 doc fix (launcher hardcodes models). 3 harness bugs found + fixed.

---

## Track 2b — PR #71 current state (the work to finish)

- **PR #71** (DRAFT, `[HOLD]`), branch `pi-guard-fix`, worktree `.claude/worktrees/pi-guard-fix`.
- Commits: `87e59eb` (r1 impl) → `6b9f313` (r2 guard fixes) → `ed285bf` (r3 safelist) → `05d87dd`
  (r4 exhaustive analyzer). All 4 rounds were the MG-B-hardening saga — **r2/r3/r4 are now largely
  unnecessary** once MG-B is dropped (they defended the hard interlock). The **general** hardening in
  them (B-2, B-5, glob, gh-api-write) is still worth keeping as defense-in-depth.
- Tests at `05d87dd`: `phase8-pi-guard-acl.{ts,sh}` (grew 48→95+ cases), `phase8-pi-prompt-alignment.sh`,
  both wired into `run-all.sh`; full suite was ALL GREEN at each round (the guard bypasses passed tests
  because no test exercised them — that's why the independent adversarial lens mattered).
- **e2e partial re-validation (T-pi-e2e, paused):** even pre-simplification it CONFIRMED **Plan is now
  idempotent + sets board fields natively** (the duplicate-issue + blank-field e2e mess is fixed; the
  `operator_normalize_buildable` harness bridge is retired). Sequence promotes natively. The build/merge
  half wasn't reached (paused for the direction change). A harness contamination (old plan prompt said
  "Stage=Buildable") was caught + fixed by T-pi-e2e; the de-contaminated harness is ready.

---

## Decisions locked this session (Track 2b)

1. **Tracker model:** align Pi to the **5-field board** (the github backend's real shape); do NOT
   re-add the removed claim-state/lane/track/bookend concepts. (Operator-confirmed.)
2. **Autonomy:** mirror the Claude IDC finisher + recirculator — merge-on-green, ~3-iter loop →
   recirculate, recirculator decides re-plan (autonomous) vs PRD/TRD change (gated). (Operator-confirmed.)
3. **Merge gate (CORRECTED):** ~~hard interlock (MG-B)~~ → **behavioral, mirroring Claude; no GitHub
   changes.** This supersedes the earlier "hard interlock" pick. (Operator-corrected at session end.)

---

## Verification snapshot (drift detection for resume)

- **main HEAD:** `9d74185 "docs(dev): document the Pi runtime real-LLM e2e lane (4th sandbox) (#70)"`
- **Last PRs merged:** #70 (Pi e2e doc), #69 (leftover issues backlog).
- **Open PR:** #71 (DRAFT) `pi-guard-fix` — the Track-2b work to simplify + merge.
- **Worktrees:** `main`; `.claude/worktrees/pi-guard-fix` @ `05d87dd` (clean, no uncommitted);
  `.claude/worktrees/wt-drawing` (unrelated, pre-existing).
- **Teammates:** all stood down this session (pi-e2e-fixer, guard-review, T-pi-e2e) — released, not alive.
- **Open issues:** only **#66** (Pi maturity L1–L5; this session closed L2's doc, the rest stays open).
- **Sandbox (preserve):** `~/dev/sandbox/ke-idc-test-repo-pi` (private repo + Project board #11 +
  `pi-baseline` tag), left in its green/partial state as the e2e baseline.

---

## Key files / artifacts for the fresh session

- **PR #71 / worktree `.claude/worktrees/pi-guard-fix`** — the Track-2b code. Guard:
  `runtime/pi/extensions/idc-role-harness.ts`, `guard-shell-core.ts`. Launcher: `runtime/pi/scripts/idc-pi`.
  Prompts: `runtime/pi/.pi/agents/idc/{think,plan,sequence,recirculator,build-implementer,build-reviewer,build-finisher}.md`.
  Tests: `tests/smoke/phase8-pi-guard-acl.{ts,sh}`, `phase8-pi-prompt-alignment.sh`.
- **The fixer's plan:** `~/dev/sandbox/_idc-observability/pi-guard-fix-PLAN.md` (full audit + the
  divergence list; §5.2 is the MG-A/MG-B fork — now resolved to behavioral/MG-A).
- **Adversarial attack scripts** (proof the guard holes were real): `/tmp/idc-guard-attack.ts`,
  `/tmp/idc-guard-attack2.ts`, `/tmp/idc-guard-attack3.ts`. (In `/tmp` — may not survive a reboot;
  the findings are summarized in this handoff + the PR review history.)
- **Pi e2e harness (T-pi-e2e's, reusable):** `~/dev/sandbox/_idc-observability/bin/{seed-pi-board,run-pi-e2e,verify-pi-drain}.sh`
  (run-pi-e2e supports `think|think-plan|plan|sequence|build|full|fleet`; pin `PI_IDC_HARNESS_REPO`
  at the worktree's `runtime/pi`; uses a sandbox-local `PI_CODING_AGENT_DIR` auth seed for Gemini).
  Captured runs: `~/dev/sandbox/_idc-observability/run-pi-*.txt`.

---

## Open items / notes for resume

- **The adversarial-review findings, for reference if any general hardening is kept:** B-2 (git must
  path-check its touched files — keep), B-5 (deny unknown git verbs + `git -c` fail-closed — keep, real
  arbitrary-shell evasion), glob-`rm` refusal (keep). The MG-B-forge-specific findings (B-1 symlink,
  B-3/B-6/B-7 gh-api/git verdict forge) become moot when the hard interlock is dropped.
- **#66 still open:** the autonomy grant here is authority + behavior only. The self-driving runtime
  (L1 parallel build pool, L4 headless drain loop) is multi-day runtime work, still flagged not built.
  Note the L2 doc was already fixed (PR #69).
- **Pi is experimental + not in production use** — no urgency; the simplified behavioral gate matches
  the operator's accepted Claude-runtime standard, which is the right bar.
