#!/bin/bash
# Phase 4 (marker-emit) smoke — scripts/idc_emit_marker.py serializes the idc-discovery /
# idc-deferral HTML-comment JSON markers the implementer/finisher hand-write today (design §B.5,
# T1b), so a malformed hand-typed marker can no longer silently drop out of the recirculation net.
#
# Round-trips the emitted markers through the REAL consumer regexes:
#   - idc-discovery -> idc_recirc_sweep.DISCOVERY_MARKER / parse_markers (the sweep's own parser)
#   - idc-deferral   -> idc_acceptance_check.DEFERRAL_MARKER (the wave-close acceptance gate's parser)
# so drift between the emitter and either consumer turns this test red, not just a paraphrase.
#
# Hermetic: no GitHub, no tracker — a pure serializer, exercised directly.
# Usage: bash tests/smoke/phase4-marker-emit.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN/scripts/idc_emit_marker.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCRIPT" ] || fail "idc_emit_marker.py not found (not implemented yet)"

# ---- --help parses for both marker kinds -------------------------------------------------------
python3 "$SCRIPT" --help >/dev/null 2>&1 || fail "--help should parse"

# ---- discovery: well-formed marker, round-tripped through the sweep's own parser ---------------
DISC="$(python3 "$SCRIPT" discovery --what 'tighten retry backoff' --area 'scripts/idc_gh_board.py' \
          --suggested-scope 'add jittered backoff on 5xx' --origin '#501')" \
  || fail "discovery emit failed"
printf '%s\n' "$DISC" | grep -qE '^<!-- idc-discovery: \{.*\} -->$' \
  || fail "discovery marker is not well-shaped HTML-comment JSON: $DISC"

python3 - "$PLUGIN" "$DISC" <<'PY' || fail "discovery marker did not round-trip through idc_recirc_sweep's own parser"
import sys, os
plugin, text = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_recirc_sweep as s
found = s.parse_markers(text, s.DISCOVERY_MARKER)
assert len(found) == 1, f"expected exactly 1 discovery marker, got {found}"
obj = found[0]
assert obj == {
    "what": "tighten retry backoff",
    "area": "scripts/idc_gh_board.py",
    "suggested_scope": "add jittered backoff on 5xx",
    "origin": "#501",
}, f"round-tripped object mismatch: {obj}"
PY

# ---- deferral: well-formed marker, round-tripped through the acceptance gate's own parser -------
DEFR="$(python3 "$SCRIPT" deferral --kind out-of-boundary --what 'Spanner instance/db/IAM' \
          --blocks-goal true --suggested-issue '#365')" \
  || fail "deferral emit failed"
printf '%s\n' "$DEFR" | grep -qE '^<!-- idc-deferral: \{.*\} -->$' \
  || fail "deferral marker is not well-shaped HTML-comment JSON: $DEFR"

python3 - "$PLUGIN" "$DEFR" <<'PY' || fail "deferral marker did not round-trip through idc_acceptance_check's own parser"
import sys, os, json
plugin, text = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(plugin, "scripts"))
import idc_acceptance_check as a
m = a.DEFERRAL_MARKER.search(text)
assert m, f"idc_acceptance_check.DEFERRAL_MARKER did not match: {text}"
obj = json.loads(m.group(1))
assert obj == {
    "kind": "out-of-boundary", "what": "Spanner instance/db/IAM",
    "blocks_goal": True, "suggested_issue": "#365",
}, f"round-tripped object mismatch: {obj}"
assert obj["blocks_goal"] is True, "blocks_goal must be a real JSON boolean, not a string"
PY

# ---- deferral: --blocks-goal false serializes as a real JSON boolean, not the string "false" ----
DEFR2="$(python3 "$SCRIPT" deferral --kind deferred --what 'nice-to-have polish' \
           --blocks-goal false --suggested-issue 'later')" || fail "deferral(false) emit failed"
printf '%s\n' "$DEFR2" | grep -q '"blocks_goal":false' \
  || fail "blocks_goal=false must serialize as the JSON literal false: $DEFR2"
printf '%s\n' "$DEFR2" | grep -q '"blocks_goal":"false"' \
  && fail "blocks_goal must never serialize as the STRING \"false\" (the acceptance gate requires a real JSON boolean)"

# ---- fail-closed: a blank required field is refused (exit 2), never emits a corrupt marker ------
if python3 "$SCRIPT" discovery --what '' --area a --suggested-scope s --origin o >/tmp/idc-marker-emit-blank.$$ 2>&1; then
  fail "a blank --what must be refused (exit 2), not silently emit a corrupt marker"
fi
rm -f /tmp/idc-marker-emit-blank.$$

if python3 "$SCRIPT" deferral --kind deferred --what w --blocks-goal maybe --suggested-issue x >/dev/null 2>&1; then
  fail "--blocks-goal must be 'true'/'false' only — 'maybe' must be refused (exit 2)"
fi

echo "PASS: idc_emit_marker.py discovery/deferral serialization + round-trip through the real consumer parsers green"
