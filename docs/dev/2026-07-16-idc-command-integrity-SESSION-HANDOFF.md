# IDC Command Integrity — Session Handoff (2026-07-16, Tasks 1–5 CLOSED, Task 6 AT CAP)

**Written:** 2026-07-16, at the operator's request, to resume in a fresh session.
**Branch:** `feat/idc-command-integrity` — HEAD `c53f45b` at handoff time (this doc adds one commit).
**Worktree:** `/Users/jeremy/dev/proj/idc-workflow/.worktrees/idc-command-integrity` (git-ignored `.worktrees/`)
**Main checkout:** `/Users/jeremy/dev/proj/idc-workflow` — untouched on `main` at `dd170ff`. Do NOT edit it.
**Ledger (read FIRST on resume):** `.superpowers/sdd/progress.md` — the durable per-round record.
**NOT pushed:** the runbook's hard constraint (no merge/push/publish) stands; everything is local commits on this branch.

## Pick up here — the operator's exact resume instruction

Start the fresh session on **Fable 5 with MAX effort** (`/model` → Fable 5, max thinking). First
action, before any wave dispatch: **a full independent review of the two round-7 BLOCKS findings**
— read `.superpowers/sdd/task-6-review-r7-posture.md` (the verdict), re-run its two probes
against the production functions yourself, judge whether each is (a) real and exploitable as
claimed, (b) correctly scoped, (c) fixable as narrowly as the lead's standing recommendation says.
Then present the wave-7 go/no-go to the operator (the cap was reached; NO wave without operator
sign-off).

### The two round-7 BLOCKS (both probe-demonstrated by the round-7 reviewer)

1. **The real Claude entry hook admits a Think restart the contract refuses.**
   `scripts/idc_command_contract.py`'s `command_start` correctly raises `ObligationConflict` on a
   cross-manifest restart, but `scripts/hooks/idc_command_entry_gate.py:161` catches it, sees the
   old record, returns `_REG_OPENED`, and `_admit()` emits `additionalContext` (= allow, per
   `scripts/hooks/idc_hook_lib.py:113`). Coverage at finish then checks only the OLD manifest —
   the second manifest's units can be dropped (the incident class). Reviewer probe:
   `direct_start=REFUSED` but `entry_gate=opened`, `second_manifest_checked=False`. Regression 16e
   covers only the CLI path, not the hook path.
2. **Doctor closes on fabricated PASS rows, including a failed read reported as PASS.**
   `commands/doctor.md:448` has the agent construct its own report; `idc_command_report.py`
   validates schema not truth; closeout spot-re-runs ONLY row 5
   (`idc_command_contract.py:1628`). Reviewer probe: row-2 GitHub read failed, reported PASS,
   `doctor_closeout_ok=True`.

**Standing lead recommendation (operator has NOT yet ruled):** one final bounded wave 7 fixing
exactly these two — (1) entry gate surfaces `ObligationConflict` as a DENY with a hook-payload
regression; (2) every PASS-claiming deterministic doctor row gets the row-5 spot-re-run treatment,
a non-re-runnable row cannot claim PASS — then round 8 as the true final review. Alternatives
offered: accept-as-documented-gaps (advised against; both are incident-class), or descope doctor's
machine-verified closeout.

## State of the 8-task plan

| Task | State |
|---|---|
| 1 runtime freshness · 2 lifecycle envelope · 3 mutation interlock · 4 intake manifest | ✅ CLOSED (review-clean; see ledger) |
| 5 next-action oracle | ✅ CLOSED 2026-07-16 (round 8, no findings) |
| 6 `/idc:intake` + closeouts | ⛔ AT CAP: 6 fix waves + 7 review rounds done; rounds 6–7 ran posture-governed; round 7 returned the 2 BLOCKS above; STOPPED per cap awaiting operator |
| 7 legacy gate repair (no fake history) | ⏳ TODO (brief pre-extracted: `.superpowers/sdd/task-7-brief.md`) |
| 8 release gate → 4.1.0 | ⏳ TODO (needs operator spend OK for the hook-fidelity proof) |

Canonical plan: `docs/dev/2026-07-12-idc-command-integrity-and-external-intake-plan.md` (sole spec).
Runbook: `docs/dev/2026-07-12-idc-command-integrity-claude-execution-runbook.md` — now carries two
operator directives from 2026-07-16: **Codex reviews at `xhigh` reasoning, never `max`**, and the
**terminal posture** (below).

## Operating rules in force (operator directives, binding)

1. **Terminal posture** (`.superpowers/sdd/terminal-posture.md`, embedded in
   `build-review-prompt.sh`): only demonstrated exploitable incident-class defects WITH repro
   block; everything else → deferred list; two reviewer buckets BLOCKS/DEFERRED; **hard cap two
   posture-governed rounds per task** (Task 6 has consumed both; Tasks 7/8 get two each), then
   stop for operator sign-off.
2. **Codex reviewers at `xhigh`** reasoning (`run-review.sh` already set); reviews run DETACHED in
   their own cmux workspace, never foreground.
3. **Fix waves run as FRESH NAMED TEAMMATES** (visible panes), one writer at a time, killed after
   each wave via `bash ~/.claude/scripts/teardown-teammates.sh --name <name>`; a teammate idling
   mid-wave gets a SendMessage resume nudge first (worked for wave 6).
4. Unchanged from the runbook: no merge/push/publish; never touch issues #106/#154, KE
   PR/gate/pointer #706/#707/#708, or live knowledge-engine; every tracker write through the
   sanctioned doors; lint (`bash scripts/lint-references.sh` → CLEAN) before every commit; smoke
   green (`bash tests/smoke/run-all.sh`, python3 ≥ 3.10 on PATH — default python3 is 3.9); test
   scripts /bin/bash 3.2-compatible; regexes portable to /usr/bin/grep (PATH grep is ugrep).

## The loop mechanics (all helpers staged in `.superpowers/sdd/`)

Per wave: write `task-6-fix-guidance-rN.md` (adjudicated findings) → spawn fresh named teammate
(opus) pointed at guidance + verdict + brief → verify its commit range + rerun lint/smoke yourself
→ `review-package <base> <head>` (sdd skill script; base is ALWAYS `d254a75` for Task 6) → write
`task-6-review-rN-note.md` (frozen identifiers, disclosures) → `build-review-prompt.sh 6 <pkg>
<note>` → launch `cmux workspace create --name idc-review-task-6-rN --cwd <worktree> --command
"bash .superpowers/sdd/run-review.sh 6"` → Monitor the log for `codex exit=` → archive verdict to
`task-6-review-rN.md` → adjudicate under the posture → ledger entry. Full worked history: ledger
log + `task-6-review-r{1..7}.md` + `task-6-fix-guidance-r{1..6}.md` + `task-6-report.md` (all
writer RED/GREEN receipts, chronological).

## Verification (drift detection for resume)

- Branch HEAD at handoff: `c53f45b` (+ this docs commit on top); `git status` clean.
- Controller receipts on `c53f45b`'s predecessor chain (see ledger): full smoke `idc smoke: ALL
  GREEN` (69 PASS), `lint-references: CLEAN (36 files)`; wave-6 writer receipts in
  `task-6-report.md` (lifecycle 58 ok, /bin/bash 3.2.57 + py3.14).
- Worktrees expected: this one only (`git worktree list`). Alive teammates expected: none (all
  torn down). Unrelated parked branch `te/phase4-closeout-w3` must NOT be deleted (see memory
  index).
- Deferred-hardening list: ledger `## Deferred Minor findings` (7 items from r7 + 2 pre-existing
  env items + earlier entries) — feeds the final whole-branch review; none block.
- Live knowledge-engine board corruption (#706/#707/#708) remains UNREPAIRED by design — Task 7
  builds the tool; live repair needs separate operator authorization.

## Notes for resume

- Session memory (auto-memory dir) has been updated to this state: see
  `project-command-integrity-repair-paused.md` (now "Task 6 at cap"), plus
  `feedback-codex-review-xhigh-not-max.md` and `feedback-terminal-posture-review-loops.md`.
- The round-7 reviewer honored the two-bucket contract precisely; its DEFERRED list is
  high-quality — mine it at the final whole-branch review, not before.
- Reviewer sandbox cannot run the temp-repo suites (`mktemp` denied) — reviewer verdicts verify
  statically + via probes; the CONTROLLER re-runs lint+smoke after every wave. Keep doing both.
