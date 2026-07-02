#!/bin/bash
# Phase 3 (provenance-gate) smoke — scripts/idc_provenance_check.py is Plan's post-condition
# (design §B.4, T1a): a Buildable minted this run must carry a valid idc-provenance marker on its
# LIVE github body before Plan can report done. Converts enforcement-map row 14 from PROSE-ONLY to
# DET-VERIFY.
#
# Hermetic: a PATH `gh` stub serves `gh issue view <n> --json body -q .body` from fixture files —
# no live GitHub. Uses a real matrix.yaml parsed by the real idc_matrix_check.parse_matrix.
# Usage: bash tests/smoke/phase3-provenance-gate.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN/scripts/idc_provenance_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCRIPT" ] || fail "idc_provenance_check.py not found (not implemented yet)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --help parses
python3 "$SCRIPT" --help >/dev/null 2>&1 || fail "--help should parse"

# ---- fixture matrix (real matrix.yaml the check parses with the real idc_matrix_check) ---------
MATRIX="$WORK/phase1-matrix.yaml"
cat > "$MATRIX" <<'YAML'
phase: Phase 1
pillars:
  - id: P1
    wave: 1
    domain: api
    surfaces: [scripts/idc_provenance_check.py]
  - id: P2
    wave: 1
    domain: api
    surfaces: [scripts/idc_emit_marker.py]
YAML

# ---- fixture issue bodies -------------------------------------------------------------------
mkdir -p "$WORK/bodies"
# #10 — a Buildable WITH a valid provenance marker naming a real pillar in this matrix
cat > "$WORK/bodies/10" <<'EOF'
Some goal-contract prose.

<!-- idc-provenance: {"matrix":"phase1-matrix.yaml","pillar":"P1"} -->
EOF
# #11 — a Buildable with NO marker at all (Plan skipped the stamp — the RC this gate exists to catch)
cat > "$WORK/bodies/11" <<'EOF'
Some goal-contract prose, no marker.
EOF
# #12 — a marker naming a pillar id that is NOT in this matrix (stale / mistyped id)
cat > "$WORK/bodies/12" <<'EOF'
<!-- idc-provenance: {"matrix":"phase1-matrix.yaml","pillar":"P99"} -->
EOF

# ---- gh stub: `gh issue view <n> --json body -q .body` -> fixture file content ------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env python3
import sys
args = sys.argv[1:]
if args[:2] == ["issue", "view"]:
    n = args[2]
    try:
        sys.stdout.write(open("$WORK/bodies/" + n).read())
    except OSError:
        sys.stdout.write("")
    sys.exit(0)
sys.stderr.write("gh stub: unhandled " + repr(args) + "\\n")
sys.exit(99)
STUB
chmod +x "$WORK/bin/gh"

run() { ( PATH="$WORK/bin:$PATH" python3 "$SCRIPT" --matrix "$MATRIX" --repo "$WORK" "$@" ); }

# ---- case A: a Buildable WITH valid provenance -> exit 0 ---------------------------------------
out="$(run --issues 10 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "issue #10 has valid provenance — expected exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q '^provenance: ok 1$' || fail "expected 'provenance: ok 1', got: $out"

# ---- case B: a Buildable with NO marker -> exit 2, names #11 -----------------------------------
out="$(run --issues 11 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "issue #11 has no provenance marker — expected exit 2, got $rc: $out"
printf '%s\n' "$out" | grep -q '#11' || fail "missing-provenance report must name #11: $out"

# ---- case C: a marker naming a pillar NOT in this matrix -> exit 2 ------------------------------
out="$(run --issues 12 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "issue #12's pillar is not in the matrix — expected exit 2, got $rc: $out"
printf '%s\n' "$out" | grep -q '#12' || fail "missing-provenance report must name #12: $out"

# ---- case D: a mixed batch reports ONLY the offending issues, and a clean batch is exit 0 -------
out="$(run --issues 10,11 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "mixed batch (one bad) must exit 2, got $rc"
printf '%s\n' "$out" | grep -q '#11' || fail "mixed-batch report must name the offending #11"
printf '%s\n' "$out" | grep -q '#10' && fail "mixed-batch report must NOT name the clean #10"

out="$(run --issues 10 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "a clean batch must still exit 0 (got $rc): $out"

echo "PASS: idc_provenance_check.py Plan post-condition (with/without/mismatched provenance) green"
