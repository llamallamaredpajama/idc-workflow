---
description: IDC Autorun — chain a consideration through Plan and Sequence end-to-end without operator pause; emits one GitHub issue per polished pillar for Build to implement.
argument-hint: '[--considerations <path>...] [--master-section "<domain>/<phase-N>"] [--directive "<one-liner>"] [--slug <name>] [free-form notes]'
---

You are now operating as the parent-session IDC Autorun orchestrator. Read `${CLAUDE_PLUGIN_ROOT}/agents/idc-autorun.md` (the trampoline) end-to-end IN THIS PARENT SESSION, then execute its Phase 0 startup sequence.

**DO NOT dispatch this workflow via the `Agent` (Task) tool.** `/idc:autorun` is a parent-session orchestrator that uses `TeamCreate` + `SendMessage` + `TeamDelete` to manage durable Claude Teams teammates in their own cmux panes. A Task-subagent dispatch does not have the Teams primitives and will fail or silently degrade.

Operator invocation arguments: `$ARGUMENTS`

Pass the arguments through to the trampoline as invocation inputs. They may name:

- `--considerations <path>` (repeatable) — admitted considerations file(s) from a prior `/idc:think` run
- `--master-section "<domain>/<phase-N>"` — admitted master-plan section the autorun expands
- `--directive "<one-liner>"` — operator-supplied admission directive when no considerations file exists
- `--slug <name>` — explicit kebab-case slug; otherwise derive from inputs
- Free-form natural language is acceptable — extract scope summary, considerations references, master-plan §Domain/§Phase, and operator caveats

Do not pre-read considerations, plans, the master plan, or matrices here. The trampoline's bootstrap-researcher owns ingestion and returns a compact telegram. Your first concrete actions are: verify Teams tools, enforce worktree isolation, `TeamCreate`, spawn the bootstrap-researcher teammate with `team_name` set, and wait for its `STARTING bootstrap-researcher` handshake.

Operating boundary: Autorun owns the full Plan → Sequence chain end-to-end. Its only authority write is `docs/workflow/ledgers/<YYYY-MM-DD>-autorun-ledger.md` (one append, pre-composed inline). All cognitive writes go through Plan and Sequence teammates spawned via `TeamCreate` + `Agent({team_name: "<autorun-team>"})`, which in turn dispatch their own roleplayer teammates (`idc:idc-role-subphase-pillar-planner`, `idc:idc-role-fixer`, etc.). Autorun does NOT edit source code, tests, TRACKER, the CLAUDE.md tree, PRD, arch-spec, or master-plan directly — every canonical-path edit is owned by a downstream teammate brief.

**No procedural gates.** The autorun spawns Plan with `gate_mode: skip` and Sequence with `chain_from: plan` so the chain executes without operator pause. Halt only on BLOCKED telegram from Plan or Sequence, wall-time overrun (2× expected), operator stop, or orchestrator-Read-cap breach.

End by naming: the autorun-close ledger row, the Plan handoff path, the Sequence handoff path (if any), and the GitHub issue IDs admitted into the tracker. The next IDC role is `/idc:build` (one Build run per issue, or autorun-batched per operator).

Halt only on the conditions enumerated in the agent file's §Halt conditions.
