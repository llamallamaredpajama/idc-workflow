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

1. **Planning lane** — one plan-run durable worker per unplanned consideration in
   `docs/considerations/` (each runs `idc:idc-plan`, itself zero-teammate); **serialize board
   admission** through this parent so the global re-wave stays coherent. Skip if none.
2. **Heal board hygiene** in passing (the auto `--fix`; `/idc:doctor` stays read-only).
3. **Build lane** — while eligible build work exists, run `idc:idc-build` on the eligible
   waves, including waves unblocked mid-run from the operator's phone. Check the exit
   condition with:
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py" --tracker <TRACKER.md>
   ```
   (or the github-backend equivalent via `idc:idc-tracker-adapter`).
4. **Exit** when no considerations remain unplanned and the drain predicate reports
   `drain: complete` (only Done + PRD-gated Blocked + operator gate issues left). Emit the
   exit report: planned, admitted, built/merged, board state, and anything waiting on the
   operator.

A pending PRD gate is not a halt — autorun reports it and exits clean. Run
`/loop /idc:autorun` for always-on operation. Autorun owns no direct canonical or source
writes — every cognitive write happens inside the `/idc:plan` and `/idc:build` runs it
dispatches (`WORKFLOW.md §4.5`).
