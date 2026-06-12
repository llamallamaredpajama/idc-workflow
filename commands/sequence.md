---
description: IDC Sequence — build and maintain TRACKER ordering from polished pillar plans (status/order overlay only; no scope origination)
argument-hint: <pillar-plan-paths | "scope summary"> [--janitor]
---

You are now operating as the parent-session IDC Sequence orchestrator. Read `${CLAUDE_PLUGIN_ROOT}/agents/idc-sequence.md` (the trampoline) end-to-end IN THIS PARENT SESSION, then execute its Phase 0 startup sequence.

**DO NOT dispatch this workflow via the `Agent` (Task) tool.** `/idc:sequence` is a parent-session orchestrator that uses `TeamCreate` + `SendMessage` + `TeamDelete` to manage durable Claude Teams teammates in their own cmux panes. A Task-subagent dispatch does not have the Teams primitives and will fail or silently degrade.

Operator invocation arguments: `$ARGUMENTS`

Pass the arguments through to the trampoline as invocation inputs. They may name:

- One or more polished pillar-plan paths (`docs/plans/pillars/<…>-plan.md`) — admission set
- `--janitor` — tracker-only janitor pass (reorder, compact, clarify; no new admissions)
- Free-form natural language is acceptable — extract pillar paths and wave-grouping hints

Do not pre-read pillar plans, matrices, or TRACKER state here. The trampoline's bootstrap-researcher owns ingestion and returns a compact telegram. Your first concrete actions are: verify Teams tools, enforce worktree isolation, `TeamCreate`, spawn the bootstrap-researcher teammate with `team_name` set, and wait for its `STARTING bootstrap-researcher` handshake.

Operating boundary: Sequence writes ONLY the GitHub Project tracker ordering/status (mutated via `idc:idc-skill-tracker-adapter`; root `CLAUDE.md` Key Docs table is authoritative for the tracker surface) (and an optional wave hand-off under `docs/handoffs/waves/<YYYY-MM-DD-HHMM>-<tag>.md`). Do not edit PRD, architecture spec, master plan, subphase plans, or pillar plans. Do not originate phase, subphase, pillar, or task scope. Do not write source code or tests.

**Required trace:** every TRACKER edit must cite an existing plan-derived unit from a polished pillar plan. Missing scope routes back to Ripple (drift) or Develop (un-decomposed admitted phase), not Sequence. Implementation Wave queues are an execution-order overlay; never originate scope through them.

End by naming the TRACKER lines edited, the wave queue header (if any), and any plan-admission gaps for Develop or Ripple. Halt only on the conditions enumerated in the trampoline's §Halt Conditions.
