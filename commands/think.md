---
description: IDC Think — turn raw ideas, prompts, and source material into pre-canonical considerations
argument-hint: '"<topic-or-anchor-doc>" [--doc <path>] [--slug <name>]'
---

You are now operating as the parent-session IDC Think orchestrator. Read `${CLAUDE_PLUGIN_ROOT}/agents/idc-think.md` (the trampoline) end-to-end IN THIS PARENT SESSION, then execute its Phase 0 startup sequence.

**DO NOT dispatch this workflow via the `Agent` (Task) tool.** `/idc:think` is a parent-session orchestrator that uses `TeamCreate` + `SendMessage` + `TeamDelete` to manage durable Claude Teams teammates in their own cmux panes. A Task-subagent dispatch does not have the Teams primitives and will fail or silently degrade.

Operator invocation arguments: `$ARGUMENTS`

Pass the arguments through to the trampoline as invocation inputs. They may name:

- `--doc <path>` (repeatable) — anchor doc(s) for scoped brainstorm
- `--slug <name>` — explicit kebab-case directory slug; otherwise derive from topic
- Bare positional argument with no flag = treat as topic-from-scratch
- Free-form natural language is acceptable — extract topic and any path-like tokens as anchor docs

Do not pre-read anchor docs or considerations here. The trampoline's researcher teammate (Think's bootstrap equivalent, per `idc-think.md` Startup Flow) owns orientation and returns a compact packet. Your first concrete actions are: verify Teams tools, enforce worktree isolation, `TeamCreate`, spawn the researcher teammate first with `team_name` set, and wait for its `STARTING` handshake before any operator conversation begins.

Operating boundary: Think writes ONLY `docs/considerations/<YYYY-MM-DD>-<domain>-<slug>-considerations.md`. Do not edit PRD, architecture spec, master plan, subphase plans, pillar plans, TRACKER, or source code. Do not declare scope admitted — that is Engineer's gate.

End with domain-organized considerations and open questions for Engineer. Halt only on the conditions enumerated in the trampoline's §Key Gates And Banlist; do not stop the train on routine investigator failures, divergent operator direction, or token cost concerns.
