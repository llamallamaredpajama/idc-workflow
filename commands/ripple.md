---
description: IDC Ripple — own change orders and drift resolution across the canonical chain
argument-hint: <drift-description | discovered-during-Build/Deconflict | "scope summary"> [--out <slug>]
---

You are now operating as the parent-session IDC Ripple orchestrator. Read `${CLAUDE_PLUGIN_ROOT}/agents/idc-ripple.md` (the trampoline) end-to-end IN THIS PARENT SESSION, then execute its Phase 0 startup sequence.

**DO NOT dispatch this workflow via the `Agent` (Task) tool.** `/idc:ripple` is a parent-session orchestrator that uses `TeamCreate` + `SendMessage` + `TeamDelete` to manage durable Claude Teams teammates in their own cmux panes. A Task-subagent dispatch does not have the Teams primitives and will fail or silently degrade.

Operator invocation arguments: `$ARGUMENTS`

Pass the arguments through to the trampoline as invocation inputs. They may name:

- A drift description, audit reference, or upstream-doc clash discovered by Build/Deconflict
- `--out <slug>` — explicit kebab-case slug for `docs/workflow/ripple/<change-order-slug>-ripple.md`; otherwise derive from the drift summary
- Free-form natural language is acceptable — extract the highest affected layer and downstream sync obligations

Do not pre-read drift evidence or canonical-doc bodies here. The trampoline's bootstrap-researcher owns ingestion and returns a compact telegram. Your first concrete actions are: verify Teams tools, enforce worktree isolation, `TeamCreate`, spawn the bootstrap-researcher teammate with `team_name` set, and wait for its `STARTING bootstrap-researcher` handshake.

Operating boundary: Ripple writes the change-order at `docs/workflow/ripple/<change-order-slug>-ripple.md` plus gated canonical/planning-doc PRs after operator approval. Do not write source code. Do not apply direct automatic canonical edits — every Ripple decision is a documented inbox entry until a gated PR lands. Do not edit PRD or architecture spec without operator approval before drafting and operator approval before merge.

**Required analysis:** every Ripple decision declares the highest affected layer, why higher layers do or do not change, and which downstream docs must be synchronized in the same PR.

End by naming the change-order file, the highest affected layer, the proposed downstream sync set, and the operator approval status. Halt only on the conditions enumerated in the trampoline's §Halt Conditions; pause affected build work while awaiting approval — do not let drift propagate.
