---
description: IDC Build — implement the next admitted TRACKER item using its polished pillar plan
argument-hint: <pillar-plan-path | TRACKER-line-pointer | "scope summary"> [free-form notes]
---

You are now operating as the parent-session IDC Build orchestrator. Read `${CLAUDE_PLUGIN_ROOT}/agents/idc-build.md` (the trampoline) end-to-end IN THIS PARENT SESSION, then execute its Phase 0 startup sequence.

**DO NOT dispatch this workflow via the `Agent` (Task) tool.** `/idc:build` is a parent-session orchestrator that uses `TeamCreate` + `SendMessage` + `TeamDelete` to manage durable Claude Teams teammates in their own cmux panes. A Task-subagent dispatch does not have the Teams primitives and will fail or silently degrade.

Operator invocation arguments: `$ARGUMENTS`

Pass the arguments through to the trampoline as invocation inputs. They may name:

- a polished pillar-plan path (`docs/plans/pillars/<…>-plan.md`),
- a TRACKER pointer / GitHub issue / admitted unit identifier,
- or free-form natural-language notes that help the bootstrap-researcher resolve the active wave.

Do not pre-read pillar plans or the runbook here. The trampoline’s bootstrap-researcher owns tracker / plan / handoff absorption and returns a compact wave-dispatch telegram. Your first concrete actions are: verify Teams tools, enforce worktree isolation, `TeamCreate`, spawn the bootstrap-researcher teammate with `team_name` set, and wait for its `STARTING bootstrap-researcher` handshake followed by the wave verdict.

Operating boundary: Build writes source code and tests, implementation PR artifacts, `docs/workflow/operator-todos/`, closeout artifacts, and status-only TRACKER bookends. Do not edit `docs/prd/prd.md`, `docs/specs/master-architectural-spec.md`, `docs/plans/master-implementation-plan.md`, `docs/plans/subphases/`, or `docs/plans/pillars/`.

Exit gate: code review + tests + Ripple Audit. If implementation diverged from the pillar OR the pillar diverged from upstream docs, file Ripple via `/idc:ripple` and pause affected work — do not paper over the drift in source. Halt only on the conditions enumerated in the trampoline; do not stop the train on routine review-fix cycles or non-blocking findings.
