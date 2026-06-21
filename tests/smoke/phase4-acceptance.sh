#!/bin/bash
# Phase 4 smoke — the dependency-aware ACCEPTANCE check (idc_acceptance_check.py): the wave-close
# gate that catches a merged-"Done" issue shipping INERT (autorun audit Defect 4 / Fix B). A Done
# issue carrying a structured deferral with blocks_goal:true whose enabling target isn't itself
# Done is an acceptance GAP that must auto-recirculate, not ship.
#   - a Done issue whose blocks_goal:true deferral points to a Done sibling   -> acceptance: ok,  0
#   - a Done issue with an UNMET blocks_goal:true deferral (free-text/non-Done)-> acceptance: gap, 1 + issue#
#   - a blocks_goal:false deferral (a non-blocking note)                       -> acceptance: ok,  0
#   - --wave N scopes the check to one wave
#   - a malformed tracker (no BEGIN/END state block)                          -> exit 2
# Failing-test-first: fails until scripts/idc_acceptance_check.py exists.
#
# Usage: bash tests/smoke/phase4-acceptance.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN/scripts/idc_acceptance_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
# emit a TRACKER.md whose BEGIN/END state block wraps the JSON read from stdin
emit() { # $1 = path ; JSON on stdin
  { echo "<!-- idc-tracker-state:begin -->"; echo '```json'; cat; echo '```'
    echo "<!-- idc-tracker-state:end -->"; } > "$1"
}

[ -f "$SCRIPT" ] || fail "acceptance check not found at $SCRIPT (not implemented yet)"

# ---- clean: a Done issue whose blocks_goal:true deferral was resolved by a Done sibling -------
emit "$WORK/clean.md" <<'JSON'
{"issues":[
  {"number":365,"status":"Done","stage":"Buildable","title":"Provision Spanner instance","blocked_by":[],"wave":"Wave 4","deferrals":[]},
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "deferrals":[{"kind":"out-of-boundary","what":"Spanner instance/db/IAM","blocks_goal":true,"suggested_issue":"#365"}]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/clean.md" >/dev/null \
  || fail "a Done issue whose blocks_goal:true deferral points to a Done sibling must be acceptance: ok"

# ---- gap: a Done issue with an UNMET blocks_goal:true deferral (free-text, no Done enabler) ---
emit "$WORK/gap.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "deferrals":[{"kind":"out-of-boundary","what":"Spanner instance/db/IAM Terraform","blocks_goal":true,"suggested_issue":"provision a Spanner instance"}]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/gap.md" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "an inert Done issue (unmet blocks_goal:true deferral) must exit 1 (got $rc): $out"
echo "$out" | grep -qi "acceptance: gap" || fail "an inert Done issue must print 'acceptance: gap' (got: $out)"
echo "$out" | grep -qE "(^| )449( |$)" || fail "the gap report must name the offending issue #449 (got: $out)"

# ---- gap: a blocks_goal:true deferral pointing to a NON-Done sibling --------------------------
emit "$WORK/gap-nondone.md" <<'JSON'
{"issues":[
  {"number":365,"status":"Todo","stage":"Buildable","title":"Provision Spanner instance","blocked_by":[],"wave":"Wave 4","deferrals":[]},
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "deferrals":[{"kind":"out-of-boundary","what":"Spanner instance","blocks_goal":true,"suggested_issue":"#365"}]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/gap-nondone.md" >/dev/null 2>&1 \
  && fail "a Done issue whose enabling sibling (#365) is not Done must be a gap (exit 1)"

# ---- not a gap: a blocks_goal:FALSE deferral is a non-blocking note ---------------------------
emit "$WORK/nonblocking.md" <<'JSON'
{"issues":[
  {"number":500,"status":"Done","stage":"Buildable","title":"Feature","blocked_by":[],"wave":"Wave 4",
   "deferrals":[{"kind":"deferred","what":"nice-to-have polish","blocks_goal":false,"suggested_issue":"later"}]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/nonblocking.md" >/dev/null \
  || fail "a blocks_goal:false deferral is a non-blocking note, not an acceptance gap"

# ---- --wave filter: a Wave-4 gap is out of scope for --wave 3, in scope for --wave 4 ----------
python3 "$SCRIPT" --tracker "$WORK/gap.md" --wave 3 >/dev/null \
  || fail "--wave 3 must scope out a gap that lives in Wave 4 (acceptance: ok for wave 3)"
python3 "$SCRIPT" --tracker "$WORK/gap.md" --wave 4 >/dev/null 2>&1 \
  && fail "--wave 4 must still catch the Wave 4 gap (exit 1)"

# ---- malformed tracker (no BEGIN/END state block) -> exit 2 ----------------------------------
echo "not a tracker" > "$WORK/malformed.md"
python3 "$SCRIPT" --tracker "$WORK/malformed.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a malformed tracker (no state block) must exit 2 (got $rc)"

# ---- wiring: idc-build.md Phase 4 runs the acceptance check as a BLOCKING, recirculating gate -
BUILD="$PLUGIN/agents/idc-build.md"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"
grep -qiE 'idc_acceptance_check\.py' "$BUILD" \
  || fail "idc-build.md Phase 4 must run the acceptance check (idc_acceptance_check.py) at wave-close (P1-1)"
grep -qiE 'acceptance: gap' "$BUILD" \
  || fail "idc-build.md must act on an 'acceptance: gap' (auto-recirculate, do not close green) (P1-1)"
grep -qiE 'Done-but-inert' "$BUILD" \
  || fail "idc-build.md wave-close must auto-file a recirculation for each Done-but-inert issue (P1-1)"

# ---- P2-1: the inert/acceptance-gap recirculation trigger is named where work is filed --------
FIN="$PLUGIN/agents/idc-finisher.md"; IMPL="$PLUGIN/agents/idc-implementer.md"; RECMD="$PLUGIN/commands/recirculate.md"
for f in "$FIN" "$IMPL" "$RECMD"; do [ -f "$f" ] || fail "missing $f"; done
grep -qiE 'inert/acceptance-gapped' "$FIN" \
  || fail "idc-finisher.md must add the inert/acceptance-gap recirculation trigger (P2-1)"
grep -qiE 'inert/acceptance-gapped' "$IMPL" \
  || fail "idc-implementer.md must add the inert/acceptance-gap recirculation trigger (P2-1)"
grep -qiE 'acceptance-gap' "$RECMD" \
  || fail "commands/recirculate.md must accept an acceptance-gap as a recirculation input (P2-1)"

echo "PASS: acceptance check gates inert-Done (unmet blocks_goal deferral); wave-scoped; malformed->exit2; build Phase 4 wired; recirc trigger broadened"
