#!/bin/bash
# idc-assert-class: mixed
# Phase 4 smoke — the dependency-aware ACCEPTANCE check (idc_acceptance_check.py): the wave-close
# gate that catches a merged-"Done" issue shipping INERT (autorun audit Defect 4 / Fix B). A Done
# issue carrying a structured deferral with blocks_goal:true whose enabling target isn't itself
# Done is an acceptance GAP that must auto-recirculate, not ship. The deferral is serialized onto
# the issue as a comment marker (`<!-- idc-deferral: {json} -->`) by the closeout — no dedicated
# tracker field, no 7th op; comment is one of the six core ops and both backends carry comments.
#   - a Done issue whose blocks_goal:true deferral points to a DISTINCT Done sibling  -> ok,  0
#   - a Done issue with an UNMET blocks_goal:true deferral (free-text/non-Done/self)   -> gap, 1 + issue#
#   - a blocks_goal:false deferral (a non-blocking note)                              -> ok,  0
#   - --wave N scopes the check to one wave
#   - a malformed tracker (no BEGIN/END state block)                                 -> exit 2
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
  {"number":365,"status":"Done","stage":"Buildable","title":"Provision Spanner instance","blocked_by":[],"wave":"Wave 4","comments":[]},
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance/db/IAM\",\"blocks_goal\":true,\"suggested_issue\":\"#365\"} -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/clean.md" >/dev/null \
  || fail "a Done issue whose blocks_goal:true deferral points to a Done sibling must be acceptance: ok"

# ---- gap: a Done issue with an UNMET blocks_goal:true deferral (free-text, no Done enabler) ---
emit "$WORK/gap.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance/db/IAM Terraform\",\"blocks_goal\":true,\"suggested_issue\":\"provision a Spanner instance\"} -->"]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/gap.md" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "an inert Done issue (unmet blocks_goal:true deferral) must exit 1 (got $rc): $out"
echo "$out" | grep -qi "acceptance: gap" || fail "an inert Done issue must print 'acceptance: gap' (got: $out)"
echo "$out" | grep -qE "(^| )449( |$)" || fail "the gap report must name the offending issue #449 (got: $out)"

# ---- gap: a blocks_goal:true deferral pointing to a NON-Done sibling --------------------------
emit "$WORK/gap-nondone.md" <<'JSON'
{"issues":[
  {"number":365,"status":"Todo","stage":"Buildable","title":"Provision Spanner instance","blocked_by":[],"wave":"Wave 4","comments":[]},
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance\",\"blocks_goal\":true,\"suggested_issue\":\"#365\"} -->"]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/gap-nondone.md" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "a Done issue whose enabling sibling (#365) is not Done must be a gap (exit 1, not $rc): $out"

# ---- gap: a self-referencing deferral (suggested_issue == its own #) is NOT resolved ----------
emit "$WORK/gap-selfref.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance\",\"blocks_goal\":true,\"suggested_issue\":\"#449\"} -->"]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/gap-selfref.md" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "a deferral naming its OWN issue must be a gap (self-reference loophole) (exit 1, not $rc): $out"

# ---- not a gap: a blocks_goal:FALSE deferral is a non-blocking note ---------------------------
emit "$WORK/nonblocking.md" <<'JSON'
{"issues":[
  {"number":500,"status":"Done","stage":"Buildable","title":"Feature","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"deferred\",\"what\":\"nice-to-have polish\",\"blocks_goal\":false,\"suggested_issue\":\"later\"} -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/nonblocking.md" >/dev/null \
  || fail "a blocks_goal:false deferral is a non-blocking note, not an acceptance gap"

# ---- --wave filter: selects the RIGHT wave (gap in 3, clean in 4) -----------------------------
# A two-wave fixture: the gap is in Wave 3, a clean Done issue is in Wave 4. This proves --wave
# selects the named wave (not a no-op, not always-include, not always-exclude).
emit "$WORK/twowave.md" <<'JSON'
{"issues":[
  {"number":300,"status":"Done","stage":"Buildable","title":"Wave-3 inert","blocked_by":[],"wave":"Wave 3",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"unmet dep\",\"blocks_goal\":true,\"suggested_issue\":\"do it later\"} -->"]},
  {"number":400,"status":"Done","stage":"Buildable","title":"Wave-4 clean","blocked_by":[],"wave":"Wave 4","comments":[]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/twowave.md" --wave 3 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "--wave 3 must catch the Wave-3 gap (got $rc): $out"
echo "$out" | grep -qE "(^| )300( |$)" || fail "--wave 3 must name #300 (got: $out)"
python3 "$SCRIPT" --tracker "$WORK/twowave.md" --wave 4 >/dev/null \
  || fail "--wave 4 must report ok (the only Wave-4 issue is clean)"

# ---- TRANSITIVE inertness: a --wave N close must catch a dependent whose enabler is itself inert
#      and OUT of wave N (else a wave-scoped check assumes an out-of-wave Done enabler is clean and
#      ships a transitively-inert increment — the cardinal silent-pass). #449 (Wave 4) -> #365, and
#      #365 (Wave 3) is Done but carries its OWN unmet blocks_goal:true deferral. Gut the transitive
#      check (status-only "met") and --wave 4 goes back to `ok` while shipping inert #449 -> red.
emit "$WORK/transitive.md" <<'JSON'
{"issues":[
  {"number":365,"status":"Done","stage":"Buildable","title":"Provision Spanner instance","blocked_by":[],"wave":"Wave 3",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"IAM still missing\",\"blocks_goal\":true,\"suggested_issue\":\"do it later\"} -->"]},
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance\",\"blocks_goal\":true,\"suggested_issue\":\"#365\"} -->"]}
]}
JSON
out="$(python3 "$SCRIPT" --tracker "$WORK/transitive.md" --wave 4 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "--wave 4 must catch #449 whose out-of-wave enabler #365 is itself inert (transitive) (exit 1, not $rc): $out"
echo "$out" | grep -qE "(^| )449( |$)" || fail "the transitive gap must name #449 (got: $out)"

# ---- a --wave value carrying NO wave number -> exit 2 (never a silent whole-board fallback) -----
python3 "$SCRIPT" --tracker "$WORK/twowave.md" --wave four >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a non-numeric --wave value (typo) must exit 2, not silently re-scope the whole board (got $rc)"

# ---- blocks_goal:null / missing -> exit 2 (fail-closed; the gate is the last-resort defense) ----
# The validator rejects a null/absent blocks_goal upstream, but the gate must not mis-read a null
# (or a manually-edited tracker) as "non-blocking" and silently pass. Loosen the gate's bool check
# back to `bg is not None and ...` and this goes green while a null deferral ships inert -> red.
emit "$WORK/nullbg.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {\"kind\":\"out-of-boundary\",\"what\":\"Spanner instance\",\"blocks_goal\":null,\"suggested_issue\":\"later\"} -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/nullbg.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a blocks_goal:null deferral must exit 2 (fail-closed), not be read as non-blocking (got $rc)"

# ---- unparseable deferral marker -> exit 2 (fail-closed, never silently skip a possible gap) --
emit "$WORK/badmarker.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: {not valid json} -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/badmarker.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "an unparseable idc-deferral marker must exit 2 (fail-closed), got $rc"

# ---- a deferral SENTINEL with no parseable {…} payload -> exit 2 (not silently "no deferral") --
# A `{…}`-anchored marker pattern would skip a corrupt sentinel (no braces) and the gate could then
# print `acceptance: ok` over an inert Done. The sentinel is matched first, so a non-object payload
# fails closed. Anchor the pattern back to `(\{.*?\})` and this goes green (silent pass) -> red.
emit "$WORK/sentinel-noobj.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: TRUNCATED-no-json-object -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/sentinel-noobj.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "an idc-deferral sentinel with no JSON-object payload must exit 2 (fail-closed), not be skipped as no-deferral (got $rc)"

# ---- a deferral marker whose payload is valid JSON but NOT an object -> exit 2 ----------------
emit "$WORK/marker-nonobj.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":["<!-- idc-deferral: [\"not\",\"an\",\"object\"] -->"]}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/marker-nonobj.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "an idc-deferral marker whose payload is valid JSON but not an object must exit 2 (got $rc)"

# ---- malformed tracker (no BEGIN/END state block) -> exit 2 ----------------------------------
echo "not a tracker" > "$WORK/malformed.md"
python3 "$SCRIPT" --tracker "$WORK/malformed.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a malformed tracker (no state block) must exit 2 (got $rc)"

# ---- a state block that is valid JSON but the WRONG SHAPE -> exit 2 (not exit 1 = a real gap) --
# A top-level array (or a non-list `issues`) used to raise an unhandled exception -> CLI exit 1,
# which the build wave-close reads as `acceptance: gap` and spuriously recirculates. It must fail
# closed as exit 2 (a tracker error), distinct from a real gap.
emit "$WORK/shape-array.md" <<'JSON'
["not","a","state","object"]
JSON
python3 "$SCRIPT" --tracker "$WORK/shape-array.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a state block that is a JSON array (wrong shape) must exit 2, never exit 1 (got $rc)"
emit "$WORK/shape-issues.md" <<'JSON'
{"issues":"not-a-list"}
JSON
python3 "$SCRIPT" --tracker "$WORK/shape-issues.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a state block whose \`issues\` is not a list must exit 2 (got $rc)"

# ---- a state block MISSING the `issues` key entirely -> exit 2 (not a silent empty board) ------
# A dropped `issues` key used to default to an empty board (state.get("issues", [])) -> a silent
# `acceptance: ok`. A missing key is corruption, not an empty board: fail closed (exit 2).
emit "$WORK/no-issues-key.md" <<'JSON'
{"next_number":1}
JSON
python3 "$SCRIPT" --tracker "$WORK/no-issues-key.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a state block missing the \`issues\` key must exit 2 (fail-closed), not read as an empty board (got $rc)"

# ---- an explicitly-present empty board (`issues: []`) stays a legitimate empty board -> ok ------
emit "$WORK/empty-board.md" <<'JSON'
{"issues":[]}
JSON
python3 "$SCRIPT" --tracker "$WORK/empty-board.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "an explicitly-present empty board (issues: []) must stay acceptance: ok exit 0 (got $rc)"

# ---- a `comments` value that is a STRING (not a list) -> exit 2 -------------------------------
# A string comments makes the marker loop iterate CHARACTERS, so an embedded blocks_goal:true marker
# is never matched and the inert Done prints `acceptance: ok` (silent pass). Drop the comments-list
# guard and this Done-with-unmet-deferral goes green -> red.
emit "$WORK/comments-string.md" <<'JSON'
{"issues":[
  {"number":449,"status":"Done","stage":"Buildable","title":"Two-store seed","blocked_by":[],"wave":"Wave 4",
   "comments":"<!-- idc-deferral: {\"kind\":\"x\",\"what\":\"y\",\"blocks_goal\":true,\"suggested_issue\":\"later\"} -->"}
]}
JSON
python3 "$SCRIPT" --tracker "$WORK/comments-string.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "a string (non-list) comments must exit 2 (fail-closed), not silently char-iterate past an inert Done (got $rc)"

# ---- wiring: idc-build.md Phase 4 runs the acceptance check as a BLOCKING, recirculating gate -
BUILD="$PLUGIN/agents/idc-build.md"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"
grep -qiE 'idc_acceptance_check\.py' "$BUILD" \
  || fail "idc-build.md Phase 4 must run the acceptance check (idc_acceptance_check.py) at wave-close (P1-1)"
grep -qiE 'acceptance: gap' "$BUILD" \
  || fail "idc-build.md must act on an 'acceptance: gap' (auto-recirculate, do not close green) (P1-1)"
grep -qiE 'Done-but-inert' "$BUILD" \
  || fail "idc-build.md wave-close must auto-file a recirculation for each Done-but-inert issue (P1-1)"
# github parity: the github path must be CONCRETE — materialize query+comments into the gate's
# state block and run the SAME script. Reverting to a vague "github-backend equivalent" drops the
# idc-tracker-state materialization → red.
grep -qiE 'idc-tracker-state' "$BUILD" \
  || fail "idc-build.md Phase 4 must make the github path concrete: materialize query+comments into the gate's idc-tracker-state block and run the same script (P1-1 github parity)"
grep -qiE 'whole board' "$BUILD" \
  || fail "idc-build.md Phase 4 github path must materialize the WHOLE board (not just wave N) so a cross-wave enabler is visible — else the gate false-gaps a valid deferral (Codex review)"

# ---- producer: the finisher lands each unresolved deferral as an idc-deferral comment marker --
FIN="$PLUGIN/agents/idc-finisher.md"
[ -f "$FIN" ] || fail "agents/idc-finisher.md missing"
grep -qiE 'idc-deferral' "$FIN" \
  || fail "idc-finisher.md must serialize deferrals as idc-deferral comment markers so the gate can read them (producer; else the gate is inert)"

# ---- P2-1: the inert/acceptance-gap recirculation trigger is named where work is filed --------
IMPL="$PLUGIN/agents/idc-implementer.md"; RECMD="$PLUGIN/commands/recirculate.md"
for f in "$IMPL" "$RECMD"; do [ -f "$f" ] || fail "missing $f"; done
grep -qiE 'inert/acceptance-gapped' "$FIN" \
  || fail "idc-finisher.md must add the inert/acceptance-gap recirculation trigger (P2-1)"
grep -qiE 'inert/acceptance-gapped' "$IMPL" \
  || fail "idc-implementer.md must add the inert/acceptance-gap recirculation trigger (P2-1)"
grep -qiE 'acceptance-gap' "$RECMD" \
  || fail "commands/recirculate.md must accept an acceptance-gap as a recirculation input (P2-1)"

# ---- P3: phase-close is BLOCKING for acceptance-class findings (others stay non-blocking) -----
grep -qiE 'acceptance-class findings are blocking' "$BUILD" \
  || fail "idc-build.md Phase 5 must make acceptance-class findings BLOCKING at phase close (P3)"
grep -qiE 'every wave-close' "$BUILD" \
  || fail "idc-build.md must run the acceptance check at every wave-close, not only at phase boundary (P3, mid-phase pause)"
grep -qiE 'unscoped' "$BUILD" \
  || fail "idc-build.md Phase 5 must also run the acceptance check UNSCOPED (whole board) as a backstop for a waveless/post-close inert Done (P3 backstop)"

echo "PASS: acceptance gate (deferral comment markers) catches inert-Done; wave-scoped; bad marker/malformed->exit2; build wired; finisher produces; recirc trigger; phase-5 blocks acceptance-class"
