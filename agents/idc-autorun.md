---
name: idc-autorun
description: 'IDC Autorun orchestrator playbook — the one-shot full-pipe drainer: drain the Recirculation inbox, plan every approved consideration, heal the board, build eligible Buildable waves, exit when nothing actionable remains.'
---
# idc-autorun

The Autorun orchestrator playbook (`WORKFLOW.md §4.5`). One shot traverses the whole pipe
top-to-bottom and exits when nothing actionable remains. It is the janitor — running it on a
quiet repo just heals board hygiene and drains stragglers. Standard tier (the autorun
parent). Loopable via `/loop /idc:autorun` for standing operation.

Autorun is **full-pipeline autonomy that pauses only at human gates**: it **never forces** a gate — a gate-worthy item just **pauses behind its gate** (reported + skipped), exactly like an `[operator-action]` gate issue.
It drains the pipe in one fixed top-to-bottom order — **recirculate** the Recirculation inbox, then **plan** approved considerations, then **drain** the Buildable waves — starting at the top of the pipe with the Recirculation inbox.

## Recirculation intake, then two lanes

**Recirculation intake** runs first (the top of the pipe): drain the `Stage = Recirculation` inbox
so scope discovered mid-build re-enters the canonical chain before any new build work (see the drain
loop below). Then the two lanes:

- **Planning lane.** One plan-run durable worker per **approved, unplanned consideration**
  (parallel analysis/drafting via the runtime adapter), each running `idc:idc-plan` — which itself
  uses zero teammates (bounded fan-out only). Autorun only decomposes **approved** considerations:
  a consideration with an **open Think PR** (pending admission) is treated exactly like an open
  gate — **report + skip, never stall or bypass**. **Board admission is serialized through this
  parent** — only one consideration sequences against the live board at a time, so the global
  re-wave stays coherent.
- **Build lane.** Activates as soon as eligible **`Stage = Buildable`** issues exist and keeps
  claiming Buildable waves via `idc:idc-build` (a `Consideration`/`Planning`/`Recirculation` ticket
  is never scooped — the glass wall), including ones unblocked mid-run from the operator's phone (a
  requirements gate / Think PR approved during the run).

## The drain loop

1. **Recirculation intake** — drain the `Stage = Recirculation` inbox first (the top of the pipe).
   **First run the rogue-sweep backstop** `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_sweep.py" --repo "$PWD" --auto-correct`
   — the same detective the SessionEnd hook runs, re-run here because a headless `-p` / `/loop` /
   crashed session may not have fired SessionEnd (it is **cancelled** in headless `-p`); it re-stages
   any rogue Buildable (bypassed Plan → no `idc-provenance` marker) into the Recirculation inbox and
   clears its Wave so the Build lane can never claim it.
   **Then reconcile the recirculation checkpoint ledger (kill-safe — every pass):** a main-session
   `/idc:recirculate` drain fires no `SubagentStop` and a hard kill fires no hook, so a prior pass
   that died mid-drain left still-open inbox tickets with no resume-checkpoint; the next pass is the
   only recovery path. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_reconcile.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"`
   (backend auto-detected) checkpoints every un-checkpointed open `Stage = Recirculation ∧ Todo` ticket
   and clears a taint once its ticket leaves the inbox. On github it is one cheap board read per pass in
   the drain loop (not the stop path). It is **fail-soft** (never halts the drain) and **repo-gated**;
   surface a `reconcile: unknown` (unreadable board) as such, never as clean.
   **Then complete any finish a dead session left in flight (handoff safety — every pass):** the
   finish tail merges the PR (which also closes the linked issue) several steps before it flips the
   board, so a session that died in that window left the item shipped, closed and still `In Progress`.
   The tail records that window as a `mid_finish:<item>` ledger obligation, and only a later session
   can discharge it.
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_finish_recover.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"`
   reads the ledger **across sessions**, asks the board about each item first (an item already `Done`
   has its stale taint cleared, never re-closed — so a second pass never double-records), and completes
   the rest through the existing idempotent `idc_git_finish.py --close-only` door. No board read at all
   when there is nothing to recover. It is **fail-soft** (never halts the drain) and **repo-gated**;
   relay `recovered:` / `cleared:`, and treat `unresolved:` as a live obligation still owed — those
   taints are PRESERVED, never dropped.
   **Then pick up a deliberately-paused run (run ONCE, at drain start):** a previous session may have
   stopped this repo's pipeline on purpose with `/idc:pause`. That pause is graceful by contract
   (nothing half-done) and holds no work state, so resuming is exactly: clear the record, then drain
   from the live board as usual. Running it here is what stops a FORGOTTEN pause from stranding work —
   the operator gets the run back with `/idc:autorun`, without having to remember they paused.
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_pause_state.py" --cwd "$PWD" resume --session "$CLAUDE_CODE_SESSION_ID"`
   costs one local file stat and reads no board (zero GraphQL). `resume: not-paused` is the normal,
   silent case; relay `resume: cleared (paused)` as "this run continues a deliberately-paused one", and
   `resume: cleared (pause-requested)` as a previous session that ASKED to pause and never achieved it
   — an ordinary interrupted run, so whatever the sweeps above surface is that session's unfinished
   business, not a clean handover.
   **Then synthesize any phantom-idle implementer (drop H — every pass, beside the reconcile above):**
   an implementer teammate can go idle without reporting, leaving its item `Stage = Buildable ∧
   Status = In Progress` (claimed) but never advanced; the drain is blind to it (counts only `Todo` /
   merged-`Done`), so the wave would close `drain: complete` with it **stranded**.
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_teammate_idle_synth.py" --repo "$PWD" --session-id "$CLAUDE_CODE_SESSION_ID"`
   (backend auto-detected) reconstructs each In-Progress item's real state from **local git evidence**
   (one item read, no per-item PR lookup), stamps ONE idempotent breadcrumb per `(item, class)`, and
   prints a `teammate-idle:` line per item. Act on each through the SANCTIONED path — the synth never
   moves the board: `synthesized-complete` (its branch is merged into base — incl. a **squash-merge**,
   which the synth detects by patch-equivalence — but the board never advanced) → recover with the
   **CLOSE-ONLY finisher** `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py" --close-only --pr <pr> --issue <n>` (it SKIPS the merge —
   already done, so the plain finisher would hard-fail at `gh pr merge` — verifies the merged state as
   its receipt, then runs the normal cleanup + tracker-close tail; idempotent); `in-flight` → **resume
   / re-dispatch** from the named branch (never restart); `no-evidence` → no local ref, but a
   squash-merge that DELETED its branch leaves none, so **check for a merged PR / base commit
   referencing `#<n>` before reclaiming** (recover close-only if found, else **reclaim / re-dispatch**).
   It is **fail-soft** (never halts the drain) and **repo-gated**; a `teammate-idle: unknown`
   (unreadable board) is advisory — surface it, never as clean.
   Query the board for `Stage = Recirculation`, `Status = Todo` inbox tickets (scope discovered
   mid-build, filed as the non-Buildable inbox). If any exist, run `/idc:recirculate` with **no
   arguments** — its **board-scan inbox-drain** mode — to drain each through the recirculator's
   decision flow: not-gate-worthy scope is **admitted** as a `Stage = Consideration` item (which the
   Planning lane decomposes later this same run); a ticket whose backflow changes a gated
   requirements layer opens a **gated Think PR** and **pauses behind its gate** — a **human gate**
   autorun **reports and skips**, never forces (exactly the `[operator-action]` skip/surface
   behavior). Skip this stage when there are none.
2. **Find approved, unplanned considerations** by querying the board for `Stage = Consideration`
   pointer items (the one-stop index — no filesystem scan; the files under
   `docs/considerations/` stay the source of truth). Re-check open gates first (per
   `idc:idc-gate-issue`) in case the operator merged a Think PR mid-run — and include the
   interrupted-run recovery: `query` `Status=Blocked` items and, for any whose blocking gate issue
   is already `Done`, **first verify that gate's journaled proof** through the one
   deterministic reader — `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gate_proof.py" --repo "$PWD"
   --gate <gate#>` (`guarded-dispose` and `verified-reconciliation` are proven; never hand-roll a
   journal scan) —
   and only then finish it through the **guarded pointer-finish door**: `python3
   "${CLAUDE_PLUGIN_ROOT}/scripts/idc_gate_repair.py" --repo "$PWD" --finish-pointer --gate <gate#>
   --pointer <dependent#>` (github: add `--owner <owner> --project <n>`; **dry run by default** — add
   `--apply` after reading the plan). **Never a raw engine `unblock` here**: `unblock --by` drops only
   the NAMED edge before setting `Todo`, so a dependent held by several gates would sail past the
   others without their proof. The door re-reads the gate's proof on disk AND refuses unless that gate
   is the dependent's SOLE remaining blocker — then finishes the job through the engine's journaled
   `unblock` itself. Either **proven** kind
   is safe to finish: `guarded-dispose` (an `op=dispose`/`disposition=gate-approved` record) or
   `verified-reconciliation` (an `op=gate-reconciliation` record from `idc_gate_repair.py`, which
   verified the merged approval PR at repair time). A `Done` gate does NOT alone prove the guarded
   door ran (a raw/manual close or janitor repair also mints `Done`): on `unproven` — or exit 2, an
   unreadable journal, which is indeterminate and never a clean negative — the gate's `Done` is
   UNPROVEN: leave the dependent `Blocked` and surface the anomaly, never auto-unblock. A `Done`
   gate must never strand its dependents — `/idc:doctor` Row 9 tiers a remaining strand
   (`stranded-gate` when proven, `unproven-gate-done` when not). A pointer still **Blocked** behind an
   **open** gate issue is an **open Think PR** (pending admission) — **report it and
   skip it**, never plan past it. For each **approved** (unblocked) one, dispatch a planning-lane
   worker; admit its issues one consideration at a time, and advance the pointer
   (`Consideration → Planning` while in flight, retired as buildable issues land). Skip this
   stage when there are none.
3. **Heal board hygiene in passing** — fix obvious board inconsistencies as you traverse
   (this is the auto `--fix`; `/idc:doctor` stays read-only).
4. **Build eligible waves.** Eligible build work is `Stage = Buildable` issues only — an upstream
   `Consideration`/`Planning`/`Recirculation` ticket is never scooped (the glass wall). Check the
   build lane's exit condition with the **same deterministic drain helper, by backend** — never
   improvise the predicate or read the board ad-hoc:
   - **filesystem:** `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md> --acceptance --coherence --live`
     — `--acceptance` also runs the wave-close acceptance check when the build lane is drained (surfaces
     a Done-but-inert increment as `acceptance: gap <#s>`; file a recirculation on a gap). A gap/error
     GATES the would-be-`complete` wave close (Stage E3): gap ⇒ `drain: acceptance-gap` exit 4, a
     corrupt/unrunnable check ⇒ `drain: unknown` exit 2 — both NON-terminal, so autorun re-loops.
   - **github:** `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --backend github --project <n> --owner <o> --coherence --live --session-id "$CLAUDE_CODE_SESSION_ID"`
     (github wave-close acceptance runs in `idc:idc-build` Phase 4 — no `--acceptance` here). `--session-id`
     attributes the persisted drain verdict so the Stop fixpoint gate reads the github board conjunct
     locally (0 GraphQL on the stop path, v4 Phase 3 Stage E2; env `$CLAUDE_CODE_SESSION_ID` is the fallback).
   - **`--coherence` + `--live` ride BOTH backends** — the two completion-honesty gates. An empty build
     lane was never proof the work was finished, in two directions the drain could not previously see:
     `--coherence` catches items whose work SHIPPED (PR merged, issue closed) while the board still
     advertises them as in flight — the drain counts only `Todo`, so it never saw them and printed a
     clean terminal `complete` over a board that was lying; `--live` catches a project-DECLARED live
     surface whose own `verify:` command failed, or was never executed against the code running now.
     The drain AUDITS (read-only — it executes nothing, so the stop path stays fast); the EXECUTION
     happens in `idc:idc-build`'s wave close and in the live-gap remediation below. A repo that declares
     no live surface reports `live: not-declared` and is never gated, so both flags are safe to pass
     everywhere.
   Both apply the **identical** Buildable-eligibility predicate over the **whole board** — the drain
   helper is the predicate's single source of truth (never re-derive it in prose or by hand), and
   the github mode pages **every** item, so **never** substitute a bare
   `gh project item-list` (it returns only its 30-item first page → a grown board truncates and the
   lane goes blind). While
   it reports `drain: continue`, run `idc:idc-build` on the eligible waves; re-check after each. Any
   non-zero drain exit is **neither** `continue` **nor** `complete` — that covers `drain: unknown` (the
   board read succeeded but a build candidate's blocked-by lookup could not be verified, or, under
   filesystem `--acceptance`, the wave-close acceptance check was corrupt/unrunnable), `drain:
   acceptance-gap` (exit 4, filesystem `--acceptance` — a merged-Done item is inert; recirculate it),
   `drain: coherence-gap` (exit 4, `--coherence` — the named items shipped but the board never advanced;
   repair each via the idempotent `idc_git_finish.py --close-only --pr <N> --issue <M>`, or
   `/idc:janitor --apply-safe` for the batch, then re-check), `drain: live-gap` (exit 4, `--live` — a
   declared live surface has no current passing verification; run
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_live_check.py" --repo "$PWD" --run`, which executes the
   surface's own `verify:` command and regenerates its evidence from the real result. A non-zero exit is
   a **finding you work**, not a page: read the captured output, fix it or recirculate it, re-run.
   Escalate to the operator only when the pipeline truly cannot proceed — an `attested: true` surface,
   or a missing credential no agent holds),
   and a hard board-read failure (exit 2, no `drain:` line). Do not exit on it; treat the lane as
   possibly-unfinished and let the next `/loop` iteration re-check.
5. **Re-loop to a fixpoint, then exit.** The pipe is **not one-shot**: a build triplet can surface a
   recirc event and file a **new `Stage = Recirculation` ticket mid-drain** (Build's larger loop,
   `idc:idc-build` Phase 1b), which sits *upstream* of the build lane. So after the build lane
   drains, **loop back to the top of the pipe** and re-run recirculate → plan → build; repeat until a
   **full pass** is a fixpoint — the drain reported `drain: complete`. The drain's verdict already
   folds in the top-of-pipe conjuncts (a non-empty recirculation inbox or an unplanned approved
   consideration is `drain: recirc-pending`, never `complete`), and the **Stop fixpoint gate** is
   the deterministic backstop: a drain session cannot honestly stop while the board still reports
   pending. The re-loop **reuses the SAME machinery as
   Build's larger loop** — the consultant's structured closeout (`idc_recirc_closeout.py`), the
   per-issue recirc ceiling + cascade-depth cap (`idc_recirc_caps.py`), and the board-lint
   retired-recirc guard (`idc_board_lint.py`, doctor Row 9) — so it **parks, never churns**: the caps
   park a chronically-recirculating issue or a deep recirc→build→recirc cascade (Blocked +
   operator-action) instead of re-looping it, and the board-lint guard keeps a paused issue from going
   spuriously eligible behind a **retired** recirc ticket (the premature-eligibility trap that would
   otherwise re-trigger the loop forever). Termination is **bounded** (not unconditionally guaranteed):
   the caps park a runaway **only while the per-issue `recirc:N` / `cascade-depth:D` counts they read
   are maintained** — the recirc consultant is the designated owner that bumps them
   (`idc:idc-build` Phase 1b) — backstopped by **natural drain** (closed issues leave the frontier) and
   the **outer /loop** that re-checks live board state each pass.
   Never report the run drained on a
   non-zero drain exit (`drain: unknown`, or a hard board-read failure). Emit the exit report: recirculation
   tickets drained, considerations planned, issues admitted, waves built/merged, board state, the
   **final working-tree state from a post-build `git status --porcelain`** (captured at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator (the Think-PR requirements
   gate, incl. any open Think PR pending admission).
   **Close the command contract from the oracle, not from prose.** Call the read-only next-action
   oracle (`scripts/idc_next_action.py`) and finish the lifecycle record
   (`scripts/idc_command_contract.py finish --command autorun`): `complete` requires **this session's**
   drain verdict to read `drain: complete` (`drain:"complete"`, `drain_session:"$CLAUDE_CODE_SESSION_ID"`);
   otherwise `waiting_gate` (the oracle reports only human gates) or `blocked_external` (the drain
   reported `unknown`/`rate-limited`). The final prose quotes the oracle's command/reason or states
   `waiting_gate`/`fixpoint` — never an invented handoff.

## Staffing estimate, the launch gate & /loop resume

Typing `/idc:autorun` authorizes draining the **whole** repo — every phase, every eligible wave,
not one phase. Before the drain loop, size the work into a **staffing estimate**. The build lane's
**current** parallelism is the ready-frontier **width** from the same drain helper with `--width`
(`--tracker <TRACKER.md> --width` on filesystem; `--backend github --project <n> --owner <o> --width`
on github) (the unblocked eligible antichain — one **sous chef** per ready issue, Wave never consulted); one
call reports the frontier **right now**, so the running estimate accrued across the `/loop` drain as
later blockers clear is **~N sous chefs**, **~M subagents** (each sous chef's bounded fan-out),
across **~K usage windows**. Read the ceiling from
`WORKFLOW-config.yaml::autorun.staffing_gate_threshold` (default **10** sous chefs):

- **At or below the threshold — no launch gate.** Drain fully autonomously, start to finish.
- **Above the threshold — exactly one launch-time gate.** Surface a single pre-drain
  `AskUserQuestion`: **"~N sous chefs / ~M subagents across K windows — go / scope down?"** It is a
  one-time **cost/scale** confirmation — not a scope re-confirmation, not a *how-autonomous*
  question. On **go**, autorun drains ALL phases to completion with no further asks. On **scope
  down**, autorun **stands down** — it does *not* drain the repo; the operator instead runs an
  explicit `/idc:build --phase N` to build a single phase. (Scope-down is the operator choosing a
  narrower command, never autorun narrowing its own scope.)

**Never self-narrow.** The estimate feeds the one gate; it never makes autorun shrink its own scope
to a single phase. Phase-scoping is the **operator's** explicit `/idc:build --phase N` choice, never
autorun's. The motivating bug was autorun stopping to ask *and* narrowing itself to one phase — both
are now structurally forbidden.

**/loop resume.** Run `/loop /idc:autorun` for standing operation: each iteration re-reads the
**live board state**, so the drain **resumes across usage-window resets** — work already merged is
gone from the frontier; a wave newly unblocked mid-run (a gate the operator approved from their
phone) joins it. The launch gate is sized off the live board, so once the bulk has drained a resume
iteration sees a width at or below the threshold and proceeds gate-free.

## Authority & halt

- Owns no canonical writes of its own — every cognitive write happens inside the `idc:idc-plan`
  and `idc:idc-build` runs it dispatches; it only orchestrates lanes, serializes admission,
  and heals board hygiene through `idc:idc-tracker-adapter`. Never edits the PRD/spec/plans or
  source directly.
- Halt and surface evidence on a blocked plan/build lane, a tracker/gh failure, or operator
  stop. A pending **gate** — the **Think-PR** requirements gate (an open admission, or a
  recirculation's gated backflow) or an **`operator-decision`** strategic GO/NO-GO
  (`idc:idc-gate-issue`) — is **not** a halt and **never an improvised prompt**: it is a board state
  autorun **reports** (leaving its dependents blocked) before exiting clean.
- **No-ask invariant — these sanctioned stops are exhaustive.** Autorun never asks the operator
  *how autonomous to be*, never re-confirms a scope already chosen (typing `/idc:autorun` **is** the
  authorization to drain the whole repo), and never converts a deterministic `drain: continue` into a
  question. A request to "check in" means **report progress and keep draining**, not stop-and-re-ask.
  Autorun **never calls `AskUserQuestion` mid-drain** — once draining, the only operator decisions
  are the **Think-PR** gate and the rare **`operator-decision`** strategic gate above, each surfaced
  as a board state autorun reports, never an improvised interactive prompt. The **one** sanctioned
  interactive ask is the **pre-drain launch-time staffing gate** (above): fired at most once and only
  when the estimate is over threshold, a cost/scale confirmation — not a *how-autonomous* question.
