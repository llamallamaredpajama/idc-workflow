#!/bin/bash
# idc_interlock_gate_hook.sh — the PreToolUse wrapper for the terminal-action interlocks (v4 Phase 2).
#
# Registered by hooks/hooks.json as a PreToolUse command hook with a Bash matcher. Claude Code runs
# it with the working directory set to the session repo and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the
# markdown token is NOT a shell env var inside a hook — the plugin root must arrive as an argument,
# per CLAUDE.md).
#
# Contract (mirrors the SubagentStop verdict-gate wrapper):
#   * FAST NO-OP (exit 0) when docs/workflow/tracker-config.yaml is absent in cwd — not an
#     IDC-governed repo, so we never spawn python. (The gate ALSO repo-gates on the payload's cwd.)
#   * Otherwise exec the gate, forwarding the PreToolUse payload on stdin. The gate self-gates to the
#     Bash tool + a raw terminal/board command and decides allow (exit 0, no output) / warn-inject
#     (stderr) / deny (permissionDecision JSON).
#   * FAIL-SOFT: a missing plugin root / gate script → exit 0 (allow). The gate's own P4 fail mode
#     (idc_hook_lib.guard_pre_tool) handles internal errors (fail-open unless IDC_HOOKS_STRICT=1).
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to gate (fast path: never spawn python).
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_interlock_gate.py" ] || exit 0

exec python3 "$ROOT/scripts/hooks/idc_interlock_gate.py" "$ROOT"
