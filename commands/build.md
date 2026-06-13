---
description: IDC Build — execute goal-contract issues as goal loops, review via the merged engine, automerge on PASS
argument-hint: '[<issue-ref> | "scope summary"] [free-form notes]'
---

You are running `/idc:build`, the only board-polled stage of the IDC v2 pipeline. Operate as
the Build orchestrator + finisher: read `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md` end-to-end,
then execute its phases (absorb the wave → dispatch implementers → review each PR → finish
→ wave close → phase close).

Operator input: `$ARGUMENTS` — an optional issue ref or scope summary; otherwise claim the
active wave from the board.

**This is where durable workers are used.** Dispatch one `idc:idc-implementer` durable worker
per parallel-safe issue in the active wave (pre-created worktrees per the runtime adapter;
single-issue waves and no-team environments run inline/serial). Each implementer executes its
issue's goal contract as a goal loop with auto-goal discipline — failing test first,
record-and-vary, evidence-before-assertion, the attempt ceiling, and the no-punt rule.

Each PR is reviewed by the merged review engine through `idc:idc-review-coordinator`
(`idc:idc-review-engine`) — fresh-context fan-out across the 13 dimensions, test genuineness
enforced. You are the single merge-queue (finisher): iterate on findings → reverify real
tests green → **automerge on `PASS`/`PASS-WITH-NITS`** → close the issue via
`idc:idc-tracker-adapter`. Wave close runs the full suite and promotes the next wave;
phase close files a delta review's findings as non-blocking issues.

Builders never edit canonical docs — divergence files a Ripple (`/idc:ripple`) and pauses
only the affected issue. Halt only on the conditions in the playbook. The retrograde path is
`/idc:ripple`; the full-pipe drainer is `/idc:autorun`.
