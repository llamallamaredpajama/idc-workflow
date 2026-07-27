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

# --- F6: protected-surface OWNERSHIP (CODEOWNERS) validation ------------------------------------
# require_code_owner_review in the ruleset only binds a reviewer once a CODEOWNERS file names each
# protected surface. With --repo-root, the checker verifies that coverage and REFUSES an absent or
# incomplete CODEOWNERS. The shipped repo carries a CODEOWNERS covering all four surface classes.
python3 "$CHK" --ruleset "$RS" --repo-root "$PLUGIN" >/dev/null \
  || fail "the shipped ruleset + repo CODEOWNERS was rejected (every protected surface must be owned)"

# A CODEOWNERS that leaves one protected surface unowned is refused.
CO_ROOT="$WORK/co-incomplete"; mkdir -p "$CO_ROOT/.github"
cat > "$CO_ROOT/.github/CODEOWNERS" <<'CO'
.github/workflows/ @owner
scripts/hooks/ @owner
scripts/idc_validation_contract.py @owner
# the receipt surface is deliberately left unowned
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$CO_ROOT" 2>&1)" \
  && fail "checker admitted a repo whose CODEOWNERS leaves a protected surface unowned"
printf '%s\n' "$out" | grep -qiE 'codeowner|owner|receipt' \
  || fail "unowned-surface refusal must name the ownership gap; got: $out"

# A repo with NO CODEOWNERS file at all is refused.
NO_CO="$WORK/co-absent"; mkdir -p "$NO_CO"
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$NO_CO" 2>&1)" \
  && fail "checker admitted a repo with NO CODEOWNERS file"
printf '%s\n' "$out" | grep -qiE 'codeowner' \
  || fail "missing-CODEOWNERS refusal must name CODEOWNERS; got: $out"

# F20: GitHub CODEOWNERS is LAST-MATCH-WINS. A broad `* @owner` followed by a later, MORE-SPECIFIC
# rule with NO owner leaves that surface unowned on GitHub — the checker must refuse it, not
# false-certify coverage off the earlier `*` match. Red-when-broken: a first-match validator returns
# owned on the `*` rule and admits.
LMW_ROOT="$WORK/co-last-match"; mkdir -p "$LMW_ROOT/.github"
cat > "$LMW_ROOT/.github/CODEOWNERS" <<'CO'
* @owner
# a later, more-specific rule with NO owner un-owns the hook surface on GitHub (last-match-wins)
/scripts/hooks/
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$LMW_ROOT" 2>&1)" \
  && fail "checker false-certified a surface un-owned by a later last-match-wins ownerless override"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "last-match-wins refusal must name the un-owned surface; got: $out"

# Control: the SAME two rules in the OTHER order (`* @owner` LAST) legitimately owns every surface,
# because GitHub's last match is then the owning `*`. This must pass — the fix is precedence-aware,
# not a blanket ban on wildcard+specific combinations.
LMW_OK="$WORK/co-last-match-ok"; mkdir -p "$LMW_OK/.github"
cat > "$LMW_OK/.github/CODEOWNERS" <<'CO'
/scripts/hooks/
* @owner
CO
python3 "$CHK" --ruleset "$RS" --repo-root "$LMW_OK" >/dev/null \
  || fail "checker refused a CODEOWNERS whose LAST matching rule (`* @owner`) owns every surface"

# F20 (glob semantics) — GitHub distinguishes a NON-recursive one-level pattern (`dir/*`, `/*`) from a
# recursive subtree (`dir/**`, `dir/`). A `dir/*` owns only the files DIRECTLY in dir, NOT a nested
# subtree — so it must not false-certify `scripts/hooks/**`. Red-when-broken: a validator that strips
# `/*` and `/**` identically collapses the one-level rule into a recursive claim and admits.
#
# Case B — `/scripts/*` (one level under scripts) does NOT own the nested `scripts/hooks/**` subtree.
GS_B="$WORK/co-glob-b"; mkdir -p "$GS_B/.github"
cat > "$GS_B/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/* @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_B" 2>&1)" \
  && fail "checker false-certified scripts/hooks/** off a one-level /scripts/* (GitHub: one level only)"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "one-level-glob refusal must name the un-owned hook surface; got: $out"

# Case C — `/*` (one level at repo root) does NOT own any nested subtree.
GS_C="$WORK/co-glob-c"; mkdir -p "$GS_C/.github"
cat > "$GS_C/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/* @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_C" 2>&1)" \
  && fail "checker false-certified a nested surface off a root one-level /* (GitHub: root files only)"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "root one-level-glob refusal must name the un-owned surface; got: $out"

# Case D — a later OWNERLESS descendant rule (`/scripts/hooks/*.py`) un-owns part of a surface an
# earlier recursive rule owned; the whole surface is then not owned on GitHub.
GS_D="$WORK/co-glob-d"; mkdir -p "$GS_D/.github"
cat > "$GS_D/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/hooks/ @team
/scripts/hooks/*.py
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_D" 2>&1)" \
  && fail "checker missed a later ownerless descendant (*.py) un-owning part of scripts/hooks/**"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "ownerless-descendant refusal must name the un-owned hook surface; got: $out"

# F20 (REOPENED round-3-codex) — the matcher strategy CHANGED to a strict class allowlist: each
# documented GitHub CODEOWNERS pattern class is modeled precisely (any-depth semantics INCLUDED), and
# ANY pattern outside the modeled classes fails CLOSED (can never certify). GitHub anchors a pattern
# only when it carries a leading/middle slash; a SLASHLESS or trailing-slash-only pattern matches at
# ANY DEPTH. The two reopen vectors below were false-certified when the round-3 matcher mis-anchored
# such patterns to the repo root.
#
# Case E — a SLASHLESS bare directory (`hooks/`) matches at ANY DEPTH, so a later ownerless `hooks/`
# un-owns `scripts/hooks/**` an earlier anchored rule owned. Red-when-broken (pre-fix): the validator
# classified `hooks/` as a root-anchored dir, missed the override, and returned owned=True (false-certify).
GS_E="$WORK/co-glob-e"; mkdir -p "$GS_E/.github"
cat > "$GS_E/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/hooks/ @team
hooks/
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_E" 2>&1)" \
  && fail "checker false-certified scripts/hooks/** — a later ownerless slashless 'hooks/' un-owns it at any depth"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "slashless-dir refusal must name the un-owned hook surface; got: $out"

# Case F — a SLASHLESS bare FILENAME (`idc_validation_contract.py`) matches that basename at ANY DEPTH,
# so a later ownerless one un-owns the validation surface an earlier anchored rule owned. Red-when-broken
# (pre-fix): classified as an exact repo-root file, missed the override, returned owned=True.
GS_F="$WORK/co-glob-f"; mkdir -p "$GS_F/.github"
cat > "$GS_F/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_receipt_check.py @team
/scripts/idc_validation_contract.py @team
idc_validation_contract.py
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_F" 2>&1)" \
  && fail "checker false-certified the validation surface — a later ownerless slashless basename un-owns it at any depth"
printf '%s\n' "$out" | grep -qiE 'valid|owner' \
  || fail "slashless-file refusal must name the un-owned validation surface; got: $out"

# Case G (control — precedence-aware, NOT a blanket ban on unanchored rules) — a slashless OWNED rule
# (`hooks/ @team`) legitimately owns `scripts/hooks/**` because GitHub matches it at any depth. The
# checker MUST certify it. Red-when-broken (pre-fix): the any-depth OWNED rule was mis-anchored to the
# root and FALSE-REFUSED (owned=False), so the shipped-style diagnostic wrongly rejected a valid repo.
GS_G="$WORK/co-glob-g"; mkdir -p "$GS_G/.github"
cat > "$GS_G/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
hooks/ @team
CO
python3 "$CHK" --ruleset "$RS" --repo-root "$GS_G" >/dev/null \
  || fail "checker false-refused an any-depth OWNED rule ('hooks/ @team') that owns scripts/hooks/** on GitHub"

# Case H (fail-closed on an UNMODELED pattern) — a surface 'owned' ONLY by a pattern outside the
# modeled classes (a `[a-z]` char range — which CODEOWNERS does not even support) must NEVER certify:
# the validator refuses rather than guessing the glob's reach. Guards the class-allowlist invariant so
# an adversarial/unknown pattern can never be leaned on to establish ownership.
GS_H="$WORK/co-glob-h"; mkdir -p "$GS_H/.github"
cat > "$GS_H/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/hooks/[a-z]*.py @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_H" 2>&1)" \
  && fail "checker certified scripts/hooks/** off an UNMODELED char-range pattern — it must fail closed"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "unmodeled-pattern refusal must name the un-owned hook surface; got: $out"

# Case I (fail-closed on a different UNMODELED shape) — an owner that reaches the surface only through
# a mid-pattern `**` we do not model must not certify either.
GS_I="$WORK/co-glob-i"; mkdir -p "$GS_I/.github"
cat > "$GS_I/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/**/hooks @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_I" 2>&1)" \
  && fail "checker certified scripts/hooks/** off an UNMODELED mid-'**' pattern — it must fail closed"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "unmodeled mid-** refusal must name the un-owned hook surface; got: $out"

# F28 (surface typing, NOT the rule matcher) — a bare protected-surface entry whose basename contains
# a dot (`config/my.dir`, a dotfile dir like `.github`) is a DIRECTORY, but `_surface_target` guessed
# it was a FILE. Typed as a file the checker only un-owns on an EXACT-name match, so a later ownerless
# rule carving a hole INSIDE the directory is invisible and the surface false-certifies. The fix
# re-types the surface to a directory once a rule structurally proves it is one, so the interior
# ownerless hole un-owns it. These cases use a ruleset whose protected_surfaces carry an extra
# dotted-DIRECTORY surface (the four shipped surface classes are preserved so validate_contract passes).
F28_RS="$WORK/rs-f28.json"
python3 - "$RS" "$F28_RS" <<'PY' || fail "F28 ruleset setup failed"
import json, sys
d = json.load(open(sys.argv[1]))
d["idc_contract"]["protected_surfaces"].append("config/my.dir")   # a dotted-basename DIRECTORY surface
json.dump(d, open(sys.argv[2], "w"))
PY

# Case J (F28 false-certify) — `/config/my.dir/ @team` owns the directory, then a later ownerless
# `/config/my.dir/secret.txt` carves a hole; GitHub leaves secret.txt unowned, so the surface is NOT
# fully owned. Red-when-broken (pre-fix): the surface was typed as a file, the interior hole matched
# no exact file, and the checker returned owned=True — a false-certify.
F28_HOLE="$WORK/co-f28-hole"; mkdir -p "$F28_HOLE/.github"
cat > "$F28_HOLE/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/config/my.dir/ @team
/config/my.dir/secret.txt
CO
out="$(python3 "$CHK" --ruleset "$F28_RS" --repo-root "$F28_HOLE" 2>&1)" \
  && fail "checker false-certified a dotted-basename DIRECTORY surface with an ownerless interior hole (F28)"
printf '%s\n' "$out" | grep -qiE 'my\.dir|owner' \
  || fail "F28 refusal must name the un-owned dotted-directory surface; got: $out"

# Case K (F28 control) — the SAME dotted-directory surface FULLY owned (no interior hole) still
# certifies, and the shipped dotted-FILE surfaces are unaffected (no rule structurally makes them
# directories). Proves the fix is precedence/structure-aware, not a blanket refusal of dotted paths.
F28_OK="$WORK/co-f28-ok"; mkdir -p "$F28_OK/.github"
cat > "$F28_OK/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/config/my.dir/ @team
CO
python3 "$CHK" --ruleset "$F28_RS" --repo-root "$F28_OK" >/dev/null \
  || fail "checker false-refused a fully-owned dotted-directory surface (F28 control), or regressed a shipped dotted-file surface"

# --- installer safety guards (no network is reached before these refusals) ----------------------
# No --repo -> refuse (never guesses the target board).
python3 "$INS" --ruleset "$RS" >/dev/null 2>&1 \
  && fail "installer acted with NO --repo target (must refuse without an explicit repo)"
# Explicit sandbox repo + a --repo-root whose CODEOWNERS covers every surface -> dry-run plan, exit 0.
plan="$(python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/ke-idc-test-repo-install \
        --repo-root "$PLUGIN" 2>&1)" \
  || fail "installer dry-run against an explicit sandbox repo (with a complete --repo-root) did not succeed"
printf '%s' "$plan" | grep -Fq "idc-pathway-integrity" \
  || fail "installer plan does not name the ruleset it would install"
printf '%s' "$plan" | grep -Fq "idc/pathway-integrity" \
  || fail "installer plan does not name the required check it would enforce"
# A known production repo, even with --apply, is refused BEFORE any mutation (production guard first).
python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/idc-workflow --apply >/dev/null 2>&1 \
  && fail "installer did NOT refuse to mutate a known production repo"

# F18 (REOPENED round-3-codex) — the ownership gate must validate the TARGET repo named by --repo, NOT
# the ruleset-carrying checkout. For the SHIPPED default ruleset that checkout is the PLUGIN itself,
# whose CODEOWNERS covers all four surfaces — so the round-2 derivation validated the wrong repo and
# would bind require_code_owner_review onto a target with NO CODEOWNERS at all. The fix stops deriving
# the root from the ruleset path: --repo-root (a checkout of --repo) is now REQUIRED.
#
# (a) The documented default invocation — shipped ruleset, --repo target, NO --repo-root — must REFUSE
#     rather than fall back to the plugin's own CODEOWNERS and pass. Red-when-broken (pre-fix): the
#     installer derived repo_root=<plugin>, ownership passed, and this invocation printed a plan / exit 0.
out="$(python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/ke-idc-test-repo-install 2>&1)" \
  && fail "installer validated the ruleset-carrying (plugin) checkout instead of the target — the default invocation must REFUSE without --repo-root"
printf '%s\n' "$out" | grep -qiE 'repo-root|codeowner|owner' \
  || fail "missing-target-checkout refusal must explain that --repo-root is required; got: $out"

# (b) A real TARGET checkout with NO CODEOWNERS is refused — require_code_owner_review would bind no
#     reviewer. This is the gap F18 exists to close, now checked on the actual --repo-root target.
TGT_NOCO="$WORK/target-no-codeowners"; mkdir -p "$TGT_NOCO"
out="$(python3 "$INS" --ruleset "$RS" --repo llamallamaredpajama/ke-idc-test-repo-install \
        --repo-root "$TGT_NOCO" 2>&1)" \
  && fail "installer did NOT refuse a target checkout whose CODEOWNERS is absent"
printf '%s\n' "$out" | grep -qiE 'codeowner|owner' \
  || fail "target-ownership refusal must name the CODEOWNERS gap; got: $out"

echo "PASS: ruleset checker enforces PR flow, exact-head required check, force-push/deletion prevention, all protected surfaces, GitHub any-depth/last-match-wins ownership with a strict class allowlist that fails closed on unmodeled patterns, and re-types a dotted-basename DIRECTORY surface off the file guess so an interior ownerless hole cannot false-certify (F28); installer refuses without --repo, refuses a production repo, and requires --repo-root so the TARGET repo's CODEOWNERS (never the ruleset's) gates the install"
