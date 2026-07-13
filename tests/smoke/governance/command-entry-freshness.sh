#!/bin/bash
# idc-assert-class: behavior
# command-entry-freshness.sh — the UserPromptExpansion admission gate (Task 2, command integrity).
# Before a governed `/idc:*` command is allowed to expand, the entry gate binds the RUNNING plugin
# runtime to the governed repo's install receipt (Task 1 freshness). A STALE runtime (older than the
# repo's receipt) is refused with an actionable reload instruction; a CURRENT runtime is admitted AND
# its command lifecycle record is opened in the ledger. This scenario drives the ACTUAL hook process
# with a real event-shaped UserPromptExpansion payload (filesystem, hermetic, no gh):
#
#   (stale)   receipt requires 4.1.0, runtime is 4.0.0 → expansion is BLOCKED, and the refusal names
#             /reload-plugins AND explains that /clear does not reload plugin commands/hooks.
#   (current) receipt requires 4.0.0, runtime is 4.0.0 → expansion is ADMITTED with additionalContext,
#             and the command is registered active in the ledger (status shows it).
#
# Red-when-broken (MANDATORY, reviewed): make the gate ignore the freshness verdict (always allow) ⇒
# (stale) FAILs; make the admit path skip command_start ⇒ (current)'s status assertion FAILs.
#
# Auto-discovered by the governance lane (phase-governance.sh); runnable standalone under python3.
#
# Usage: bash tests/smoke/governance/command-entry-freshness.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ENTRY_GATE="$GOV_PLUGIN/scripts/hooks/idc_command_entry_gate.py"
[ -f "$ENTRY_GATE" ] || gov_fail "scripts/hooks/idc_command_entry_gate.py not found (not implemented yet)"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# A governed repo (so is_governed_repo() is true → the admit path registers the command).
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

# Two synthetic plugin roots loaded via a non-cache (plugin-dir style) path, so freshness compares
# the running version against the repo's receipt only. OLD is behind the receipt (stale); CURRENT
# matches it.
OLD_PLUGIN="$WORK/plugin-old"; CURRENT_PLUGIN="$WORK/plugin-current"
mk_plugin() { mkdir -p "$1/.claude-plugin"; printf '{"name":"idc","version":"%s"}\n' "$2" > "$1/.claude-plugin/plugin.json"; }
mk_plugin "$OLD_PLUGIN" 4.0.0
mk_plugin "$CURRENT_PLUGIN" 4.0.0

# write_receipt <repo> <version> — a v2 install receipt pinning the required plugin_version.
write_receipt() {
  printf 'receipt_version: 2\nplugin_version: %s\n' "$2" > "$1/docs/workflow/install-receipt.yaml"
}

emit_expansion() {
  python3 - "$1" "$2" "$REPO" <<'PY'
import json, sys
print(json.dumps({
    "session_id": "S-entry",
    "cwd": sys.argv[3],
    "hook_event_name": "UserPromptExpansion",
    "expansion_type": "command",
    "command_name": sys.argv[1],
    "command_args": sys.argv[2],
    "command_source": "plugin",
    "prompt": "/" + sys.argv[1] + " " + sys.argv[2],
}))
PY
}

# ── (stale) receipt requires 4.1.0 but the runtime is 4.0.0 → BLOCK with a reload instruction ──────
write_receipt "$REPO" 4.1.0
OUT="$(emit_expansion idc:think 'Drive first' | python3 "$ENTRY_GATE" "$OLD_PLUGIN")"
printf '%s' "$OUT" | grep -q '"decision": "block"' \
  || gov_fail "stale command expansion was not blocked"
printf '%s' "$OUT" | grep -q '/reload-plugins' \
  || gov_fail "stale refusal did not name /reload-plugins"
printf '%s' "$OUT" | grep -q '/clear does not reload' \
  || gov_fail "stale refusal did not explain that /clear is insufficient"
echo "  ok (stale) a runtime behind the repo receipt is refused with a /reload-plugins instruction"

# ── (current) receipt requires 4.0.0, runtime is 4.0.0 → ADMIT + register the active command ───────
write_receipt "$REPO" 4.0.0
OUT="$(emit_expansion idc:think 'Drive first' | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"
printf '%s' "$OUT" | grep -q 'additionalContext' \
  || gov_fail "current command did not receive its command-contract context"
python3 "$GOV_PLUGIN/scripts/idc_command_contract.py" status --repo "$REPO" \
  --session S-entry --json | grep -q '"command": "think"' \
  || gov_fail "current expansion did not register the active command"
echo "  ok (current) a current runtime is admitted with additionalContext + registers the command"

echo "PASS: the command entry gate refuses a stale runtime with an actionable reload instruction and admits a current runtime while opening its lifecycle record"
