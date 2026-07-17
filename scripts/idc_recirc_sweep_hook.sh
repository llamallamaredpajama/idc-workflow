#!/bin/bash
# idc_recirc_sweep_hook.sh — the SessionEnd wrapper for the recirculation-intake safety net.
#
# Registered by hooks/hooks.json as a SessionEnd command hook. Claude Code runs it with the working
# directory set to the session's repo, and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the markdown token is
# NOT a shell env var inside a hook, so the plugin root must arrive as an argument — see CLAUDE.md).
#
# Contract:
#   * EARLY-EXIT 0 when docs/workflow/tracker-config.yaml is absent in cwd — this is not an
#     IDC-governed repo, so the hook does nothing (it fires for every session on the machine).
#   * Otherwise run idc_recirc_sweep.py --auto-correct against the repo at cwd.
#   * FAIL-SOFT: never exit non-zero, never block session exit. Any error is swallowed (the helper
#     itself also always exits 0 in --auto-correct mode; the `|| true` is belt-and-suspenders).
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to do.
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) → fail-soft.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/idc_recirc_sweep.py" ] || exit 0
sh "$ROOT/scripts/idc_python_runtime.sh" || exit 0

python3 "$ROOT/scripts/idc_recirc_sweep.py" --repo "$PWD" --auto-correct >/dev/null 2>&1 || true

exit 0
