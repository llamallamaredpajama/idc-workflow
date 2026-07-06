# Handoff — IDC v4 Phase 3 ("loop & liveness enforcement") — 2026-07-05

**Status:** ✅ **PHASE 3 COMPLETE — 2026-07-06.** All stages **A, B, C, D, E1, E2, E3 (`d6e2836`),
E4 (`8a4e312`), E5 MERGED/PASSED**; main also carries the E5-found autorun doc fix (`bcc357f`,
janitor `--report`→`--json`). Authoritative design:
[`2026-07-03-deterministic-core-refactor-plan.md`](2026-07-03-deterministic-core-refactor-plan.md)
§3.2/§3.4 + §5 Phase 3. **E5 record (top-level acceptance, all green):** run-all ALL GREEN on merged
main (real checkout); governance lane 37/37 under BOTH parsers; autorun-sandbox e2e driven by
**Codex** (`codex exec --dangerously-bypass-approvals-and-sandbox`, the Anthropic monthly spend cap
blocked every nested `claude -p` — capture `_idc-observability/run-p3e5-codex-resume.txt`): the
spend-limit death of the first wave left a GENUINE mid-drain kill (plan lane merged, item #198
stranded In-Progress with open PR #207), and the resume pass exercised the Phase-3 machinery live —
E1 `reconcile: complete`, E4 `teammate-idle: 198 in-flight branch idc/198-healthcheck ahead 1`
(breadcrumb stamped), drain looped to `drain: complete`/0 with the verdict persisted for
`session_id: p3e5-codex`; `verify-drain.sh` PASS 5/5; post-condition janitor findings (1 RISKY,
2 REPORT-ONLY) all trace to the seeded gated fixture (gate issue #201 has a blank Stage — seed
hygiene, not drain damage). **E2 MINOR-2 CLOSED live:** on the real sandbox, the Stop gate (invoked
directly with real Stop payloads — Claude hooks can't fire inside a Codex process) ALLOWED + cleared
the marker on the real persisted `complete` verdict, DEFER-allowed a no-verdict session with the
exact warn, and emitted `decision: block` on a persisted `recirc-pending`/4 — 0 GraphQL on the stop
path (gate report Δ=0). **Next phase = plan §5 Phase 4** (journal/reconciliation + prose demotion).

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

**Stage C — accepted residuals (all SAFE over-act; never lose a ticket — the board is ground truth,
re-drain idempotent; candidates for a future hardening pass, not merge-blockers).** Enumerated by the
Fable audit + a corroborating codex pass:
- A file-based closeout invoked with QUOTED/defensive shell forms (`--closeout "$tmp"`,
  `$(… --closeout x)`) isn't harvested — only the bareword `--closeout <path>` (the documented flow).
  Effect: a ticket closed out in the board-move window gets a spurious (harmless) checkpoint.
- A resumed drain that validly closes out only PART of its scope before stopping again does not clear
  the now-covered tickets' `recirc_checkpoint` taints (the clear branch is skipped while `uncovered` is
  non-empty) — stale hint taints linger (the Stop gate cross-checks the board, so they never falsely block).
- A resumed subagent stopping twice can duplicate a checkpoint comment.
- github backend remains best-effort / not hermetically tested (its hard path is Stage E).

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

---

## E3/E4 completion record — 2026-07-06

- **E3 (`d6e2836`)**: acceptance error/gap gates the wave close (`drain: unknown`/2, `drain:
  acceptance-gap`/4 on the existing exit-4). 2-lens review converged on 2 findings, both fixed +
  red-proven: the Stage-B scenario asserted the pre-E3 contract, and the filesystem Stop gate
  re-drained WITHOUT `--acceptance` (an inert board read `complete` at Stop and cleared the marker).
- **E4 (`8a4e312`)**: `scripts/idc_teammate_idle_synth.py` + `idc_git_finish.py --close-only`,
  wired at pass-top beside E1's reconcile. **8 codex review rounds + a fresh reviewer lens**, every
  guard mutation-proven; highlights: squash/rebase/cherry-pick landings need patch-equivalence (not
  ancestry); ancestry alone can't distinguish landed-vs-stale (positive evidence = the Stage-D
  `Issue: #N` trailer); close-only needs ownership + containment + LIVE-remote-tip proof before any
  deletion (data-safety); dirty uncommitted worktrees dominate complete (the impl-235 shape); the
  adapter branch shape (`worktree-build-N`) resolves before the strict leading-segment regex.
  Documented residual: staging-landed-unpromoted reads in-flight by design (`--base` overrides).
- Relay note: the Writer teammate idled without starting a round once (lead took over, then it woke
  — back off when the worktree changes under you) and later died on the spend cap after its final
  commit. codex found real findings in EVERY round for E4; rounds 7/8 were declared-final +
  data-safety-exception; the residual pass after round 8 yielded doc-fixable items only.

## RESUME 2026-07-06 (historical) — D/E1/E2 MERGED · E3 UNVERIFIED WIP · E4/E5 pending · HALTED on spend limit

**main @ `440bb6d`.** The relay ran through three more stages cleanly; the 4th was interrupted by an
account **monthly spend-limit** block (a Writer teammate died `failureReason: You've hit your monthly
spend limit`). **Raise the cap at claude.ai/settings/usage before dispatching any more teammates** —
every new teammate will fail the same way until it's raised.

### MERGED this run (all local-verified: lint 0 · run-all ALL GREEN · governance both python3 + no-pyyaml · red-when-broken)
| Stage | squash | Delivers |
|-------|--------|----------|
| **D — PostToolUse board-coherence self-repair** | `2b7d81f` | 2 fail-OPEN PostToolUse observers: `idc_post_commit_sync.py` (git-commit → linked item In-Progress or repair/inject) + `idc_post_issue_create.py` (gh-issue-create → board-add or inject); new `guard_post_observer`/`post_tool_inject` in `idc_hook_lib.py`. **2-lens caught a BLOCKER: Bash PostToolUse `tool_response` has NO `exit_code` field** (both hooks were dead-in-prod; now infer success from stdout/stderr text) + 5 more, all fixed + RWB-proven. |
| **E1 — main-session drop-F reconciliation** | `61dd645` | `scripts/idc_recirc_reconcile.py` — kill-safe closeout-or-checkpoint reconciliation run from the drain loop (top of every autorun pass + end of `/idc:recirculate`), since the main-session drain fires no SubagentStop. Transcript-less (board=ground truth), taint=idempotence latch, SAFE-bias (unreadable inbox → verdict `unknown`, never a false empty). Reuses Stage C's factored helpers (+`origin=` param on `_checkpoint_body`, +`plugin_root` on the gh helper). |
| **E2 — github persisted-verdict (0-GraphQL stop path)** | `440bb6d` | New `scripts/hooks/idc_drain_verdict.py` (atomic write, tolerant read, session-scoped `current_verdict`, 24h staleness, self-heals its gitignore). `idc_autorun_drain.py` persists `{verdict,exit,session_id,ts}` each pass; `idc_stop_fixpoint_gate.py`'s github branch (`_github_says_pending`) reads it instead of a live drain → **0 new GraphQL on the stop path**. codex found NO issues; reviewer 3 minors (all fixed/deferred). |

### E3 — UNVERIFIED WIP (do NOT trust or merge as-is)
- **Branch `p3e3-accepterr` @ `ac69bf3`** (local only, NOT pushed, NOT merged). writer-E3 hit the spend
  limit mid-build **before committing or self-verifying**; the lead committed its partial work as WIP.
- **Goal:** an acceptance error/gap at wave close must propagate a NON-terminal drain signal instead of
  being swallowed into `drain: complete`/exit 0. The bug: `idc_autorun_drain.py:382-410` runs the
  wave-close acceptance check, prints its `acceptance:` line, then emits `drain: complete`/0 regardless.
  Intended fix (per `stage-e3-brief.md`, re-derivable from the plan): in the would-be-`complete` path,
  gate on the acceptance result — **ERROR** (corrupt/exit-2/unrunnable) → `drain: unknown`/exit 2;
  **GAP** (inert Done item) → new verdict token `drain: acceptance-gap`/exit 4 (existing non-terminal
  code); **OK** → `complete` unchanged. Persist the new verdicts via `_persist_verdict` (E2). Keep the
  Phase-0 exit-code CONTRACT {0,2,3,4} and the no-`--acceptance` default output byte-identical.
- **WIP touches** (262 lines, unverified): `scripts/idc_autorun_drain.py` (+80), `commands/autorun.md`,
  `agents/idc-autorun.md`, new `tests/smoke/governance/drain-acceptance-nonterminal.sh` (179 lines).
- **To resume E3:** verify the WIP FROM SCRATCH — `bash scripts/lint-references.sh`; run the new
  scenario under python3 AND a no-pyyaml venv and **prove it red-when-broken** (revert the gate → gap/
  error print `complete` instead); `bash tests/smoke/run-all.sh` (Stage B `drain-wave-close-acceptance`
  must not regress). Then 2-lens review (codex `codex review --base main` + a fresh reviewer) → fix →
  squash-merge. If the WIP is unsound, discard the branch and rebuild from the brief.

### E4, E5 — pending (not started)
- **E4 — TeammateIdle synthesis (drop H).** `TeammateIdle` is NOT a real Claude Code hook event → build
  it as a **drain-loop-invoked deterministic check** that synthesizes an idle teammate's completion from
  worktree/branch/PR state. New `scripts/hooks/` module wired into the drain loop; governance scenario
  red-when-broken. (Plan §3.2 drop H.)
- **E5 — TOP-LEVEL ACCEPTANCE (the final gate).** Full `run-all` + governance both parsers + an
  **autorun-sandbox e2e** (Stop gate + ledger end-to-end) captured to `_idc-observability/` via a spawned
  sandbox-rooted `claude -p` (CLAUDE.md local-e2e playbook — never touch live repos). **E5 MUST assert
  the github persisted-verdict gating end-to-end** (reviewer-E2's MINOR-2: the real env→drain→gate
  `session_id` equality is only CLI-seeded in E2's unit test, never exercised live — E5 closes that).

### Relay operating notes carried this run (all confirmed)
- Merges go **direct-to-main via git squash + push** (NOT `gh pr merge`): GitHub's GraphQL PR API is
  rate-limited this account; the work is verified LOCAL (this repo's authoritative signal), and
  direct-to-main is the repo's release norm. Iteration policy authorized the per-stage squash-merge.
- **opus Writers self-committed and needed no Fable escalation** (unlike Stage-D's sonnet writer, which
  went idle uncommitted → lead took over). Use opus for the remaining hard units.
- **codex catches a real bug nearly every stage** (D: the exit_code Blocker; E1: the misleading
  checkpoint body; E2: clean) — never skip it; it's one of the two review lenses.
- Run artifacts (briefs, per-stage findings, codex outputs) live OUTSIDE the repo at
  `/Users/jeremy/dev/sandbox/_idc-observability/phase3-de-relay/` — reusable to resume.
- Verify LOCAL not CI (CI chronically red on 2 pre-existing non-hermetic phase9 tests); run-all needs
  `export PATH="$HOME/.bun/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"` (phase8 Pi/bun).
