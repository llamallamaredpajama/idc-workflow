---
description: IDC Autorun — one-shot full-pipe drainer (plan unplanned considerations, heal the board, build eligible waves)
argument-hint: '[--consideration <path>...] [free-form notes]'
---

You are running `/idc:autorun`, the one button. Operate as the Autorun orchestrator **in this
session**: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` end-to-end, then run its two-lane
drain loop.

Operator input: `$ARGUMENTS` — optional consideration paths or notes; otherwise drain the
whole repo.

Traverse the pipe top-to-bottom and exit when nothing actionable remains:

1. **Planning lane** — one plan-run durable worker per **approved**, unplanned consideration
   (each runs `idc:idc-plan`, itself zero-teammate). A consideration with an **open Think PR**
   (pending admission) is treated like an open gate — **report + skip, never plan past it**;
   **serialize board admission** through this parent so the global re-wave stays coherent. Skip if
   none.
2. **Heal board hygiene** in passing (the auto `--fix`; `/idc:doctor` stays read-only).
3. **Build lane** — while eligible build work exists, run `idc:idc-build` on the eligible
   waves, including waves unblocked mid-run from the operator's phone. Check the exit
   condition with:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md>
   ```
   (or the github-backend equivalent via `idc:idc-tracker-adapter`).
4. **Exit** when no approved considerations remain unplanned and the drain predicate reports
   `drain: complete` (only Done + requirements-gated Blocked + operator gate issues + un-admitted
   considerations left). Emit the exit report: planned, admitted, built/merged, board state, the
   **final working-tree state from a post-build `git status --porcelain`** (run it at exit, never a
   start-of-run snapshot — the build lane writes files mid-run, so a stale snapshot under-counts any
   uncommitted/untracked artifact), and anything waiting on the operator.

**Drain everything; one launch gate, never self-narrow.** `/idc:autorun` drains the **whole** repo —
every phase, every eligible wave. Before draining, size a **staffing estimate** from the
ready-frontier width (`idc_autorun_drain.py --frontier`, one **sous chef** per ready issue) summed
across the remaining waves: **~N sous chefs / ~M subagents across K usage windows**. Read
`WORKFLOW-config.yaml::autorun.staffing_gate_threshold` (default **10**): at or below it, run
**fully autonomous with no launch gate**; above it, surface **exactly one** pre-drain
`AskUserQuestion` — **"~N sous chefs / ~M subagents across K windows — go / scope down?"** (a
one-time cost confirmation) — then drain ALL phases. Autorun **never self-narrows** to a phase;
phase-scoping is the operator's explicit `/idc:build --phase N` choice. Wrap the drain in `/loop`
so each iteration re-reads the **live board** and **resumes across usage-window resets**.

A pending Think-PR gate (incl. an open Think PR pending admission) is not a halt — autorun reports
it and exits clean. Run
`/loop /idc:autorun` for always-on operation. Autorun owns no direct canonical or source
writes — every cognitive write happens inside the `/idc:plan` and `/idc:build` runs it
dispatches (`WORKFLOW.md §4.5`).
