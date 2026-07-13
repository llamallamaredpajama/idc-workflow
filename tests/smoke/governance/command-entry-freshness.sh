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

# ── the ADMISSION-CATEGORY matrix (Fix 5), directly exercised ───────────────────────────────────────
# A receipt can be UNVERIFIABLE two ways (freshness raises InvalidReceiptError): an invalid v2 receipt
# (receipt_version: 2 with no plugin_version) or an unknown legacy receipt (a receipt_version this
# reader does not understand). CURRENT_PLUGIN reads fine (4.0.0), so the receipt is the only fault.
# Categorization: the SIX workflow commands (think|intake|plan|build|recirculate|autorun) are
# fail-closed on an unverifiable receipt; the recovery/diagnostic group (doctor|update|uninstall|
# janitor) + init may expand on an unknown/invalid receipt to diagnose/migrate; EVERY command
# (recovery, janitor, init included) is blocked on a POSITIVELY stale runtime.
write_bad_v2_receipt()  { printf 'receipt_version: 2\n' > "$1/docs/workflow/install-receipt.yaml"; }
write_unknown_receipt() { printf 'receipt_version: 99\nplugin_version: 4.0.0\n' > "$1/docs/workflow/install-receipt.yaml"; }

# (a) a WORKFLOW command (plan) on an invalid receipt → BLOCKED with the repair message naming BOTH
#     /idc:doctor AND /idc:update (fail-closed — we refuse an unverifiable workflow body).
write_bad_v2_receipt "$REPO"
OUT="$(emit_expansion idc:plan 'Ship it' | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"
printf '%s' "$OUT" | grep -q '"decision": "block"' \
  || gov_fail "(a) a workflow command on an invalid receipt was not blocked"
printf '%s' "$OUT" | grep -q '/idc:doctor' \
  || gov_fail "(a) the workflow repair message did not name /idc:doctor"
printf '%s' "$OUT" | grep -q '/idc:update' \
  || gov_fail "(a) the workflow repair message did not name /idc:update"
echo "  ok (a) a workflow command on an invalid receipt is fail-closed with the /idc:doctor + /idc:update repair"

# (b) `init` on an invalid receipt → ALLOWED to expand (bootstrap), returning additionalContext.
OUT="$(emit_expansion idc:init '' | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"
printf '%s' "$OUT" | grep -q 'additionalContext' \
  || gov_fail "(b) init on an invalid receipt was not allowed to expand"
echo "  ok (b) init on an invalid receipt is allowed to expand (bootstrap)"

# (c) a RECOVERY command (doctor) AND `janitor` on an unknown legacy receipt → ALLOWED to expand AND
#     each OPENS its lifecycle record in the governed repo. The emitted additionalContext claims a
#     record was opened, so a record MUST actually exist (the Stop closeout gate + a later `finish`
#     both depend on it) — Fix 2.
#     Red-when-broken for the janitor RECLASSIFICATION: move janitor back to the fail-closed set ⇒
#     janitor is BLOCKED here instead of allowed ⇒ the additionalContext assertion FAILs.
#     Red-when-broken for Fix 2: emit additionalContext WITHOUT calling register_start ⇒ the
#     active-record assertion FAILs.
write_unknown_receipt "$REPO"
# assert_active <session> <command>: exactly one active lifecycle record for that command+session.
assert_active() {
  python3 "$GOV_PLUGIN/scripts/idc_command_contract.py" status --repo "$REPO" --session "$1" --json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); c=sys.argv[1]; sys.exit(0 if sum(1 for r in d["active"] if r.get("command")==c)==1 else 1)' "$2"
}
for CMD in idc:doctor idc:janitor; do
  bare="${CMD#idc:}"
  OUT="$(emit_expansion "$CMD" '' | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"
  printf '%s' "$OUT" | grep -q 'additionalContext' \
    || gov_fail "(c) $CMD on an unknown legacy receipt was not allowed to expand"
  assert_active S-entry "$bare" \
    || gov_fail "(c) $CMD was allowed on an invalid receipt but did NOT open its lifecycle record (Fix 2)"
done
echo "  ok (c) doctor AND janitor on an unknown legacy receipt are allowed to expand AND open their lifecycle record"

# (d) a POSITIVELY STALE runtime → BLOCKED for a recovery command, janitor, AND init alike (stale code
#     is unsafe for EVERY command). Receipt requires 4.1.0 but OLD_PLUGIN runs 4.0.0.
write_receipt "$REPO" 4.1.0
for CMD in idc:doctor idc:janitor idc:init; do
  OUT="$(emit_expansion "$CMD" '' | python3 "$ENTRY_GATE" "$OLD_PLUGIN")"
  printf '%s' "$OUT" | grep -q '"decision": "block"' \
    || gov_fail "(d) $CMD on a positively stale runtime was not blocked"
  printf '%s' "$OUT" | grep -q '/reload-plugins' \
    || gov_fail "(d) $CMD stale block did not name /reload-plugins"
done
echo "  ok (d) a positively stale runtime blocks recovery commands, janitor, and init alike"

# (e) Fix 1 — precedence: a POSITIVELY STALE cached runtime hidden behind an INVALID receipt must
#     STILL block a recovery command. The running-vs-cache staleness signal is receipt-INDEPENDENT
#     and MUST be computed BEFORE the invalid-receipt recovery-allow path — a stale runtime is the
#     more dangerous condition. Fixture: a version-keyed cache dir with 4.0.0 (running) + a newer
#     4.1.0 sibling (so freshness sees running-behind-cache without consulting the receipt), plus a
#     BAD v2 receipt that would otherwise raise into the recovery-allow branch.
#     Red-when-broken: validate the receipt before the cache-stale check (the old precedence) ⇒ the
#     invalid receipt raises first and doctor/janitor get ALLOWED here ⇒ the block assertion FAILs.
CACHE_DIR="$WORK/cache/idc"; mkdir -p "$CACHE_DIR/4.1.0"
STALE_CACHE_RUNNING="$CACHE_DIR/4.0.0"; mk_plugin "$STALE_CACHE_RUNNING" 4.0.0
write_bad_v2_receipt "$REPO"
for CMD in idc:doctor idc:janitor; do
  OUT="$(emit_expansion "$CMD" '' | python3 "$ENTRY_GATE" "$STALE_CACHE_RUNNING")"
  printf '%s' "$OUT" | grep -q '"decision": "block"' \
    || gov_fail "(e) $CMD on a stale cached runtime with an invalid receipt was not blocked (invalid receipt hid the stale runtime)"
  printf '%s' "$OUT" | grep -q '/reload-plugins' \
    || gov_fail "(e) $CMD stale+invalid block did not name /reload-plugins"
  printf '%s' "$OUT" | grep -q '/clear does not reload' \
    || gov_fail "(e) $CMD stale+invalid block did not explain that /clear is insufficient"
done
echo "  ok (e) a stale cached runtime with an invalid receipt blocks recovery commands (positive-stale beats invalid-receipt)"

echo "PASS: the command entry gate refuses a stale runtime with an actionable reload instruction, admits a current runtime while opening its lifecycle record, opens a record for a recovery command allowed on an invalid receipt, blocks a stale runtime even when the receipt is invalid (positive-stale precedence), and applies the admission-category matrix (workflow fail-closed on an invalid receipt; recovery/janitor/init may expand; all blocked when positively stale)"
