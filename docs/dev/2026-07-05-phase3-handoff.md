# Handoff — IDC v4 Phase 3 ("loop & liveness enforcement") — 2026-07-05

**Status:** 🟡 **IN PROGRESS** · **Branch:** `main` @ `5d6f0ee` · Stages **A, B, C MERGED**; **D, E pending.**
Driven via `/auto-goal-teams` as a **sequential relay** (one enforcement point per stage: build → 2-lens
adversarial review [codex + a teammate] → fix → merge). Authoritative design:
[`2026-07-03-deterministic-core-refactor-plan.md`](2026-07-03-deterministic-core-refactor-plan.md) §3.2/§3.4
+ §5 Phase 3. **NEXT = Stage D.**

> The run's scratch briefs (`shared-context.md`, `stage-*-brief.md`) lived in a session scratchpad and do
> **not** survive `/clear`. Everything needed to resume is below or in the plan; re-derive per-stage briefs
> from the plan + this doc.

---

## What's MERGED (drop-points closed)

| Stage | PR / squash | Delivers | Drop |
|-------|-------------|----------|------|
| **A — obligations ledger** | #138 `44a71a5` | `scripts/hooks/idc_ledger.py` — taint `set_taint`/`clear_taint`/`pending_taints(cwd, session_id=X)` for `.idc-session-state.json` at the workspace root; session-scoped, tolerant read (corrupt→empty), atomic write, **advisory file lock** (`_write_lock`) against a lost-update race, repo-gated, written **only by scripts/hooks — never the LLM**. Gitignored via `idc_init_scaffold.sh` (glob `.idc-session-state.json*`). | foundation |
| **B — Stop fixpoint gate** | #139 `bb4b80c` | `scripts/hooks/idc_stop_fixpoint_gate.py` (+`_hook.sh`), hooks.json `Stop`. **FILESYSTEM backend**: blocks an autorun/build orchestrator stop while `idc_autorun_drain.py` exits 4 (recirc-pending); N=3 `bounded_block` → loud-fail + one-time board annotation. **Crux:** block ⟺ board(drain exit 4) **AND** ledger both say work-remains → **ledger alone never blocks a clean board** (`drain: complete` wins). Self-gate = `orchestrator_drain` marker keyed to `$CLAUDE_CODE_SESSION_ID` (spike-verified == Stop payload.session_id), cleared on `drain: complete`. Drain loop invokes `idc_acceptance_check.py` at wave close (wired into `agents/idc-autorun.md`). | **E** |
| **C — recirc closeout-or-checkpoint** | #140 `5d6f0ee` | `scripts/hooks/idc_recirc_closeout_gate.py` (+`_hook.sh`), hooks.json `SubagentStop`. When a recirculator **subagent** stops without a valid `idc_recirc_closeout.py` closeout, it stamps a resume-checkpoint comment {branch, PR#, dispositions} + `recirc_checkpoint:<ticket>` taint on every still-open inbox ticket it owned. Fail-open detective. | **F** (subagent path only — see below) |

Full smoke green on each merge (lint 0 · run-all ALL GREEN · governance both `python3` and `uv run --with pyyaml`).

## PENDING

- **Stage D — PostToolUse board-coherence self-repair** (plan §3.2). Two PostToolUse hooks, **fail-OPEN
  observers** (never break the user's command): (1) `git commit` → linked board item claimed/In-Progress,
  branch↔item linkage; auto-repair or inject corrective context (claim/status drift). (2) `gh issue create`
  → if the new issue isn't board-added with Stage+Status in the same command, inject remediation or auto-add
  via the engine (drop D). hooks.json += 2× PostToolUse. Governance: commit-on-unclaimed + issue-not-added,
  red-when-broken. Watch the GraphQL cost of any per-commit board read on the github backend — prefer a cheap
  check + inject over an expensive scan.
- **Stage E — TeammateIdle synthesis (drop H) + top-level integration acceptance**, PLUS three **drain-loop /
  verdict-determinism increments deferred here** (all the same theme — make the drain's verdict fully
  deterministic + gate-enforced, honoring "no new board GraphQL on the stop path"):
  1. **Main-session drop-F** (deferred from Stage C, reviewer's Option A). The primary `/idc:recirculate`
     drain runs **in the main session** (`autorun.md:80` → `/idc:recirculate` no-args; `recirculate.md:7`
     "in this session") and the Teams-teammate consultant has its **own Stop** — neither fires Stage C's
     SubagentStop hook. Close via a deterministic closeout-or-checkpoint reconciliation invoked from the
     autorun drain loop / end of `/idc:recirculate`, reusing Stage C's `idc_recirc_closeout_gate` checkpoint
     logic; this is also the **only** path that survives a hard kill (no hook fires) via next-pass reconciliation.
  2. **github drop-E persisted-verdict** (deferred from Stage B). A live github drain on the stop path is
     ~5k GraphQL (violates the constraint), so Stage B defers github (no regression — github keeps Phase-0
     truthful-exit + prose; filesystem gained the hard gate). Fix = `idc_autorun_drain.py` persists
     `{verdict, exit, session_id}` locally; the Stop hook reads that for github = 0 new GraphQL.
  3. **acceptance-error non-terminal** (deferred from Stage B, codex). A corrupt tracker makes
     `idc_acceptance_check.py` exit 2, but the drain still prints `drain: complete`/exit 0 → corruption
     masquerades as a clean wave close. Make an acceptance error/gap propagate a non-terminal signal.
  - Then **top-level acceptance**: full run-all + governance both parsers + an **autorun-sandbox e2e**
    (Stop gate + ledger end-to-end) captured to `_idc-observability/` (see `CLAUDE.md` local-e2e playbook).
  - **Stage E is large** — split it into focused increments (TeammateIdle, main-session-drop-F,
    github-persisted-verdict, acceptance-error, acceptance-e2e), not one PR.

## Relay lessons (carry into D/E)

- **codex (`codex review --base main`) catches a real bug essentially every stage** — a fail-open, a race, a
  scope defect. Do NOT skip it; run it as one of the two review lenses. It kept finding successive edge cases
  in Stage C's scope logic (4 rounds).
- **For genuinely hard logic, escalate to a Fable 5 deep-reasoning teammate** (`Agent` with `model: fable`,
  prompt it to reason exhaustively) instead of looping codex/fixers. On Stage C, Fable live-reproduced a real
  drop-F under-checkpoint defect that survived 4 rounds and fixed the root (the narrow-vs-whole-inbox trigger)
  in one pass with a 7-mutation proof. This was the operator's call and it worked.
- **Safe-bias for a state-preserving gate: OVER-act, never UNDER-act.** Stage C's drop-F: under-checkpointing
  (missing a ticket the subagent owned) IS the state loss; over-checkpointing is a recoverable breadcrumb
  (board is ground truth, re-drain idempotent). Ambiguous/undeterminable → checkpoint the whole inbox.
- **Teammates reliably go idle mid-verification WITHOUT committing**, leaving edits uncommitted. The lead
  takes over the shared worktree: verify → **commit FIRST** → then mutation-test. `git checkout` to restore a
  mutation **wipes uncommitted work** (lost a Stage-A fix that way once) — use **cp backups**, or commit first.
- **Verify LOCAL, not CI** (CI chronically red on 2 pre-existing non-hermetic phase9 tests). Run the
  governance lane under **both** `python3` and `uv run --with pyyaml`. `export
  PATH="$HOME/.bun/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"` so run-all's phase8 Pi
  tests don't env-fail on missing `bun`. Every governance scenario must be **mutation-proven red-when-broken**.
- **hooks.json is auto-discovered → NEVER also list a hook in `plugin.json`** (3.1.1 duplicate-hooks fatal).
- **Merge cadence:** squash-merge from the **main checkout** (`gh pr merge <N> --squash --delete-branch`);
  the local-branch-delete error when a worktree holds it is expected — `git worktree remove … --force` then
  `git branch -D`.

## How to resume (fresh session)

1. Read the plan §5 Phase 3 + §3.2/§3.4, and this doc.
2. `git -C <repo> log --oneline -5` → confirm `main` @ `5d6f0ee` (A/B/C merged).
3. Author the **Stage D** brief from the plan (PostToolUse commit-sync + issue-create), pre-create a worktree
   (`git worktree add -b p3d-postsync <repo>/../idc-worktrees/p3d-postsync main`), dispatch a Writer teammate
   running `auto-goal`, then the 2-lens review → fix → merge cycle. Repeat for Stage E's increments.
4. Keep the lead context-lean: route from teammate telegrams; delegate heavy reads/mutation to teammates;
   watch for the idle-without-commit pattern and take over when it happens.
