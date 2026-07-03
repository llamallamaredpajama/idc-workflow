#!/bin/bash
# idc_verdict_gate_hook.sh — the SubagentStop wrapper for the verdict gate (v4 Phase 1).
#
# Registered by hooks/hooks.json as a matcher-less SubagentStop command hook (it fires for EVERY
# subagent stop on the machine, so it self-gates fast). Claude Code runs it with the working
# directory set to the session repo and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the markdown token is
# NOT a shell env var inside a hook — the plugin root must arrive as an argument, per CLAUDE.md).
#
# Contract:
#   * FAST NO-OP (exit 0) when docs/workflow/tracker-config.yaml is absent in cwd — not an
#     IDC-governed repo, so we never spawn python. (The gate ALSO repo-gates on the payload's cwd.)
#   * Otherwise exec the gate, forwarding the SubagentStop payload on stdin. The gate self-gates to
#     review agents and decides allow (exit 0, no output) vs block ({"decision":"block",...}).
#   * FAIL-SOFT: a missing plugin root / gate script → exit 0 (allow). The gate's own P4 fail mode
#     (idc_hook_lib.guard_pre_action) handles internal errors.
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to gate.
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_verdict_gate.py" ] || exit 0

exec python3 "$ROOT/scripts/hooks/idc_verdict_gate.py" "$ROOT"
