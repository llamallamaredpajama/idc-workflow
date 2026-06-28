---
description: IDC Autorun — one-shot full-pipe drainer (drain the Recirculation inbox, plan unplanned considerations, heal the board, build eligible Buildable waves)
argument-hint: '[--consideration <path>...] [free-form notes]'
---

You are running `/idc:autorun`, the one button. Operate as the Autorun orchestrator **in this
session**: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` end-to-end, then run its
full-pipe drain loop.

Operator input: `$ARGUMENTS` — optional consideration paths or notes; otherwise drain the
whole repo.

Autorun is **full-pipeline autonomy that pauses only at human gates**: it **never forces** a gate — a gate-worthy item just **pauses behind its gate** (reported + skipped), exactly like an `[operator-action]` gate issue.
It drains the pipe in one fixed top-to-bottom order — **recirculate** the Recirculation inbox, then **plan** approved considerations, then **drain** the Buildable waves — and exits when nothing actionable remains.

Traverse the pipe top-to-bottom and exit when nothing actionable remains:

1. **Recirculation intake** — the top of the pipe. **First run the rogue-sweep backstop:**
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_sweep.py" --repo "$PWD" --auto-correct` — the
   same detective the SessionEnd hook runs, re-run here because a headless `-p` / `/loop` / crashed
   session may not have fired SessionEnd (it is **cancelled** in headless `-p`); it re-stages any
   rogue Buildable (bypassed Plan → no `idc-provenance` marker) into the Recirculation inbox and
   clears its Wave, so the Build drain below can never claim it. Then, if any `Stage = Recirculation`
   inbox tickets exist (scope discovered mid-build, filed back into the non-Buildable inbox), run
   `/idc:recirculate` with **no arguments** (its **board-scan inbox-drain** mode) to absorb each back
   into the canonical chain *before* any new build work. Not-gate-worthy scope is admitted as a
   `Stage = Consideration` item (which the Planning lane then decomposes this same run); a ticket
   whose backflow changes a gated requirements layer opens a **gated Think PR** — a **human gate**:
   autorun leaves that ticket **paused behind its gate** (reported + skipped), exactly the
   `[operator-action]` skip/surface behavior, and **never forces** it. Skip if no
   `Stage = Recirculation` tickets exist.
2. **Planning lane** — one plan-run durable worker per **approved**, unplanned
   (admitted-but-undecomposed) consideration (each runs `idc:idc-plan`, itself zero-teammate). A
   consideration with an **open Think PR** (pending admission) is treated like an open gate —
   **report + skip, never plan past it**; **serialize board admission** through this parent so the
   global re-wave stays coherent. Skip if none.
3. **Heal board hygiene** in passing (the auto `--fix`; `/idc:doctor` stays read-only).
4. **Build lane** — while eligible build work exists, run `idc:idc-build` on the eligible waves,
   claiming **only `Stage = Buildable`** issues (a `Consideration`/`Planning`/`Recirculation` ticket
   is never scooped — the glass wall), including waves unblocked mid-run from the operator's phone.
   Check the exit condition with:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md>
   ```
   (or the github-backend equivalent via `idc:idc-tracker-adapter`).
5. **Exit** when no `Stage = Recirculation` tickets remain, no approved considerations remain
   unplanned, and the drain predicate reports `drain: complete` (only Done + requirements-gated
   Blocked + operator gate issues + un-admitted considerations + gated recirculation backflow left).
   Emit the exit report: recirculated, planned, admitted, built/merged, board state, the
   **final working-tree state from a post-build `git status --porcelain`** (run it at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator.

**Drain everything; one launch gate, never self-narrow.** `/idc:autorun` drains the **whole** repo —
every phase, every eligible wave. Before draining, size a **staffing estimate** from the
ready-frontier width (`idc_autorun_drain.py --width`, one **sous chef** per ready issue — one call
reports the current frontier) accrued across the `/loop` drain: **~N sous chefs / ~M subagents across
K usage windows**. Read
`WORKFLOW-config.yaml::autorun.staffing_gate_threshold` (default **10**): at or below it, run
**fully autonomous with no launch gate**; above it, surface **exactly one** pre-drain
`AskUserQuestion` — **"~N sous chefs / ~M subagents across K windows — go / scope down?"** (a
one-time cost confirmation): on **go**, drain ALL phases; on **scope down**, autorun **stands down**
so the operator runs an explicit `/idc:build --phase N`. Autorun **never self-narrows** to a phase;
phase-scoping is the operator's explicit `/idc:build --phase N` choice. Wrap the drain in `/loop`
so each iteration re-reads the **live board** and **resumes across usage-window resets**.

A pending Think-PR gate (incl. an open Think PR pending admission, or a recirculation's gated
backflow) is not a halt — autorun reports it and exits clean. Run
`/loop /idc:autorun` for always-on operation. Autorun owns no direct canonical or source
writes — every cognitive write happens inside the `/idc:plan` and `/idc:build` runs it
dispatches (`WORKFLOW.md §4.5`).
