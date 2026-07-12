# Handoff — U2 PR #149 review/fix relay complete (2026-07-07)

**Branch:** `te/phase4-2026-07-06-u2-fix` (PR #149 → `te-integration/phase4-2026-07-06`, issue #142)
**Status:** merge gate SATISFIED — codex round 10 reports **no Blocker/Major**; one P2 tracked on #150.
**Session:** the plain review/fix relay continued from `docs/dev/2026-07-06-phase4-wave1-handoff.md`
(+ addendum `ddbb715`); six codex rounds (5–10) run from the U2 worktree
(`.worktrees/team-dispatch-wave-2-20260707-020111-259a`), every finding fixed TDD (red verified
before each fix) except the final P2, which is tracked, not fixed (operator said stop looping).

## Pick up here (operator)

1. **Merge decision.** The Goal-1 contract's codex gate ("fix every Blocker/Major and re-run until
   it reports none") is met at PR head `5618bf5`. Merge per the contract's MERGE block
   (`docs/dev/2026-07-07-phase4-fullauto-plan.md` Goal 1): squash-merge into te-integration,
   close #149 + #142 with the SHAs, delete the stray `te/phase4-2026-07-06-u2` branch. The one
   open codex P2 (rotation/append race, below) is tracked on #150 — merge-now-and-track or
   fix-first is the operator's call; it is concurrency hardening, not a correctness break in the
   single-writer smoke/e2e surface.
2. **Goal 2 (U5 prose demotion)** now explicitly includes **#150**'s prose half: re-point the
   adapter skills' status-mutation recipes (`idc_tracker_fs.py claim/move/close`, raw
   `gh project item-edit`) to `idc_transition.py`. #150 carries the full door inventory.
3. **Operator design question preserved on #150** (the U2 BLOCKED-STOP clause anticipated it):
   the engine has NO op for stage transitions or non-verdict terminal closes (gate approvals,
   pointer retirement, recirc drain) — `idc_transition.py`'s terminal branch is an explicit
   "Awaiting a non-Done terminal disposition (Phase 4)" stub. Until designed + doors journaled,
   the janitor replay check stays **opt-in** (`--check-journal-divergence`; doctor Row 10 passes it).

## What landed this session (PR #149 commits `cc5537d..5618bf5`)

| Commit | Codex round | Fix |
|--------|------------|-----|
| `cc5537d` | (resume) 4→5 prep | Missing journal on a NON-EMPTY board ⇒ indeterminate/exit 2 (empty fresh board stays clean); plus the prior session's uncommitted round-1..4 fixes (replay hardening, board-util inlined, structured journal records) |
| `ca6d61a` | 5 (P1) | Finisher journals its tracker-close at the `tracker_close` choke point (both backends, close-only included); phase9 claims through the ENGINE so its COHERENT headline is red-when-broken against exactly this bug |
| `ca609d5` | 6 (3×P2) | `_apply_board` journals SAFE-FIX closes (apply-safe converges); rotation fails closed on missing journal + terminal items; derived create WATERMARK — board-only items above the earliest journaled create are flagged, legacy below stays quiet |
| `0281b65` | 7 (2×P2) | Restored the shipped `findings > indeterminate` exit precedence (the branch had inverted it); rotation fails closed (exit 2, no traceback) on valid-JSON-non-object journal lines |
| `a8080c5` | 8 (P2) | Status-only ops journal ONLY status — stamping `cur["stage"]` had laundered out-of-band Stage edits into expected state on the item's next sanctioned op |
| `5618bf5` | 9 (P1) | Journal replay OPT-IN behind `--check-journal-divergence` until #150 unifies the mutation doors (codex's own round-5 remedy); doctor Row 10 unchanged (passes the flag); phase9 headline passes the flag so end-state replay-clean is still proven e2e |

**Round 10 verdict:** no Blocker/Major; "the rest of the inspected changes and targeted smoke
tests looked coherent." One P2: `--rotate-journal`'s read→`os.replace` window can silently drop a
`journal_append` that lands mid-rotation (lock shared with `journal_append`, or re-read/merge
before replace). Tracked as a comment on #150.

## Verification (all in the U2 worktree at `5618bf5`)

- `bash scripts/lint-references.sh` → CLEAN (34 files)
- `bash tests/smoke/run-all.sh` → **ALL GREEN** (incl. phase8 Pi + phase-governance, 44 scenarios + self-check)
- `bash tests/smoke/phase-governance.sh` → ALL GREEN
- Every fix was proven RED first (the failing assert observed) before the green commit
- Codex captures: `/Users/jeremy/dev/sandbox/_idc-observability/run-u2-codex-review-round{5..10}.txt`
- NOT run this session: sandbox e2e (U6's acceptance surface), `scripts/run-evals.sh`

## New governance scenarios / cases (all red-when-broken, verified red pre-fix)

- `journal-divergence-doctor.sh`: case 8 (missing journal ⇒ indeterminate), case 9 (watermark),
  case 9b (Stage-launder guard), case 5 REWRITTEN (replay opt-in until #150 — restore the old
  default-on assert when #150 closes), case 10 (findings win over indeterminate)
- `journal-rotation.sh`: missing-journal + terminal items ⇒ exit 2; non-object line ⇒ exit 2
- `journal-apply-safe-close.sh` (NEW): apply-safe close is journaled and the re-scan converges
- `janitor-resume-recirc.sh` / `phase1-git-janitor.sh`: seed an empty journal (their subject is
  not journal coherence); `phase9-realgit-lifecycle.sh`: engine claim + journal-close receipt +
  flagged COHERENT headline

## Tracker state

- **#149** OPEN, head `5618bf5`, gate met, PR comment documents the round-9 disposition
- **#142** (U2) — closes with the merge per the Goal-1 MERGE block
- **#150** (NEW) — journal door unification + flip replay default back on; blocked-by #142,
  blocks #146; carries the rotation-race P2 as a comment
- **#145** (U5) / **#146** (U6) — unchanged; U5's sweep should absorb #150's prose half
