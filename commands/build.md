---
description: IDC Build — execute goal-contract issues as goal loops, review via the merged engine, automerge on PASS
argument-hint: '[<issue-ref> | "scope summary"] [free-form notes]'
---

You are running `/idc:build`, the only board-polled stage of the IDC v2 pipeline. Operate as
the Build orchestrator driving the impl→review→finish **triplet**: read
`${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md` end-to-end, then execute its phases (absorb the
wave → dispatch triplets → review each PR → finish → wave close → phase close).

Operator input: `$ARGUMENTS` — an optional issue ref or scope summary; otherwise claim the
active wave from the board.

**This is where durable workers are used.** Dispatch one **triplet** per parallel-safe issue —
an `idc:idc-implementer` (the engine) feeding the reviewer feeding an `idc:idc-finisher`. The
adapter decides session realization: **pi** = standing residents, **Claude Teams** = teammates,
**Codex** = app-server threads; collapse to one sequential session only as a last-resort
fallback (single-issue waves, no-team environments). The implementer executes its issue's goal
contract as a `/fullauto-goal` loop with auto-goal discipline — failing test first,
record-and-vary, evidence-before-assertion, the attempt ceiling, and the no-punt rule — then
hands off to review.

Each PR is reviewed by the independent combined review agent (`idc:idc-review-engine`, run via
`idc:idc-review-coordinator`) — fresh-context fan-out across the 13 dimensions, test genuineness
enforced. The **finisher** (not the implementer)
runs its own `/fullauto-goal` loop over all findings, then `/simplify` + git finalization, and
**automerges on `PASS`/`PASS-WITH-NITS`** → closes the issue via `idc:idc-tracker-adapter`.
Merges across parallel finishers are **serialized** (matrix-disjoint surfaces + a single merge
lock/queue — no silent race). Wave close runs the full suite and promotes the next wave; phase
close files a delta review's findings as non-blocking issues.

Builders never edit canonical docs — divergence files a recirculation (`/idc:recirculate`) and pauses
only the affected issue. Halt only on the conditions in the playbook. The retrograde path is
`/idc:recirculate`; the full-pipe drainer is `/idc:autorun`.
