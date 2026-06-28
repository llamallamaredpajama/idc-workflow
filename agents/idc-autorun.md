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
   `idc:idc-gate-issue`) in case the operator merged a Think PR mid-run. A pointer still
   **Blocked** behind its gate issue is an **open Think PR** (pending admission) — **report it and
   skip it**, never plan past it. For each **approved** (unblocked) one, dispatch a planning-lane
   worker; admit its issues one consideration at a time, and advance the pointer
   (`Consideration → Planning` while in flight, retired as buildable issues land). Skip this
   stage when there are none.
3. **Heal board hygiene in passing** — fix obvious board inconsistencies as you traverse
   (this is the auto `--fix`; `/idc:doctor` stays read-only).
4. **Build eligible waves.** Eligible build work is `Stage = Buildable` issues only — an upstream
   `Consideration`/`Planning`/`Recirculation` ticket is never scooped (the glass wall). Check the
   build lane's exit condition with
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md>`
   (or the github-backend equivalent via `idc:idc-tracker-adapter`). While it reports
   `drain: continue`, run `idc:idc-build` on the eligible waves; re-check after each.
5. **Exit** when no `Stage = Recirculation` tickets remain, no approved considerations remain
   unplanned, AND the drain predicate reports `drain: complete` — i.e. only Done items,
   requirements-gated Blocked items, the operator's gate issues, un-admitted considerations (open
   Think PRs), and any gated recirculation backflow are left. Emit the exit report: recirculation
   tickets drained, considerations planned, issues admitted, waves built/merged, board state, the
   **final working-tree state from a post-build `git status --porcelain`** (captured at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator (the Think-PR requirements
   gate, incl. any open Think PR pending admission).

## Staffing estimate, the launch gate & /loop resume

Typing `/idc:autorun` authorizes draining the **whole** repo — every phase, every eligible wave,
not one phase. Before the drain loop, size the work into a **staffing estimate**. The build lane's
**current** parallelism is the ready-frontier **width** from
`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md> --width`
(the unblocked eligible antichain — one **sous chef** per ready issue, Wave never consulted); one
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
