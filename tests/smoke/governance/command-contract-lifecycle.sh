#!/bin/bash
# idc-assert-class: behavior
# command-contract-lifecycle.sh — the universal IDC command lifecycle envelope (Task 2, command
# integrity). Every governed `/idc:*` command opens a lifecycle record in the session ledger at
# expansion and MUST close it with a valid terminal status; a `Stop` closeout gate refuses to let
# an agent walk away from an open command. This scenario pins the whole contract end-to-end on the
# filesystem backend (hermetic, no gh, no board):
#
#   (1) start is an idempotent upsert — two starts for the same session+command leave ONE active
#       record (never a duplicated obligation).
#   (2) the Stop closeout gate BLOCKS a session that still owns an active command with no closeout,
#       and its block names the EXACT remediation (`idc_command_contract.py ... finish`).
#   (3) an unknown / malformed terminal status CANNOT clear the obligation (the record survives).
#   (4) a schema-valid `waiting_gate` closeout ends the command honestly → Stop no longer blocks.
#   (5) a DIFFERENT session cannot finish or inherit S1's record (no cross-session escape hatch).
#
# Red-when-broken (MANDATORY, reviewed): make command_start append unconditionally (drop the upsert)
# ⇒ (1) FAILs; make the closeout gate allow when an active record exists ⇒ (2) FAILs; let finish
# accept any status ⇒ (3) FAILs; make command_finish ignore session ownership ⇒ (5) FAILs.
#
# Auto-discovered by the governance lane (phase-governance.sh); runnable standalone under python3.
#
# Usage: bash tests/smoke/governance/command-contract-lifecycle.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
CLOSEOUT_GATE="$GOV_PLUGIN/scripts/hooks/idc_command_closeout_gate.py"
[ -f "$CONTRACT" ] || gov_fail "scripts/idc_command_contract.py not found (not implemented yet)"
[ -f "$CLOSEOUT_GATE" ] || gov_fail "scripts/hooks/idc_command_closeout_gate.py not found (not implemented yet)"

# A governed throwaway workspace so is_governed_repo() is true (the ledger writes there).
WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
OUT="$WORK/out.json"
# Per-run-unique session ids (the "S1"/"S2" of the contract spec): the Stop closeout gate's anti-nag
# counter (idc_hook_lib.bounded_block) is a PERSISTENT per-user-tmp file keyed by session+command, so
# a fixed "S1" would accumulate across reruns and stop blocking after N=3 — the same hermetic-id
# pattern the sibling stop-ledger-alone-never-blocks.sh uses.
S1="s1-$$-$(basename "$WORK")"
S2="s2-$$-$(basename "$WORK")"

contract() { python3 "$CONTRACT" "$@"; }
json_count() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); print(len(data.get(sys.argv[1], [])))' "$1"
}
stop_payload() {
  python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2],"hook_event_name":"Stop","stop_hook_active":False}))' "$1" "$REPO"
}

# (1) start creates one active record and is idempotent for the same session+command.
contract start --repo "$REPO" --session "$S1" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'Drive first' --source user >/dev/null
contract start --repo "$REPO" --session "$S1" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'Drive first' --source user >/dev/null
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "start must upsert one active command record"
echo "  ok (1) start upserts exactly one active command record (idempotent)"

# (2) Stop blocks an active command with no closeout.
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
grep -q '"decision": "block"' "$OUT" || gov_fail "active command escaped Stop"
grep -q 'idc_command_contract.py.*finish' "$OUT" || gov_fail "block lacks exact remediation"
echo "  ok (2) Stop closeout gate blocks an open command + names the exact finish remediation"

# (3) the record cannot be cleared with an unknown or malformed status. Two isolating probes so the
# status guard is exercised on its OWN, not masked by the envelope check: (3a) the spec's exact case
# (unknown status + empty evidence); (3b) an unknown status with an OTHERWISE-VALID envelope, so ONLY
# the status guard can reject it (red-when-broken for the status check specifically).
if contract finish --repo "$REPO" --session "$S1" --command think --status done \
  --evidence-json '{}'; then
  gov_fail "unrecognized status cleared the obligation"
fi
if contract finish --repo "$REPO" --session "$S1" --command think --status done \
  --evidence-json '{"schema_version":1,"refs":{}}'; then
  gov_fail "an unknown status with a valid envelope must still be rejected (status guard)"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "a rejected finish must leave the active record intact"
echo "  ok (3) an unknown/malformed terminal status cannot clear the obligation (status guard isolated)"

# (4) a schema-valid waiting_gate closeout ends the command honestly.
contract finish --repo "$REPO" --session "$S1" --command think --status waiting_gate \
  --evidence-json '{"schema_version":1,"refs":{"think_pr":706,"gate":708,"pointer":707}}'
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
[ ! -s "$OUT" ] || gov_fail "valid waiting_gate closeout still blocked Stop"
echo "  ok (4) a schema-valid waiting_gate closeout ends the command → Stop no longer blocks"

# (5) a different session cannot finish or inherit S1's record.
if contract finish --repo "$REPO" --session "$S2" --command think --status no_action \
  --evidence-json '{"schema_version":1}'; then
  gov_fail "foreign session finished S1's command"
fi
echo "  ok (5) a foreign session cannot finish/inherit another session's command record"

echo "PASS: the IDC command lifecycle envelope holds — start upserts one obligation, Stop refuses an open command with the exact finish remediation, an unknown/malformed status cannot clear it, a schema-valid closeout ends it, and no foreign session can finish another's record"
