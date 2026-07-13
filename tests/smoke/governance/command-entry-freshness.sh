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

# (f) Fix 1 — read_version() must not CRASH on valid-but-wrong-shape JSON. A manifest whose top-level
#     JSON is a list (`[]`) — valid JSON, wrong shape — must be treated as an unreadable version
#     (None), NOT raise AttributeError. The recovery/allow path calls read_version a SECOND time
#     (registration) OUTSIDE the main gate's try/except, so a raise there crashes the hook with no
#     lifecycle record — violating "a recovery command allowed for any fail-closed reason owns a
#     record." A governed `doctor` on a non-stale runtime with a wrong-shape manifest must still be
#     ALLOWED and still OPEN its record, with no crash.
#     Red-when-broken: let read_version do `json.load(f).get("version")` on `[]` ⇒ AttributeError
#     escapes the recovery registration ⇒ no additionalContext + no active record ⇒ FAILs.
REPO_F="$WORK/repo-f"; mkdir -p "$REPO_F/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_F/docs/workflow/tracker-config.yaml"
printf 'receipt_version: 2\nplugin_version: 4.0.0\n' > "$REPO_F/docs/workflow/install-receipt.yaml"
BADSHAPE_PLUGIN="$WORK/plugin-badshape"; mkdir -p "$BADSHAPE_PLUGIN/.claude-plugin"
printf '[]\n' > "$BADSHAPE_PLUGIN/.claude-plugin/plugin.json"
emit_expansion_repo() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
print(json.dumps({
    "session_id": "S-shape",
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
if ! OUT="$(emit_expansion_repo idc:doctor '' "$REPO_F" | python3 "$ENTRY_GATE" "$BADSHAPE_PLUGIN")"; then
  gov_fail "(f) the entry gate CRASHED on a wrong-shape (\`[]\`) plugin manifest (read_version raised)"
fi
printf '%s' "$OUT" | grep -q 'additionalContext' \
  || gov_fail "(f) doctor on a wrong-shape manifest was not allowed to expand"
python3 "$GOV_PLUGIN/scripts/idc_command_contract.py" status --repo "$REPO_F" --session S-shape --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if sum(1 for r in d["active"] if r.get("command")=="doctor")==1 else 1)' \
  || gov_fail "(f) doctor was allowed on a wrong-shape manifest but did NOT open its lifecycle record (Fix 1)"
echo "  ok (f) a wrong-shape (\`[]\`) plugin manifest does not crash the gate; doctor is allowed AND opens its record"

# (g) Fix 2 — the FAILED-WRITE / admission contract, proven across the THREE ways it must hold. When
#     the per-session state ledger cannot persist (an unwritable repo root → the temp-file create
#     fails), the gate must react HONESTLY per command class, and a failed closeout must never be
#     reported as a close. EVERY sub-case below is guarded by an EXPLICIT exit-status check, so a hook
#     that CRASHED (non-zero, empty output) fails the case loudly instead of sliding past a mere
#     "no forbidden text / no record" check — which an empty output would satisfy vacuously.
REPO_G="$WORK/repo-g"; mkdir -p "$REPO_G/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_G/docs/workflow/tracker-config.yaml"
printf 'receipt_version: 2\nplugin_version: 4.0.0\n' > "$REPO_G/docs/workflow/install-receipt.yaml"
# emit_expansion_g <command> <args> <repo> <session> — a UserPromptExpansion payload with an explicit
# session so each sub-case reads back its OWN ledger without cross-talk.
emit_expansion_g() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
print(json.dumps({
    "session_id": sys.argv[4],
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
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
# no_active <repo> <session> <command>: exit 0 iff NO active record for that command+session.
no_active() {
  python3 "$CONTRACT" status --repo "$1" --session "$2" --json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); c=sys.argv[1]; sys.exit(0 if not any(r.get("command")==c for r in d["active"]) else 1)' "$3"
}

# (g1) a WORKFLOW command (think) whose obligation CANNOT be recorded must be BLOCKED — never admitted
#      UNRECORDED, because the Stop closeout gate could not then enforce its closeout. The refusal is
#      SPECIFICALLY the write-failure block (not bootstrap, not admission, not the stale/repair reason),
#      the hook EXITS 0 (a clean block, not a crash), and NO active record exists.
#      Red-when-broken: drop the `command in WORKFLOW_COMMANDS` write-fail block ⇒ think is bootstrap-
#      admitted instead of blocked ⇒ the `"decision": "block"` assertion FAILs. Make that path
#      `raise SystemExit(3)` ⇒ the exit-0 assertion FAILs (a crash is caught, not passed).
chmod 500 "$REPO_G"   # read+traverse, NO write → the ledger temp-file create fails (write cannot persist)
OUT="$(emit_expansion_g idc:think 'Drive first' "$REPO_G" S-wf-think | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"; RC=$?
chmod 700 "$REPO_G"   # restore so the status readback + cleanup are unambiguous
[ "$RC" -eq 0 ] \
  || gov_fail "(g1) the entry gate did NOT exit 0 on a workflow write-failure (a crash, not a clean block)"
printf '%s' "$OUT" | grep -q '"decision": "block"' \
  || gov_fail "(g1) a workflow command whose obligation could not be recorded was NOT blocked"
printf '%s' "$OUT" | grep -q 'could not record the command' \
  || gov_fail "(g1) the refusal was not the write-failure block (wrong reason: bootstrap/admission/stale/repair)"
if printf '%s' "$OUT" | grep -q 'additionalContext'; then
  gov_fail "(g1) a blocked workflow command still emitted admission context"
fi
no_active "$REPO_G" S-wf-think think \
  || gov_fail "(g1) status shows an active record even though the ledger write failed (Fix 2)"
echo "  ok (g1) a workflow command whose obligation cannot be recorded is BLOCKED (not admitted); no active record"

# (g2) a RECOVERY command (doctor) on the SAME write-failure must still EXPAND to help the operator,
#      but with the BOOTSTRAP context that does NOT falsely claim a record opened — and NO active
#      record exists. It must NOT be blocked (recovery may run to diagnose) and must NOT claim a record.
#      Red-when-broken: emit the record-owed context on the recovery write-fail path (opened=True) ⇒
#      the "opened a governed command record" claim assertion FAILs.
chmod 500 "$REPO_G"
OUT="$(emit_expansion_g idc:doctor '' "$REPO_G" S-wf-doctor | python3 "$ENTRY_GATE" "$CURRENT_PLUGIN")"; RC=$?
chmod 700 "$REPO_G"
[ "$RC" -eq 0 ] \
  || gov_fail "(g2) the entry gate did NOT exit 0 on a recovery write-failure (a crash)"
printf '%s' "$OUT" | grep -q 'additionalContext' \
  || gov_fail "(g2) a recovery command was NOT allowed to expand on a write-failure"
if printf '%s' "$OUT" | grep -q 'opened a governed command record'; then
  gov_fail "(g2) a recovery command FALSELY claimed a record opened despite the failed write (Fix 2)"
fi
if printf '%s' "$OUT" | grep -q '"decision": "block"'; then
  gov_fail "(g2) a recovery command was BLOCKED instead of expanding with bootstrap context"
fi
no_active "$REPO_G" S-wf-doctor doctor \
  || gov_fail "(g2) status shows an active record for a recovery command whose ledger write failed (Fix 2)"
echo "  ok (g2) a recovery command on a write-failure expands with bootstrap context (no false 'record opened'); no active record"

# (g3) a FAILED `command_finish` write must be reported as a FAILURE (non-zero) AND MUST leave the
#      command ACTIVE — otherwise the Stop closeout gate would believe an un-closed command was closed.
#      Open a real record first (writable, current runtime), then make the repo unwritable so the
#      closeout's atomic write cannot persist.
#      Red-when-broken: have command_finish ignore the atomic-write result (return the record even when
#      the write failed) ⇒ `finish` exits 0 ⇒ the non-zero-report assertion FAILs.
REPO_G3="$WORK/repo-g3"; mkdir -p "$REPO_G3/docs/workflow"
printf 'backend: filesystem\n' > "$REPO_G3/docs/workflow/tracker-config.yaml"
printf 'receipt_version: 2\nplugin_version: 4.0.0\n' > "$REPO_G3/docs/workflow/install-receipt.yaml"
python3 "$CONTRACT" start --repo "$REPO_G3" --session S-finishfail --command doctor \
  --plugin-root "$CURRENT_PLUGIN" >/dev/null \
  || gov_fail "(g3) could not open the doctor record to set up the finish-failure case"
no_active "$REPO_G3" S-finishfail doctor \
  && gov_fail "(g3) precondition failed — the doctor record did not open before the finish-failure step"
chmod 500 "$REPO_G3"   # the closeout's atomic write now cannot persist
python3 "$CONTRACT" finish --repo "$REPO_G3" --session S-finishfail --command doctor \
  --status complete --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null 2>&1; RC=$?
chmod 700 "$REPO_G3"
[ "$RC" -ne 0 ] \
  || gov_fail "(g3) a FAILED finish write was reported as SUCCESS (exit 0) — a false close (Fix 2)"
no_active "$REPO_G3" S-finishfail doctor \
  && gov_fail "(g3) the command is NO LONGER active after a FAILED finish write (closeout falsely recorded)"
echo "  ok (g3) a failed command_finish write reports failure (non-zero) AND leaves the command active"

echo "PASS: the command entry gate refuses a stale runtime with an actionable reload instruction, admits a current runtime while opening its lifecycle record, opens a record for a recovery command allowed on an invalid receipt, blocks a stale runtime even when the receipt is invalid (positive-stale precedence), does not crash on a wrong-shape plugin manifest (Fix 1), and honestly handles a failed ledger write (Fix 2): a workflow command is BLOCKED and unrecorded (g1), a recovery command still expands with bootstrap context and no false 'record opened' claim (g2), and a failed command_finish reports failure while leaving the command active (g3); plus the admission-category matrix (workflow fail-closed on an invalid receipt; recovery/janitor/init may expand; all blocked when positively stale)"
