#!/bin/bash
# idc-assert-class: behavior
# ruleset-checker-local.sh — U8 ruleset checker/installer contract (HERMETIC, no network).
#
# Proves `scripts/idc_ruleset_check.py` validates `.github/rulesets/idc-pathway-integrity.json`
# against the protected acceptance boundary (spec §2.3):
#   * required PR flow (a `pull_request` rule);
#   * required `idc/pathway-integrity` check bound at the EXACT head (strict status-check policy);
#   * force-push prevention (`non_fast_forward`) + branch-deletion prevention (`deletion`);
#   * protected IDC surfaces — workflow / hook / validation / receipt paths;
#   * FAIL on any missing or weakened entry.
# And proves `scripts/idc_ruleset_install.py` refuses to act without an explicit `--repo` and refuses
# to mutate a known production repo — the safety guards that keep a real board untouched.
#
# Red-when-broken: each `refute` mutates one contract entry and the checker MUST reject it.
# Failing-test-first: fails until the checker + installer + ruleset exist.
#
# Usage: bash tests/smoke/governance/ruleset-checker-local.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CHK="$PLUGIN/scripts/idc_ruleset_check.py"
INS="$PLUGIN/scripts/idc_ruleset_install.py"
RS="$PLUGIN/.github/rulesets/idc-pathway-integrity.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# --- existence (the honest RED reason: nothing implemented yet) --------------------------------
[ -f "$CHK" ] || fail "ruleset checker not implemented yet: scripts/idc_ruleset_check.py"
[ -f "$INS" ] || fail "ruleset installer not implemented yet: scripts/idc_ruleset_install.py"
[ -f "$RS" ]  || fail "pathway ruleset not present yet: .github/rulesets/idc-pathway-integrity.json"

# --- the shipped ruleset satisfies the full contract -------------------------------------------
python3 "$CHK" --ruleset "$RS" >/dev/null \
  || fail "the shipped ruleset was rejected by its own checker"

# --- refute(): apply one weakening mutation and require the checker to REJECT it -----------------
# $1 = label ; $2 = a python expression body that mutates the parsed dict `d`.
n=0
refute() {
  local label="$1" body="$2"
  n=$((n + 1))
  local mut="$WORK/mut-$n.json"
  python3 - "$RS" "$mut" "$body" <<'PY' || fail "refute setup failed for: $label"
import json, sys
d = json.load(open(sys.argv[1]))
rules = d["github_ruleset"]["rules"]
contract = d["idc_contract"]
def rule(t):
    return next((r for r in rules if r.get("type") == t), None)
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PY
  python3 "$CHK" --ruleset "$mut" >/dev/null 2>&1 \
    && fail "checker ADMITTED a weakened ruleset: $label"
}

refute "no pull_request rule (PRs not required)" \
  'd["github_ruleset"]["rules"] = [r for r in rules if r.get("type") != "pull_request"]'
refute "required check renamed away from idc/pathway-integrity" \
  'rule("required_status_checks")["parameters"]["required_status_checks"] = [{"context": "some/other-check"}]'
refute "strict status-check policy disabled (no longer exact head)" \
  'rule("required_status_checks")["parameters"]["strict_required_status_checks_policy"] = False'
refute "force-push prevention removed (non_fast_forward)" \
  'd["github_ruleset"]["rules"] = [r for r in rules if r.get("type") != "non_fast_forward"]'
refute "branch-deletion prevention removed (deletion)" \
  'd["github_ruleset"]["rules"] = [r for r in rules if r.get("type") != "deletion"]'
refute "exact_head contract flag cleared" \
  'contract["exact_head"] = False'
refute "protected WORKFLOW surface removed" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if ".github/workflows" not in s]'
refute "protected HOOK surface removed" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if "scripts/hooks" not in s]'
refute "protected VALIDATION surface removed" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if "valid" not in s]'
refute "protected RECEIPT surface removed" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if "receipt" not in s]'

# --- installer safety guards (no network is reached before these refusals) ----------------------
# No --repo -> refuse (never guesses the target board).
python3 "$INS" --ruleset "$RS" >/dev/null 2>&1 \
  && fail "installer acted with NO --repo target (must refuse without an explicit repo)"
# Explicit sandbox repo, default (dry-run) mode -> prints a plan, exits 0, touches nothing.
plan="$(python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/ke-idc-test-repo-install 2>&1)" \
  || fail "installer dry-run against an explicit sandbox repo did not succeed"
printf '%s' "$plan" | grep -Fq "idc-pathway-integrity" \
  || fail "installer plan does not name the ruleset it would install"
printf '%s' "$plan" | grep -Fq "idc/pathway-integrity" \
  || fail "installer plan does not name the required check it would enforce"
# A known production repo, even with --apply, is refused BEFORE any mutation.
python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/idc-workflow --apply >/dev/null 2>&1 \
  && fail "installer did NOT refuse to mutate a known production repo"

echo "PASS: ruleset checker enforces PR flow, exact-head required check, force-push/deletion prevention, and all protected surfaces; installer refuses without --repo and refuses a production repo"
