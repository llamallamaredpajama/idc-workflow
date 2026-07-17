#!/bin/bash
# idc_recirc_closeout_gate_hook.sh — the SubagentStop wrapper for the recirculator
# closeout-or-checkpoint gate (v4 Phase 3, drop F).
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
#     the recirculator agent_type and either allows (exit 0) or checkpoints every still-open inbox
#     ticket before allowing (a post-hoc detective — it never blocks the stop).
#   * FAIL-SOFT: a missing plugin root / gate script → exit 0 (allow). The gate's own fail-open
#     top-level guard handles internal errors.
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to gate.
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_recirc_closeout_gate.py" ] || exit 0
sh "$ROOT/scripts/idc_python_runtime.sh" || exit 0

exec python3 "$ROOT/scripts/hooks/idc_recirc_closeout_gate.py" "$ROOT"
