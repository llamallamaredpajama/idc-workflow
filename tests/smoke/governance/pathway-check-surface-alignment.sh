#!/bin/bash
# idc-assert-class: behavior
# pathway-check-surface-alignment.sh — F61: the deterministic checker guards every surface the
# ruleset declares, and the alignment claim is enforced instead of merely asserted in a docstring.
#
# THE DEFECT THIS LANE LOCKS. `idc_pathway_check.PROTECTED_SURFACES` carried a comment saying "Keep
# these aligned with the ruleset's `idc_contract.protected_surfaces`". They were not aligned: the
# ruleset declared seven surfaces and the tuple guarded five, omitting `.github/rulesets/**` and
# `.github/CODEOWNERS`. A tree with CODEOWNERS and the entire rulesets directory deleted still
# printed PASS from the required check. Nothing anywhere reded on the divergence — the only two
# references to PROTECTED_SURFACES were its definition and its single use — so the comment was a
# claim with no enforcement behind it. This lane is the enforcement.
#
# What it proves:
#   A. every ruleset-declared surface is COVERED by at least one checker entry (glob roots like
#      `.github/workflows/**` are satisfied by a concrete entry at or under that root);
#   B. the checker has no entry outside the declared contract (no silent private surface);
#   C. behaviorally: deleting `.github/CODEOWNERS`, or emptying `.github/rulesets/`, now REFUSES —
#      the exact tree that used to pass.
#
# Red-when-broken: drop either new surface from PROTECTED_SURFACES and A + C fail; add a surface to
# the ruleset without teaching the checker and A fails; add a checker entry the ruleset never
# declared and B fails.
#
# Usage: bash tests/smoke/governance/pathway-check-surface-alignment.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$PLUGIN/scripts/idc_pathway_check.py"
RULESET="$PLUGIN/.github/rulesets/idc-pathway-integrity.json"
WF="$PLUGIN/.github/workflows/idc-pathway-integrity.yml"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$CHECK" ] || fail "deterministic checker not found at $CHECK"
[ -f "$RULESET" ] || fail "shipped ruleset not found at $RULESET"
[ -f "$WF" ] || fail "pathway workflow not found at $WF"

# --- A + B. the two lists agree, checked against the SHIPPED artifacts -----------------------------
timeout 60 python3 - "$PLUGIN/scripts" "$RULESET" <<'PY' || exit 1
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_pathway_check as PC

declared = json.load(open(sys.argv[2], encoding="utf-8"))["idc_contract"]["protected_surfaces"]
guarded = list(PC.PROTECTED_SURFACES)

def root_of(entry):
    """A ruleset entry reduced to the path prefix it protects (`a/b/**` -> `a/b`)."""
    return entry[:-3] if entry.endswith("/**") else entry

def covers(guard, prefix):
    return guard == prefix or guard.startswith(prefix + "/")

missing = [d for d in declared if not any(covers(g, root_of(d)) for g in guarded)]
if missing:
    raise SystemExit(
        "FAIL: the ruleset declares protected surface(s) the deterministic checker does not guard: "
        f"{missing}. PROTECTED_SURFACES = {guarded}. Either guard them or stop claiming alignment.")

extra = [g for g in guarded if not any(covers(g, root_of(d)) for d in declared)]
if extra:
    raise SystemExit(
        f"FAIL: the checker guards surface(s) the ruleset never declares: {extra}. The two lists are "
        "one contract; add them to idc_contract.protected_surfaces or drop them from the checker.")

print(f"ok: {len(declared)} declared surfaces all covered by {len(guarded)} checker entries, none extra")
PY

# --- C. behavioral: the exact tree that used to pass now refuses -----------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/.github/workflows" "$REPO/.github/rulesets" "$REPO/scripts/hooks"
cp "$WF" "$REPO/.github/workflows/idc-pathway-integrity.yml"
cp "$CHECK" "$REPO/scripts/idc_pathway_check.py"
printf '# ownership checker surface\n' > "$REPO/scripts/idc_ruleset_check.py"
printf '# validation surface\n' > "$REPO/scripts/idc_validation_contract.py"
printf '# receipt surface\n'    > "$REPO/scripts/idc_receipt_check.py"
printf '# hook surface\n'       > "$REPO/scripts/hooks/idc_ledger.py"
cp "$RULESET" "$REPO/.github/rulesets/idc-pathway-integrity.json"
printf '* @owner\n'             > "$REPO/.github/CODEOWNERS"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm seed
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
SOURCE="$(timeout 60 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import idc_pathway_check as PC; print(PC.EXPECTED_CHECK_SOURCE)' "$PLUGIN/scripts")"

run_check() { timeout 60 python3 "$CHECK" --repo "$REPO" --head "$HEAD_SHA" --source "$SOURCE"; }

run_check >/dev/null 2>"$WORK/intact.err" \
  || fail "the checker refused an intact tree carrying all declared surfaces: $(cat "$WORK/intact.err")"

mv "$REPO/.github/CODEOWNERS" "$WORK/CODEOWNERS.bak"
run_check >"$WORK/no-co.out" 2>&1 \
  && fail "the required check PASSED on a tree with .github/CODEOWNERS deleted — a declared protected surface: $(cat "$WORK/no-co.out")"
grep -qi 'CODEOWNERS' "$WORK/no-co.out" \
  || fail "the refusal does not name the missing CODEOWNERS surface: $(cat "$WORK/no-co.out")"
mv "$WORK/CODEOWNERS.bak" "$REPO/.github/CODEOWNERS"

rm -rf "$REPO/.github/rulesets"
run_check >"$WORK/no-rs.out" 2>&1 \
  && fail "the required check PASSED on a tree with the whole .github/rulesets/ directory deleted: $(cat "$WORK/no-rs.out")"
grep -qi 'ruleset' "$WORK/no-rs.out" \
  || fail "the refusal does not name the missing rulesets surface: $(cat "$WORK/no-rs.out")"

# An emptied directory is a hollow surface too, not just a deleted one.
mkdir -p "$REPO/.github/rulesets"
run_check >"$WORK/empty-rs.out" 2>&1 \
  && fail "the required check PASSED on an EMPTIED .github/rulesets/ directory: $(cat "$WORK/empty-rs.out")"

cp "$RULESET" "$REPO/.github/rulesets/idc-pathway-integrity.json"
run_check >/dev/null 2>"$WORK/restored.err" \
  || fail "the checker still refuses after both surfaces were restored: $(cat "$WORK/restored.err")"

echo "PASS: the deterministic checker guards every surface the ruleset declares (and none it does not), and a tree missing CODEOWNERS or the rulesets directory is refused instead of passing"
