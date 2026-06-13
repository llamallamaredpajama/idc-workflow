#!/bin/bash
# Phase 8 smoke — the governance compiler that long-lived pi residents consume instead of
# re-reading WORKFLOW.md prose. REAL round-trip of the two helpers in a throwaway governed-repo
# sandbox (no live GitHub):
#   * scripts/idc_governance_compile.py emits a compact, hash-pinned YAML sidecar of
#     WORKFLOW.md + WORKFLOW-config.yaml + tracker-config.yaml — BYTE-STABLE across repeated runs
#     on unchanged inputs (the determinism guarantee pi residents rely on).
#   * scripts/idc_governance_check.py returns 0 on a matching sidecar but NON-ZERO after a source
#     is mutated (drift) or the sidecar is missing — fail-closed, so a stale resident reloads
#     rather than trusting prose it can no longer prove.
# Episodic Claude/Codex runs are unaffected — they keep reading WORKFLOW.md directly.
# Failing-test-first: fails until the two scripts exist.
#
# Usage: bash tests/smoke/phase8-governance.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
COMPILE="$PLUGIN/scripts/idc_governance_compile.py"
CHECK="$PLUGIN/scripts/idc_governance_check.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$COMPILE" ] || fail "compiler not found at $COMPILE (not implemented yet)"
[ -f "$CHECK" ]   || fail "checker not found at $CHECK (not implemented yet)"

# --- a governed-repo sandbox: the three source files with concrete values --------------------
# (mirrors templates/ after /idc:init substitutes the tokens; WORKFLOW-config.yaml at root,
# tracker-config.yaml under docs/workflow/.)
mkdir -p "$SBX/docs/workflow"
cat > "$SBX/WORKFLOW.md" <<'EOF'
# WORKFLOW.md — Demo IDC governance contract
## 1. Canonical chain & flow
Think -> Plan -> Build, with Ripple as the only retrograde path.
## 1.2 One-way flow + the glass wall
Planning reaches Build only through tracker issues; Build reaches planning only through Ripple.
EOF
cat > "$SBX/WORKFLOW-config.yaml" <<'EOF'
workflow:
  schema: idc
  version: 2
project:
  name: demo-app
EOF
cat > "$SBX/docs/workflow/tracker-config.yaml" <<'EOF'
backend: github
project_number: 7
field_ids:
  Status: "PVTSSF_aaa"
  Wave: "PVTSSF_bbb"
  Phase: "PVTSSF_ccc"
  Domain: "PVTSSF_ddd"
EOF

SIDE1="$SBX/side1.yaml"
SIDE2="$SBX/side2.yaml"

# --- determinism: two compiles on unchanged inputs are BYTE-identical ------------------------
python3 "$COMPILE" --repo "$SBX" --out "$SIDE1" || fail "compile #1 exited non-zero"
python3 "$COMPILE" --repo "$SBX" --out "$SIDE2" || fail "compile #2 exited non-zero"
cmp -s "$SIDE1" "$SIDE2" || fail "sidecar is NOT byte-stable across runs on unchanged inputs"

# --- sidecar shape: hash-pinned sources + tracker/glass-wall summary --------------------------
grep -Eq '^schema_version:[[:space:]]*1$'                       "$SIDE1" || fail "schema_version not 1"
grep -q  'source_hashes:'                                       "$SIDE1" || fail "no source_hashes block"
grep -Eq 'WORKFLOW.md:[[:space:]]*[0-9a-f]{64}$'                "$SIDE1" || fail "WORKFLOW.md hash not 64 lowercase hex"
grep -Eq 'WORKFLOW-config.yaml:[[:space:]]*[0-9a-f]{64}$'       "$SIDE1" || fail "WORKFLOW-config.yaml hash missing"
grep -Eq 'tracker-config.yaml:[[:space:]]*[0-9a-f]{64}$'        "$SIDE1" || fail "tracker-config.yaml hash missing"
grep -q  'glass_wall:'                                          "$SIDE1" || fail "no glass_wall summary"
grep -q  'planning_to_build: github_issues_only'               "$SIDE1" || fail "glass-wall planning->build not summarized"
grep -q  'build_to_planning: ripple_only'                      "$SIDE1" || fail "glass-wall build->planning not summarized"
grep -q  'backend: github'                                      "$SIDE1" || fail "tracker backend not summarized"

# --- default emit path lands at docs/workflow/idc-governance-contract.yaml --------------------
python3 "$COMPILE" --repo "$SBX" || fail "compile (default out) exited non-zero"
DEFAULT="$SBX/docs/workflow/idc-governance-contract.yaml"
[ -f "$DEFAULT" ] || fail "default sidecar not written to docs/workflow/idc-governance-contract.yaml"

# --- check: a matching sidecar returns 0 -----------------------------------------------------
python3 "$CHECK" --repo "$SBX" || fail "check must return 0 on a matching sidecar"

# --- drift: mutate WORKFLOW.md -> check returns NON-ZERO (fail-closed reload signal) ----------
printf '\nsneaky operator edit\n' >> "$SBX/WORKFLOW.md"
python3 "$CHECK" --repo "$SBX" >/dev/null 2>&1 && fail "check must return non-zero after WORKFLOW.md drift"

# --- completeness (codex round-6): an INCOMPLETE sidecar (a governing source omitted) is REJECTED
#     even if the remaining hashes match — so a hand-edited sidecar can't pass the gate while
#     skipping one file's drift check. (Recompile first; WORKFLOW.md was drifted above.)
python3 "$COMPILE" --repo "$SBX" || fail "recompile (for completeness test) failed"
INCOMPLETE="$SBX/incomplete.yaml"
grep -vE '^[[:space:]]*docs/workflow/tracker-config\.yaml:[[:space:]]*[0-9a-f]{64}' "$DEFAULT" > "$INCOMPLETE"
python3 "$CHECK" --repo "$SBX" --sidecar "$INCOMPLETE" >/dev/null 2>&1 \
  && fail "check must reject an incomplete sidecar (a governing source omitted)"

# --- fail-closed: a missing sidecar -> NON-ZERO (never silently treats sources as current) ----
rm -f "$DEFAULT"
python3 "$CHECK" --repo "$SBX" >/dev/null 2>&1 && fail "check must fail-closed on a missing sidecar"

echo "PASS: governance compiler byte-stable; drift, incompleteness, and a missing sidecar all fail-closed"
