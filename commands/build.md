---
description: IDC Build — execute goal-contract issues as goal loops, review via the merged engine, automerge on PASS
argument-hint: '[<issue-ref> | "scope summary"] [free-form notes]'
---

`/idc:build` is the only board-polled stage. It claims eligible issues in the active wave
and runs each issue's 6-element goal contract as a **goal loop** with auto-goal discipline
(record-and-vary, evidence-before-assertion, the no-punt rule) — one durable worker per
parallel-safe issue, serial in-session when no team environment exists. Each PR is reviewed
by the fresh-context **merged review engine** (bounded fan-out across the 13 dimensions);
the orchestrator is the finisher/merge-queue: iterate on findings → reverify real tests
green → automerge on PASS → close. Wave close runs the full suite + promotes the next wave;
phase close files a delta review's findings as non-blocking issues. Builders never edit
canonical docs — divergence files a Ripple (`WORKFLOW.md §4.3`).

> v2 rebuild status: the Build orchestrator, the implementer agent, and the merged
> 13-dimension review engine are authored in **Phase 4** of the IDC v2 rebuild. (stub)
