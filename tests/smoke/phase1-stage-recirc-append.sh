#!/bin/bash
# idc-assert-class: behavior
# Phase 1 smoke — non-destructive `Recirculation` Stage-option append (github board migration).
#
# 3.1.0 added `Stage = Recirculation` to the schema/skills/WORKFLOW/recirculate, but the board
# PROVISIONING was never updated: /idc:init created Stage with only 3 options and /idc:update's
# drift contract listed only 3 — so on a real board /idc:recirculate had no stage to file into,
# and doctor 9c's "run /idc:init" remediation was a dead loop. The fix makes init append the 4th
# option to an EXISTING Stage field, NON-DESTRUCTIVELY (existing options keep their node ids, so
# item values survive — verified against the live GitHub API). The risky part is assembling that
# `updateProjectV2Field` mutation correctly; this test pins it hermetically (no gh, no network).
#
# Red-when-broken: fails if the helper is absent, drops/re-IDs an existing option, forgets the new
# option, quotes the color enum, or isn't idempotent. Mirrors the live recipe init.md runs.
#
# Usage: bash tests/smoke/phase1-stage-recirc-append.sh   (exit 0 = pass)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
H="$HERE/scripts/idc_stage_options.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$H" ] || fail "stage-options helper not found at scripts/idc_stage_options.py (the append recipe must be a tested helper, not unreachable inline GraphQL)"

# A pre-3.1.0 board's Stage field: 3 options, each with a stable node id + color (shape returned by
# `gh api graphql … field(name:"Stage"){ id options { id name color description } }`).
cat > "$WORK/field3.json" <<'JSON'
{"id":"PVTSSF_OLD","options":[
  {"id":"aaa111","name":"Consideration","color":"GRAY","description":""},
  {"id":"bbb222","name":"Planning","color":"BLUE","description":""},
  {"id":"ccc333","name":"Buildable","color":"GREEN","description":""}
]}
JSON

# ---- (1) append on a 3-option field: emits a mutation, exit 0 (field id read FROM the JSON) -------
MUT="$(python3 "$H" append --ensure-option Recirculation --options-json "$WORK/field3.json")" \
  || fail "append on a 3-option Stage field must exit 0 and emit a mutation"

echo "$MUT" | grep -q 'updateProjectV2Field' \
  || fail "emitted mutation must call updateProjectV2Field"
echo "$MUT" | grep -q 'fieldId: *"PVTSSF_OLD"' \
  || fail "emitted mutation must target the field id read from the input JSON"

# Every EXISTING option must be re-sent WITH its node id (that is what preserves item values —
# omitting the id is the destructive re-ID the skill warns about).
for oid in aaa111 bbb222 ccc333; do
  echo "$MUT" | grep -q "id: *\"$oid\"" || fail "existing option id $oid must be preserved (re-sent) in the mutation"
done
for nm in Consideration Planning Buildable; do
  echo "$MUT" | grep -q "name: *\"$nm\"" || fail "existing option '$nm' must be preserved by name"
done
# Colors are a GraphQL ENUM — must be UNQUOTED, and the EXISTING colors preserved (not reset to GRAY).
echo "$MUT" | grep -qE 'color: *BLUE'  || fail "existing option color BLUE must be preserved, unquoted (enum)"
echo "$MUT" | grep -qE 'color: *GREEN' || fail "existing option color GREEN must be preserved, unquoted (enum)"
echo "$MUT" | grep -qE 'color: *"[A-Z]' && fail "color is a GraphQL enum and must NOT be quoted"

# The NEW option: present by name, and with NO id (a sent id would mean 'update existing', not 'create').
echo "$MUT" | grep -q 'name: *"Recirculation"' || fail "the new Recirculation option must be appended"
NIDS="$(echo "$MUT" | grep -oE 'id: *"[^"]+"' | wc -l | tr -d ' ')"
[ "$NIDS" = "3" ] || fail "exactly the 3 EXISTING options carry an id (the new Recirculation must have none); got $NIDS id fields"

# ---- (1b) --field-id overrides the JSON's id when explicitly given -------------------------------
MUT_OV="$(python3 "$H" append --field-id PVTSSF_OVERRIDE --ensure-option Recirculation --options-json "$WORK/field3.json")"
echo "$MUT_OV" | grep -q 'fieldId: *"PVTSSF_OVERRIDE"' || fail "--field-id must override the JSON id when given"

# ---- (2) idempotent: a field that ALREADY has Recirculation is a no-op (exit 3, no mutation) ------
cat > "$WORK/field4.json" <<'JSON'
{"id":"PVTSSF_NEW","options":[
  {"id":"aaa111","name":"Consideration","color":"GRAY","description":""},
  {"id":"bbb222","name":"Planning","color":"BLUE","description":""},
  {"id":"ccc333","name":"Buildable","color":"GREEN","description":""},
  {"id":"ddd444","name":"Recirculation","color":"GRAY","description":""}
]}
JSON
OUT4="$(python3 "$H" append --ensure-option Recirculation --options-json "$WORK/field4.json")"; rc4=$?
[ "$rc4" = "3" ] || fail "an already-present option must be a no-op signalled by exit 3 (got exit $rc4)"
[ -z "$OUT4" ] || fail "no-op must emit no mutation on stdout (would create a duplicate option)"

# ---- (3) fail-closed: malformed/empty input must error (exit 2), never emit a half-built mutation -
echo 'not json' > "$WORK/bad.json"
python3 "$H" append --ensure-option Recirculation --options-json "$WORK/bad.json" >/dev/null 2>&1
[ $? = 2 ] || fail "malformed field JSON must fail closed with exit 2"
# a field object with NO id and no --field-id override → fail closed (never mutate with a blank id)
cat > "$WORK/field_noid.json" <<'JSON'
{"options":[{"id":"aaa111","name":"Consideration","color":"GRAY","description":""}]}
JSON
python3 "$H" append --ensure-option Recirculation --options-json "$WORK/field_noid.json" >/dev/null 2>&1
[ $? = 2 ] || fail "missing field id (no JSON id, no --field-id) must fail closed with exit 2"

echo "PASS: Recirculation Stage-option append is non-destructive, idempotent, and fail-closed"
