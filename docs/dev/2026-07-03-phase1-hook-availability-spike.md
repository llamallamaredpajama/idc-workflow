# Phase-1 spike — hook-event availability in headless `claude -p` + subagent contexts

**Date:** 2026-07-03 · **Gate:** this is the Step-0 spike the v4 Phase-1 contract requires *before*
any dependent hook work (plan §3.2 / §6: "Hook-event availability is the load-bearing assumption").
**Result: POSITIVE across the board — the SubagentStop verdict gate is viable in `-p`. No fallback
to the §6 drain-loop-step shape is needed.**

Claude Code version under test: **2.1.199**. Method: disposable `command` hooks wired via
`--settings <file>`, each recording its stdin payload to a marker log; a headless
`claude -p --strict-mcp-config --mcp-config /tmp/empty-mcp.json --permission-mode bypassPermissions`
run that (round 1) makes a main-session Bash call **and** spawns a `general-purpose` Task subagent
that makes its own Bash call, then (round 2) blocks the subagent's stop once and observes the
continuation. Harness + raw logs: `scratchpad/spike/` (disposable).

## Round 1 — which events fire

| Event | Fired in `-p`? | Count | Notes |
|---|---|---|---|
| `SessionStart` | **yes** | 1 | |
| `PreToolUse` (matcher `*`) | **yes** | 3 | main Bash + main Task-tool call + the subagent's Bash |
| `PostToolUse` (matcher `*`) | **yes** | 3 | same three |
| `SubagentStop` | **yes** | 1 | fires when the Task subagent stops — **the load-bearing event** |
| `Stop` | **yes** | 1 | fires when the main `-p` session stops |
| `SessionEnd` | **yes** | 1 | `reason:"other"` — see caveat below |

**Caveat — SessionEnd contradicts older project memory.** Prior memory
(`idc-recirculation-intake`, `project-3.1.0-recirculation-intake`) records "SessionEnd is cancelled
in headless `-p`." On **2.1.199 it fired** (once, `reason:"other"`). Either the behavior changed
since that note or the earlier observation was version/context-specific. **Implication:** the
existing SessionEnd sweep may in fact run in `-p` on current Claude Code — but Phase 1 does **not**
newly depend on SessionEnd (its enforcement is on SubagentStop, which is proven). SessionEnd stays
as the belt-and-braces detective exactly as before; we simply no longer *assume it is dead* in `-p`.
(Do not weaken the defense-in-depth on the strength of one run.)

## SubagentStop payload shape (verbatim fields, round 1)

```
session_id, transcript_path, cwd, prompt_id, permission_mode,
agent_id            = "a2671272ff9617524"
agent_type          = "general-purpose"          <- self-gating key
effort              = {"level":"high"}
hook_event_name     = "SubagentStop"
stop_hook_active    = false                        <- Claude Code's own loop guard
agent_transcript_path = ".../subagents/agent-<agent_id>.jsonl"   <- the reviewed-PR evidence
last_assistant_message = "SUBAGENT_TOOL_OK\n\nDONE"
background_tasks, session_crons
```

The gate needs none of these to be reconstructed from archaeology: `cwd` gives the governed-repo
root (repo-gate), `agent_type` lets the hook script self-gate to the review agent(s), and
`agent_transcript_path` is the subagent's own JSONL (to resolve which PR/packet it reviewed).

## Round 2 — block + bound (the exact verdict-gate mechanic), PROVEN

A SubagentStop hook that emits `{"decision":"block","reason":"…run: echo BLOCKED_RETRY_OK"}` on its
first invocation and allows the stop thereafter (bounded by a counter file):

```
=== SubagentStop invocation n=0 stop_hook_active=False agent_type=general-purpose ===   (BLOCKED)
=== SubagentStop invocation n=1 stop_hook_active=True  agent_type=general-purpose ===   (ALLOWED)
--- subagent continued after the block: BLOCKED_RETRY_OK present in agent-<id>.jsonl ---
```

Proven facts the gate relies on:
1. **A SubagentStop hook can block** the subagent's stop by printing `{"decision":"block","reason":…}`
   to stdout (exit 0). The `reason` reaches the subagent and it **continues** (it ran the required
   command), rather than terminating with stranded prose.
2. **The block is bounded by Claude Code itself:** on the re-stop `stop_hook_active` flips to
   `True`. Combined with our own N=3 counter this gives a two-layer anti-nag stop (loud fail after
   the bound, never an infinite loop).
3. `agent_type` is present on every SubagentStop, so the hook can be registered **matcher-less**
   (fires for all subagents) and **self-gate in-script** — the robust pattern (mirrors how the
   existing `idc_recirc_sweep_hook.sh` self-gates on repo presence), and it does not depend on
   whether the SubagentStop `matcher` field filters by agent type.

## Design decisions locked by this spike

- **Transport = SubagentStop hook, registered matcher-less, self-gating in-script** on
  (repo is IDC-governed at `cwd`) ∧ (`agent_type` ∈ the review-agent set). Non-matches → instant
  `exit 0` (fast no-op on the hot path).
- **Bound = N=3** own counter **plus** `stop_hook_active` as the harness backstop; after the bound,
  loud fail (allow the stop but emit a loud warning / board annotation later phases can read),
  never an infinite block.
- **`IDC_HOOKS_OBSERVE_ONLY=1`** downgrades the block to a warning (emit the reason to stderr,
  exit 0 with no block decision) — the operator escape hatch.
- **Scope boundary honored:** Phase 1's gate enforces *the sanctioned review-agent path* (a review
  agent cannot stop without a valid verdict). It does **not** try to catch an ad-hoc
  `general-purpose` subagent doing an unsanctioned review with no verdict — that path is closed in
  **Phase 2** by the PreToolUse merge/close interlock + `idc_git_finish.py --require-routed-findings`
  (you cannot close the parent PR without a validated verdict receipt on disk). The two phases
  compose; Phase 1 alone is honest about what it covers.

## What this unblocks

Every dependent Phase-1 element may now be built on SubagentStop with confidence: the verdict gate
(task 2) and the hook-fired filer it triggers on success (task 3). Phases 2–3 (PreToolUse
merge/close interlocks; Stop-hook fixpoint gate) also rest on events proven here (PreToolUse, Stop).
