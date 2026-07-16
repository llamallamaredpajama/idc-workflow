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
# A real empty board so the Task-6 oracle can back a no_action closeout (build no_action must PROVE
# the ready frontier is empty via a fresh idc_next_action read; without TRACKER.md the oracle reads
# invalid-tracker and no_action would be refused for the WRONG reason).
python3 "$GOV_TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "could not init REPO board"
OUT="$WORK/out.json"

# A valid think waiting_gate evidence envelope (Task 6): the Think PR OPEN, its one gate marker still
# blocked, the consideration pointer still blocked. Reused by the idempotency + finished-cap cases.
THINK_WAIT_EV='{"schema_version":1,"refs":{"consideration":"pass","think_pr":706,"think_pr_state":"OPEN","gate":708,"gate_markers":1,"gate_disposition":"blocked","pointer":707,"pointer_state":"blocked"}}'
# Per-run-unique session ids (the "S1"/"S2" of the contract spec): the Stop closeout gate's anti-nag
# counter (idc_hook_lib.bounded_block) is a PERSISTENT per-user-tmp file keyed by session+command, so
# a fixed "S1" would accumulate across reruns and stop blocking after N=3 — the same hermetic-id
# pattern the sibling stop-ledger-alone-never-blocks.sh uses.
S1="s1-$$-$(basename "$WORK")"
S2="s2-$$-$(basename "$WORK")"
# Mirror of idc_ledger._MAX_FINISHED — the finished-history cap (case 6).
_MAX_FINISHED_EXPECT=20

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

# (2) Stop blocks an active command with no closeout, and the block names the REAL absolute path to
# idc_command_contract.py under the plugin root the gate was given — NOT the literal
# `${CLAUDE_PLUGIN_ROOT}` token (which is markdown-only; a Python-emitted literal resolves to the
# broken `/scripts/idc_command_contract.py`). Red-when-broken for Fix 1: emit the literal token ⇒ the
# absolute-path assertion FAILs and the no-literal-token assertion FAILs.
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
grep -q '"decision": "block"' "$OUT" || gov_fail "active command escaped Stop"
grep -F -q "$GOV_PLUGIN/scripts/idc_command_contract.py" "$OUT" \
  || gov_fail "block remediation lacks the REAL absolute idc_command_contract.py path (literal/basename)"
grep -q 'idc_command_contract.py.*finish' "$OUT" || gov_fail "block lacks the exact finish remediation"
if grep -q 'CLAUDE_PLUGIN_ROOT' "$OUT"; then
  gov_fail "block remediation still emits the literal \${CLAUDE_PLUGIN_ROOT} token (not interpolated)"
fi
echo "  ok (2) Stop closeout gate blocks an open command + names the exact finish remediation (real absolute path)"

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

# (3.1) COMMON-ENVELOPE guards, each isolated (valid command/status/refs so ONLY the schema_version
# guard can reject) — Fix 4. `schema_version` must be the INTEGER 1: Python's `True == 1` and
# `1.0 == 1`, so a naive equality check would let JSON `true` (bool) and `1.0` (float) through.
# Red-when-broken: relax the guard back to a bare `== 1` ⇒ (3.1a)/(3.1b) go green-accept ⇒ FAIL.
if contract finish --repo "$REPO" --session "$S1" --command think --status no_action \
  --evidence-json '{"schema_version":true,"refs":{}}'; then
  gov_fail "(3.1a) schema_version: true (bool) was accepted as the integer 1"
fi
if contract finish --repo "$REPO" --session "$S1" --command think --status no_action \
  --evidence-json '{"schema_version":1.0,"refs":{}}'; then
  gov_fail "(3.1b) schema_version: 1.0 (float) was accepted as the integer 1"
fi
# (3.1c) the `refs`-is-object guard, isolated (valid schema_version, non-object refs). Red-when-broken:
# drop the refs-object check ⇒ this valid-otherwise finish succeeds ⇒ FAIL.
if contract finish --repo "$REPO" --session "$S1" --command think --status no_action \
  --evidence-json '{"schema_version":1,"refs":[]}'; then
  gov_fail "(3.1c) a non-object refs was accepted"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "rejected envelope finishes must leave the active record intact"
echo "  ok (3.1) common-envelope guards isolated: schema_version rejects true/1.0, refs must be an object"

# (4) a schema-valid, command-specific-valid waiting_gate closeout ends the command honestly. Under
# Task 6 the think closeout must carry the real artifacts (PR OPEN, one gate marker blocked, pointer
# blocked) — a bare refs no longer clears it (proven in the Task-6 section below).
contract finish --repo "$REPO" --session "$S1" --command think --status waiting_gate \
  --evidence-json "$THINK_WAIT_EV"
stop_payload "$S1" | python3 "$CLOSEOUT_GATE" "$GOV_PLUGIN" > "$OUT"
[ ! -s "$OUT" ] || gov_fail "valid waiting_gate closeout still blocked Stop"
echo "  ok (4) a schema-valid waiting_gate closeout ends the command → Stop no longer blocks"

# (5) a different session cannot finish or inherit S1's ACTIVE record — isolated on OWNERSHIP (Fix 3).
# Open a fresh ACTIVE record for S1 (`build`), then have S2 attempt to finish it with a FULLY VALID
# envelope + terminal status, so the ONLY possible rejection is foreign-session ownership. (The old
# case handed S2 an invalid envelope — missing `refs` — so it was rejected by the envelope check
# BEFORE ownership ran, and dropping the ownership check would not have failed the test.)
# Red-when-broken: drop the session match in command_finish ⇒ S2 finishes S1's build ⇒ rc 0 ⇒ FAIL.
contract start --repo "$REPO" --session "$S1" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'build it' --source user >/dev/null
if contract finish --repo "$REPO" --session "$S2" --command build --status no_action \
  --evidence-json '{"schema_version":1,"refs":{}}'; then
  gov_fail "foreign session finished S1's active record despite a valid envelope (ownership not enforced)"
fi
[ "$(contract status --repo "$REPO" --session "$S1" --json | json_count active)" -eq 1 ] \
  || gov_fail "the foreign finish attempt must leave S1's active build record intact"
echo "  ok (5) a foreign session cannot finish/inherit another session's active record (ownership isolated)"

# (6) the finished-history cap drops the OLDEST finished record and RETAINS the just-finished newest
# one, even when the record being finished is OLD in write order (Fix 2). Uses an isolated ledger so
# the count is exact. Scenario: open ACTIVE `keep`, then start+finish 20 OTHER sessions (they append
# after `keep` and finish in place), then finish `keep` LAST. `keep` is now the OLDEST by list
# position but the NEWEST by finish order — the cap must key on finish order, so `keep` is retained
# and the first of the twenty (n01) is dropped. Red-when-broken: finish a record in place without
# moving it to newest ⇒ `keep` (oldest position) is pruned as the "oldest finished" ⇒ FAIL.
REPO2="$WORK/repo2"; mkdir -p "$REPO2/docs/workflow"
printf 'backend: filesystem\n' > "$REPO2/docs/workflow/tracker-config.yaml"
KEEP="keep-$$-$(basename "$WORK")"
contract start --repo "$REPO2" --session "$KEEP" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'first in, last out' --source user >/dev/null
for i in $(seq -w 1 20); do
  SI="n${i}-$$-$(basename "$WORK")"
  contract start --repo "$REPO2" --session "$SI" --command think --plugin-root "$GOV_PLUGIN" \
    --args "fill $i" --source user >/dev/null
  contract finish --repo "$REPO2" --session "$SI" --command think --status waiting_gate \
    --evidence-json "$THINK_WAIT_EV" >/dev/null \
    || gov_fail "(6) could not finish filler record $i"
done
contract finish --repo "$REPO2" --session "$KEEP" --command think --status waiting_gate \
  --evidence-json "$THINK_WAIT_EV" >/dev/null \
  || gov_fail "(6) could not finish the KEEP record"
[ "$(contract status --repo "$REPO2" --json | json_count finished)" -eq "$_MAX_FINISHED_EXPECT" ] \
  || gov_fail "(6) finished history is not capped at $_MAX_FINISHED_EXPECT records"
contract status --repo "$REPO2" --json | grep -q "$KEEP" \
  || gov_fail "(6) newest-finish-retained: the just-finished record was pruned (cap dropped the newest, not the oldest)"
if contract status --repo "$REPO2" --json | grep -q "n01-$$-"; then
  gov_fail "(6) oldest-finished-dropped: the oldest finished record survived the cap"
fi
echo "  ok (6) the finished cap drops the OLDEST + retains the just-finished NEWEST record"

# ============================================================================================
# (7) Task 6 — the command-specific closeout matrix. Evidence is a set of REFERENCES: a closeout can
# no longer clear an obligation with a bare valid envelope; the finishing status must be LEGAL for the
# command, and the command's required artifacts (a MERGED PR, a disposed gate, this session's drain,
# an independently-reviewed intake manifest, …) must be present. Two facts are re-verified from durable
# state rather than trusted — intake coverage (re-read from the manifest) and every no_action (a fresh
# oracle) — so a closeout that MATERIALIZES ONE INTAKE UNIT BUT DROPS THE REST IS BLOCKED.
INTAKE="$GOV_PLUGIN/scripts/idc_intake_manifest.py"
[ -f "$INTAKE" ] || gov_fail "scripts/idc_intake_manifest.py not found"

REPO3="$WORK/repo3"; mkdir -p "$REPO3/docs/workflow/intakes"
printf 'backend: filesystem\n' > "$REPO3/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO3/TRACKER.md" init >/dev/null || gov_fail "could not init REPO3 board"
S3="s3-$$-$(basename "$WORK")"

# Build a reviewed intake manifest (Drive + U1 + U2) through the real Task-4 helper, then materialize
# only Drive. U1/U2 stay queued — a valid durable remainder.
SRC="$REPO3/life-plan.md"
MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-life.json"
MANIFEST_REL="docs/workflow/intakes/2026-07-12-life.json"
printf '# Drive - foundation\n\nbody\n\n## U1 - first unit\n\nbody\n\n## U2 - second unit\n\nbody\n' > "$SRC"
python3 "$INTAKE" extract --source "$SRC" --out "$MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(7) intake extract failed"
python3 - "$MANIFEST" <<'PY' || gov_fail "(7) could not classify manifest"
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for unit in data["units"]:
    unit.update({"class": "new_requirement", "route": "think", "dependencies": [], "operator_stops": []})
    unit["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".life-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as h:
    json.dump(data, h, indent=2, sort_keys=True); h.write("\n")
os.replace(tmp, path)
PY
SUPPLIED_REVIEW="$REPO3/supplied-review.json"
python3 - "$INTAKE" "$MANIFEST" "$SUPPLIED_REVIEW" <<'PY' || gov_fail "(7) could not write review"
import importlib.util, json, sys
helper_path, manifest_path, review_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_for_lifecycle", helper_path)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
manifest = json.load(open(manifest_path, encoding="utf-8"))
review = {"schema_version": 1, "intake_id": manifest["intake_id"],
          "source_sha256": manifest["source"]["sha256"], "verdict": "PASS",
          "missing_unit_ids": [], "duplicate_unit_ids": [], "misrouted_unit_ids": [],
          "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(manifest)}"]}
json.dump(review, open(review_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
python3 "$INTAKE" validate --manifest "$MANIFEST" --review "$SUPPLIED_REVIEW" >/dev/null \
  || gov_fail "(7) could not validate reviewed manifest"
python3 "$INTAKE" link --manifest "$MANIFEST" --unit Drive --state materialized \
  --target-ref "think-pr:706" --evidence "gate:708" --evidence "pointer:707" >/dev/null \
  || gov_fail "(7) could not materialize Drive"

think_complete_ev() {
  # $1 = manifest repo-relative locator, $2 = selected JSON array
  printf '{"schema_version":1,"refs":{"consideration":"pass","think_pr":706,"think_pr_state":"MERGED","gate":708,"gate_markers":1,"gate_disposition":"disposed","pointer":707,"pointer_state":"admitted","intake_manifest":"%s","intake_selected":%s}}' "$1" "$2"
}

# (7a) a think complete with Drive materialized + U1/U2 durably queued PASSES.
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'life' --source user >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command think --status complete \
  --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" \
  || gov_fail "(7a) a complete think with full intake coverage was rejected"
echo "  ok (7a) think complete accepts full intake coverage (selected materialized, remainder durable)"

# (7b) THE STEP-8 GUARANTEE: a think complete that materializes Drive but DROPS U1/U2 from the
# exact-once manifest is BLOCKED — the closeout re-reads the manifest and the drop fails validation.
# Red-when-broken: skip the manifest re-read in _check_intake_coverage and this bogus close succeeds.
DROP_MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-drop.json"
DROP_REL="docs/workflow/intakes/2026-07-12-drop.json"
python3 - "$MANIFEST" "$DROP_MANIFEST" <<'PY' || gov_fail "(7b) could not build dropped manifest"
import json, sys
src, dst = sys.argv[1:]
data = json.load(open(src, encoding="utf-8"))
# Drop U1 + U2 from units but KEEP them in expected_unit_ids -> exact-once mismatch (the drop).
data["units"] = [u for u in data["units"] if u["id"] == "Drive"]
data["intake_id"] = "2026-07-12-drop"
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
contract start --repo "$REPO3" --session "$S3" --command think --plugin-root "$GOV_PLUGIN" \
  --args 'life-drop' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command think --status complete \
     --evidence-json "$(think_complete_ev "$DROP_REL" '["Drive"]')" 2>/dev/null; then
  gov_fail "(7b) a think closeout that materialized Drive but dropped U1/U2 was ACCEPTED (intake coverage not re-verified)"
fi
[ "$(contract status --repo "$REPO3" --session "$S3" --json | json_count active)" -eq 1 ] \
  || gov_fail "(7b) the rejected drop-coverage finish must leave the think record active"
# close it honestly so the record does not leak.
contract finish --repo "$REPO3" --session "$S3" --command think --status complete \
  --evidence-json "$(think_complete_ev "$MANIFEST_REL" '["Drive"]')" >/dev/null \
  || gov_fail "(7b) could not honestly close the drop-case think record"
echo "  ok (7b) a think closeout that drops units from the exact-once manifest is BLOCKED (Step-8)"

# (7c) legal-status-per-command: a lifecycle/diagnostic command may not claim a pipeline no_action.
contract start --repo "$REPO3" --session "$S3" --command doctor --plugin-root "$GOV_PLUGIN" \
  --args 'diag' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command doctor --status no_action \
     --evidence-json '{"schema_version":1,"refs":{}}' 2>/dev/null; then
  gov_fail "(7c) doctor no_action (an illegal terminal status for a diagnostic command) was accepted"
fi
# doctor's honest complete: rows + a verdict (even a FAIL verdict is a complete doctor run).
contract finish --repo "$REPO3" --session "$S3" --command doctor --status complete \
  --evidence-json '{"schema_version":1,"refs":{"rows":["1..10"],"verdict":"FAIL"}}' \
  || gov_fail "(7c) doctor complete with rows + a FAIL verdict was rejected"
echo "  ok (7c) legal-status-per-command holds (doctor may not claim no_action; a FAIL verdict still completes)"

# (7d) blocked_external is an HONEST blocked stop, never a disguised success: it must cite a
# deterministic helper's NONZERO exit + a concise diagnostic. A zero exit is not a blocker.
contract start --repo "$REPO3" --session "$S3" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'b' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":0,"diagnostic":"ok"}}}' 2>/dev/null; then
  gov_fail "(7d) a blocked_external with a ZERO helper exit was accepted (a blocker is not a success)"
fi
# (7d-sabotage, finding 1) the cited helper must be a REAL shipped deterministic helper — a phantom
# helper name (nonzero exit + diagnostic and all) is refused: the referenced artifact must exist.
if contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
     --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"totally_not_a_real_helper.py","exit":3,"diagnostic":"phantom"}}}' 2>/dev/null; then
  gov_fail "(7d-sabotage) a blocked_external citing a PHANTOM helper (not shipped under scripts/) was accepted"
fi
contract finish --repo "$REPO3" --session "$S3" --command build --status blocked_external \
  --evidence-json '{"schema_version":1,"refs":{"blocker":{"helper":"idc_autorun_drain.py","exit":3,"diagnostic":"github GraphQL rate-limited until reset"}}}' \
  || gov_fail "(7d) a blocked_external citing a nonzero helper exit + diagnostic was rejected"
echo "  ok (7d) blocked_external requires a deterministic helper's NONZERO exit + a diagnostic"

# (7e, finding 1) autorun complete reads THIS session's PERSISTED drain verdict
# (.idc-drain-verdict.json) — a DURABLE artifact — never a caller-supplied drain string. Write a real
# complete verdict for S3, then close WITHOUT any caller drain claim: the artifact is what clears it.
DV="$GOV_PLUGIN/scripts/hooks/idc_drain_verdict.py"
[ -f "$DV" ] || gov_fail "scripts/hooks/idc_drain_verdict.py not found"
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "$S3" \
  || gov_fail "(7e) could not persist a drain verdict"
contract start --repo "$REPO3" --session "$S3" --command autorun --plugin-root "$GOV_PLUGIN" \
  --args 'a' --source user >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' \
  || gov_fail "(7e) an autorun complete backed by THIS session's persisted drain: complete verdict was rejected"
echo "  ok (7e) autorun complete is cleared by the durable .idc-drain-verdict.json (this session, verdict complete)"
# (7e-sabotage) a FORGED caller drain claim with the persisted verdict FOREIGN/absent fails closed —
# the drain status is read from the durable artifact, not the caller's evidence.
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "someone-else" \
  || gov_fail "(7e) could not overwrite the drain verdict to a foreign session"
contract start --repo "$REPO3" --session "$S3" --command autorun --plugin-root "$GOV_PLUGIN" \
  --args 'a2' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
     --evidence-json "$(printf '{"schema_version":1,"refs":{"drain":"complete","drain_session":"%s"}}' "$S3")" 2>/dev/null; then
  gov_fail "(7e-sabotage) an autorun complete with a FORGED caller drain claim but a foreign persisted verdict was ACCEPTED (drain status must come from the durable artifact)"
fi
python3 "$DV" --cwd "$REPO3" write --verdict complete --exit 0 --session "$S3" >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command autorun --status complete \
  --evidence-json '{"schema_version":1,"refs":{}}' >/dev/null \
  || gov_fail "(7e-sabotage) could not honestly close the autorun record"
echo "  ok (7e-sabotage) a forged caller drain claim with a foreign/absent verdict is refused (durable artifact wins)"

# (7f, finding 1) plan complete re-validates a DURABLE matrix artifact (idc_matrix_check), never a
# caller "pass" string.
mkdir -p "$REPO3/docs/workflow/pillar-matrices"
GOODMX="docs/workflow/pillar-matrices/good.yaml"
cat > "$REPO3/$GOODMX" <<'YML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/a/]
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: api
    surfaces: [src/b/]
    blocks_on: []
YML
plan_complete_ev() {  # $1 = matrix repo-relative locator
  printf '{"schema_version":1,"refs":{"matrix":"%s","planning_pr":42,"planning_pr_state":"MERGED","decompositions":{"5":101},"pointers_retired":[5]}}' "$1"
}
contract start --repo "$REPO3" --session "$S3" --command plan --plugin-root "$GOV_PLUGIN" \
  --args 'p' --source user >/dev/null
contract finish --repo "$REPO3" --session "$S3" --command plan --status complete \
  --evidence-json "$(plan_complete_ev "$GOODMX")" \
  || gov_fail "(7f) a plan complete backed by a re-validated matrix + merged PR + real decomposition children was rejected"
echo "  ok (7f) plan complete re-validates the durable matrix artifact (idc_matrix_check), not a caller 'pass' string"
# (7f-sabotage) a colliding matrix (same wave, shared surface) and a missing matrix both fail closed.
BADMX="docs/workflow/pillar-matrices/collide.yaml"
cat > "$REPO3/$BADMX" <<'YML'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/x/]
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: ui
    surfaces: [src/x/]
    blocks_on: []
YML
contract start --repo "$REPO3" --session "$S3" --command plan --plugin-root "$GOV_PLUGIN" \
  --args 'p2' --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S3" --command plan --status complete \
     --evidence-json "$(plan_complete_ev "$BADMX")" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete whose referenced matrix FAILS deconfliction (same-wave shared surface) was accepted"
fi
if contract finish --repo "$REPO3" --session "$S3" --command plan --status complete \
     --evidence-json "$(plan_complete_ev "docs/workflow/pillar-matrices/nope.yaml")" 2>/dev/null; then
  gov_fail "(7f-sabotage) a plan complete referencing a MISSING matrix file was accepted"
fi
contract finish --repo "$REPO3" --session "$S3" --command plan --status complete \
  --evidence-json "$(plan_complete_ev "$GOODMX")" >/dev/null \
  || gov_fail "(7f-sabotage) could not honestly close the plan record"
echo "  ok (7f-sabotage) plan complete fails closed on a colliding or missing matrix artifact"

# (7g, finding 1) build complete requires STRUCTURED merged-PR receipts (a real PR ref + MERGED
# state), not an arbitrary receipt string; the empty-frontier path is oracle-backed. Runs on a FRESH
# clean board (REPO5) — REPO3 carries case-7b's intentionally-invalid intake manifest, which correctly
# makes the oracle fail-closed (invalid), so the oracle-backed empty-frontier close needs a clean repo.
REPO5="$WORK/repo5"; mkdir -p "$REPO5/docs/workflow"
printf 'backend: filesystem\n' > "$REPO5/docs/workflow/tracker-config.yaml"
python3 "$GOV_TRK" --tracker "$REPO5/TRACKER.md" init >/dev/null || gov_fail "could not init REPO5 board"
S6="s6-$$-$(basename "$WORK")"
contract start --repo "$REPO5" --session "$S6" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'bb' --source user >/dev/null
contract finish --repo "$REPO5" --session "$S6" --command build --status complete \
  --evidence-json '{"schema_version":1,"refs":{"receipts":{"101":{"pr":55,"state":"MERGED"}}}}' \
  || gov_fail "(7g) a build complete with a structured merged-PR receipt was rejected"
echo "  ok (7g) build complete requires structured merged-PR receipts (real PR ref + MERGED state)"
# (7g-sabotage) an arbitrary receipt string, and an unmerged-PR receipt, both fail closed.
contract start --repo "$REPO5" --session "$S6" --command build --plugin-root "$GOV_PLUGIN" \
  --args 'bb2' --source user >/dev/null
if contract finish --repo "$REPO5" --session "$S6" --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"101":"done"}}}' 2>/dev/null; then
  gov_fail "(7g-sabotage) a build complete with an ARBITRARY receipt string (no real PR reference) was accepted"
fi
if contract finish --repo "$REPO5" --session "$S6" --command build --status complete \
     --evidence-json '{"schema_version":1,"refs":{"receipts":{"101":{"pr":55,"state":"OPEN"}}}}' 2>/dev/null; then
  gov_fail "(7g-sabotage) a build complete whose receipt PR is not MERGED was accepted"
fi
contract finish --repo "$REPO5" --session "$S6" --command build --status complete \
  --evidence-json '{"schema_version":1,"refs":{"frontier":"none-eligible"}}' >/dev/null \
  || gov_fail "(7g) a build complete via an oracle-backed empty ready frontier was rejected"
echo "  ok (7g-sabotage) build complete fails closed on an arbitrary/unmerged receipt; empty frontier is oracle-backed"

# (8) Finding 5 — an EMPTY session identity is refused fail-closed. Codex/Pi fire no
# UserPromptExpansion and set no CLAUDE_CODE_SESSION_ID, so a bare `--session "$CLAUDE_CODE_SESSION_ID"`
# is empty there; the ledger/contract layer must refuse it so two anonymous sessions can never collide
# on (session="", command). Red-when-broken: drop the empty-session guard in command_start/finish ⇒
# an anonymous record is opened/finished ⇒ these asserts FAIL.
if contract start --repo "$REPO" --session "" --command think --plugin-root "$GOV_PLUGIN" \
     --args 'anon' --source codex 2>/dev/null; then
  gov_fail "(8) an empty session identity opened a command record (anonymous obligation)"
fi
anon_active=$(contract status --repo "$REPO" --json \
  | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin)["active"] if not str(c.get("session_id","")).strip()))')
[ "$anon_active" -eq 0 ] || gov_fail "(8) an anonymous (session=\"\") active record was written to the ledger"
if contract finish --repo "$REPO" --session "" --command think --status waiting_gate \
     --evidence-json "$THINK_WAIT_EV" 2>/dev/null; then
  gov_fail "(8) an empty session identity finished a command record"
fi
echo "  ok (8) an empty session identity is refused fail-closed (no anonymous record opened or finished)"

# (9) Finding 4 — Uninstall's closeout must run WHILE the repo is still governed. Uninstall removes
# docs/workflow/tracker-config.yaml (what marks the repo governed); once it is gone the ledger is a
# repo-gated no-op and a finish CANNOT land, so the command must finish BEFORE that removal. Walk both
# orders on a real governed repo. (Never restore via `git checkout` — REPO4 is a throwaway; just rm.)
REPO4="$WORK/repo4"; mkdir -p "$REPO4/docs/workflow"
printf 'backend: filesystem\n' > "$REPO4/docs/workflow/tracker-config.yaml"
S4="s4-$$-$(basename "$WORK")"
UNINSTALL_EV='{"schema_version":1,"refs":{"outcome":"applied","archive":"idc-archive-20260712-000000.tar.gz"}}'
# (9a) the documented order — finish WHILE governed → succeeds and the record closes.
contract start --repo "$REPO4" --session "$S4" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall' --source user >/dev/null
contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
  --evidence-json "$UNINSTALL_EV" \
  || gov_fail "(9a) an uninstall finish WHILE the repo is still governed was rejected — the documented order must succeed"
[ "$(contract status --repo "$REPO4" --session "$S4" --json | json_count active)" -eq 0 ] \
  || gov_fail "(9a) the uninstall record did not close on a governed-repo finish"
# (9b) the WHY: after tracker-config.yaml is removed the repo is ungoverned and a finish CANNOT land —
# exactly why the closeout must PRECEDE the removal.
contract start --repo "$REPO4" --session "$S4" --command uninstall --plugin-root "$GOV_PLUGIN" \
  --args 'uninstall again' --source user >/dev/null
rm -f "$REPO4/docs/workflow/tracker-config.yaml"   # Phase 3's removal ungoverns the repo
if contract finish --repo "$REPO4" --session "$S4" --command uninstall --status complete \
     --evidence-json "$UNINSTALL_EV" 2>/dev/null; then
  gov_fail "(9b) an uninstall finish AFTER the repo was ungoverned unexpectedly succeeded — the closeout must run BEFORE the tracker-config.yaml removal"
fi
echo "  ok (9) uninstall finishes its record WHILE governed (a post-ungovern finish cannot land — closeout must precede removal)"

# (10) Finding 2 — intake mode is DURABLE on the record: a think started with `--doc/--unit` records
# that fact, and intake coverage is re-verified from the RECORD on EVERY closeout path — even a finish
# that omits the intake fields, and INCLUDING waiting_gate. Previously coverage ran only when the
# caller SUPPLIED refs.intake_manifest, so an intake-mode run could drop its selected unit simply by
# omitting the intake fields at finish (the bypass). Build a reviewed manifest whose units are all
# QUEUED (nothing materialized), so any honest coverage read fails.
S5="s5-$$-$(basename "$WORK")"
UNMAT_MANIFEST="$REPO3/docs/workflow/intakes/2026-07-12-unmat.json"
UNMAT_REL="docs/workflow/intakes/2026-07-12-unmat.json"
python3 "$INTAKE" extract --source "$SRC" --out "$UNMAT_MANIFEST" \
  --goal 'execute the whole program; Drive first' --plugin-version 4.1.0 >/dev/null \
  || gov_fail "(10) intake extract failed"
python3 - "$UNMAT_MANIFEST" <<'PY' || gov_fail "(10) could not classify unmat manifest"
import json, os, sys, tempfile
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
for unit in data["units"]:
    unit.update({"class": "new_requirement", "route": "think", "dependencies": [], "operator_stops": []})
    unit["disposition"] = {"state": "queued", "target_ref": None, "evidence": []}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".unmat-", suffix=".json")
with os.fdopen(fd, "w", encoding="utf-8") as h:
    json.dump(data, h, indent=2, sort_keys=True); h.write("\n")
os.replace(tmp, path)
PY
UNMAT_REVIEW="$REPO3/unmat-review.json"
python3 - "$INTAKE" "$UNMAT_MANIFEST" "$UNMAT_REVIEW" <<'PY' || gov_fail "(10) could not write unmat review"
import importlib.util, json, sys
helper_path, manifest_path, review_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_intake_unmat", helper_path)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
m = json.load(open(manifest_path, encoding="utf-8"))
review = {"schema_version": 1, "intake_id": m["intake_id"], "source_sha256": m["source"]["sha256"],
          "verdict": "PASS", "missing_unit_ids": [], "duplicate_unit_ids": [], "misrouted_unit_ids": [],
          "notes": [f"manifest_content_sha256={helper._manifest_content_sha256(m)}"]}
json.dump(review, open(review_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
python3 "$INTAKE" validate --manifest "$UNMAT_MANIFEST" --review "$UNMAT_REVIEW" >/dev/null \
  || gov_fail "(10) could not validate unmat manifest"
# A bare, otherwise-valid think complete envelope that OMITS intake_manifest/intake_selected.
THINK_COMPLETE_BARE='{"schema_version":1,"refs":{"consideration":"pass","think_pr":706,"think_pr_state":"MERGED","gate":708,"gate_markers":1,"gate_disposition":"disposed","pointer":707,"pointer_state":"admitted"}}'

# (10a) intake-mode record (--doc/--unit) + a bare think COMPLETE that omits the intake fields, on a
# manifest whose selected unit Drive is NOT materialized → REFUSED (coverage re-read from the record).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $UNMAT_REL --unit Drive" --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S5" --command think --status complete \
     --evidence-json "$THINK_COMPLETE_BARE" 2>/dev/null; then
  gov_fail "(10a) an intake-mode think (record carries --doc/--unit) closed WITHOUT materializing its selected unit by OMITTING the intake fields at finish — the coverage bypass"
fi
[ "$(contract status --repo "$REPO3" --session "$S5" --json | json_count active)" -eq 1 ] \
  || gov_fail "(10a) the rejected bypass finish must leave the think record active"
echo "  ok (10a) an intake-mode record enforces coverage from the RECORD even when the finish omits the intake fields (complete)"

# (10c) the same bypass on the WAITING_GATE path is closed too (coverage runs on EVERY path).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $UNMAT_REL --unit Drive" --source user >/dev/null
if contract finish --repo "$REPO3" --session "$S5" --command think --status waiting_gate \
     --evidence-json "$THINK_WAIT_EV" 2>/dev/null; then
  gov_fail "(10c) an intake-mode think WAITING_GATE closed WITHOUT materializing its selected unit — coverage must run on the waiting_gate path too"
fi
echo "  ok (10c) intake coverage is enforced on the waiting_gate path too (not only complete)"

# (10b) the record-based enforcement still ACCEPTS an honest close: reuse REPO3's $MANIFEST (Drive
# materialized, U1/U2 durably queued). An intake-mode record whose coverage is satisfied closes even
# though the finish omits the intake fields (they are read from the record, not the caller).
contract start --repo "$REPO3" --session "$S5" --command think --plugin-root "$GOV_PLUGIN" \
  --args "--doc $MANIFEST_REL --unit Drive" --source user >/dev/null
contract finish --repo "$REPO3" --session "$S5" --command think --status complete \
  --evidence-json "$THINK_COMPLETE_BARE" \
  || gov_fail "(10b) an intake-mode think whose recorded coverage is satisfied (Drive materialized, U1/U2 durable) was refused even though the finish omitted the intake fields"
echo "  ok (10b) an intake-mode record with satisfied coverage still closes honestly (coverage from the record, not the caller)"

echo "PASS: the IDC command lifecycle envelope holds — start upserts one obligation, Stop refuses an open command with the exact finish remediation, an unknown/malformed status cannot clear it, a schema-valid + command-specific closeout ends it, no foreign session can finish another's record, and the Task-6 matrix blocks a think closeout that drops exact-once intake units, an illegal per-command status, a zero-exit blocked_external, and a foreign-session autorun drain"
