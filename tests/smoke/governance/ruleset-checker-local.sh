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

# F40 — the mandatory ownership set now also covers the governance-of-governance surfaces (the
# deterministic checker, the ruleset directory, and CODEOWNERS itself). Fixtures that must ISOLATE a
# single vector append these three so the ONLY ownership gap is the surface under test; a fixture
# missing them would refuse for the wrong reason and mask a matcher regression (the checker would still
# refuse on the governance gap even if the vector surface were wrongly certified).
GOV='/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team'
add_gov() { printf '%s\n' "$GOV" >> "$1/.github/CODEOWNERS"; }   # $1 = repo root

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
# F40 — the three governance-of-governance surface classes are mandatory too.
refute "protected CHECKER surface removed (idc_pathway_check.py)" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if "idc_pathway_check.py" not in s]'
refute "protected RULESET-DIR surface removed (.github/rulesets)" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if ".github/rulesets" not in s]'
refute "protected CODEOWNERS-self surface removed (.github/CODEOWNERS)" \
  'contract["protected_surfaces"] = [s for s in contract["protected_surfaces"] if "CODEOWNERS" not in s]'

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
add_gov "$CO_ROOT"   # own the governance surfaces so RECEIPT is the sole gap (F40 isolation)
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
add_gov "$GS_B"
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
add_gov "$GS_C"
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
add_gov "$GS_D"
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
add_gov "$GS_E"
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
add_gov "$GS_F"
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
add_gov "$GS_G"   # a valid control must own ALL surfaces incl. the F40 governance set
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
add_gov "$GS_H"
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
add_gov "$GS_I"
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
add_gov "$F28_HOLE"   # own the governance surfaces so the dotted-dir HOLE is the sole gap (F40 isolation)
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
add_gov "$F28_OK"   # the control must own ALL surfaces incl. the F40 governance set
python3 "$CHK" --ruleset "$F28_RS" --repo-root "$F28_OK" >/dev/null \
  || fail "checker false-refused a fully-owned dotted-directory surface (F28 control), or regressed a shipped dotted-file surface"

# Case F35 — a CODEOWNERS whose bytes are NOT valid UTF-8 must fail closed with a CLEAN refusal, never
# an uncaught UnicodeDecodeError traceback. Red-when-broken (pre-fix): `_read_codeowners` caught only
# OSError, so an invalid byte crashed the checker with a Python traceback (still non-zero, but ungraceful
# and with no actionable message). `\377\376` are raw non-UTF-8 bytes.
BADUTF="$WORK/co-bad-utf8"; mkdir -p "$BADUTF/.github"
printf '* @team\n\377\376 not utf-8\n' > "$BADUTF/.github/CODEOWNERS"
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$BADUTF" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  || fail "checker admitted a repo whose CODEOWNERS is not valid UTF-8"
printf '%s\n' "$out" | grep -q 'Traceback (most recent call last)' \
  && fail "invalid-UTF-8 CODEOWNERS crashed with a traceback instead of a clean fail-closed refusal (F35)"
printf '%s\n' "$out" | grep -qiE 'unreadable|codeowner' \
  || fail "invalid-UTF-8 refusal must be a clean CODEOWNERS message; got: $out"

# Case L (F32 — round-4 regression) — a `**/name/` pattern (leading `**/` + TRAILING slash + dotted
# basename) is DIRECTORY-ONLY at any depth: it owns a directory named `idc_validation_contract.py`
# anywhere, NEVER the regular FILE `scripts/idc_validation_contract.py`. So `**/idc_validation_contract.py/ @team`
# leaves the validation FILE surface unowned on GitHub and the checker must refuse. Red-when-broken
# (pre-fix): routed to `_name_matcher`, the trailing slash was rstripped and the dotted basename typed
# as a FILE → owned=True (false-certify of a shipped protected-surface basename).
GS_L="$WORK/co-glob-l"; mkdir -p "$GS_L/.github"
cat > "$GS_L/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_receipt_check.py @team
**/idc_validation_contract.py/ @team
CO
add_gov "$GS_L"
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_L" 2>&1)" \
  && fail "checker false-certified the validation FILE surface off a directory-only '**/name/' pattern (F32)"
printf '%s\n' "$out" | grep -qiE 'valid|owner' \
  || fail "F32 refusal must name the un-owned validation surface; got: $out"

# Case M (F33) — a lone `/ @team` matches NOTHING on GitHub, so it certifies no surface; the checker
# must not read it as repo-wide ownership. Red-when-broken (pre-fix): `/` was in the root-equivalence
# set, so `/ @team` set owned=True for every surface.
GS_M="$WORK/co-glob-m"; mkdir -p "$GS_M/.github"
cat > "$GS_M/.github/CODEOWNERS" <<'CO'
/ @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$GS_M" 2>&1)" \
  && fail "checker false-certified every surface off a bare '/ @team' that GitHub matches nothing for (F33)"
printf '%s\n' "$out" | grep -qiE 'owner|surface' \
  || fail "bare-slash refusal must name an un-owned surface; got: $out"

# Case F46 — a TRAILING-SLASH rule on a protected FILE surface (`/scripts/idc_validation_contract.py/ @team`)
# is DIRECTORY-ONLY on GitHub: it owns a directory of that name (which does not exist), NEVER the regular
# FILE, so require_code_owner_review binds no reviewer to the file. The checker must type the KNOWN
# governance file surfaces from what they ARE (files) — not infer directory-ness from the trailing-slash
# rule under validation — and REFUSE. Red-when-broken (pre-fix): `_declares_directory` re-typed the file
# surface to a directory off the `D == surface_path` trailing-slash rule and `_surface_is_owned` returned
# owned=True, false-certifying all three shipped dotted-file surfaces (and CODEOWNERS) F40 protects.
# Each fixture owns EVERY surface correctly except it swaps ONE file surface's rule to the trailing-slash
# form, so that file is the sole ownership gap. `$1`=label, `$2`=the covered surface path to sabotage,
# `$3`=a grep pattern the refusal must name.
f46_refute() {
  local surface="$2" root="$WORK/co-f46-$1"; mkdir -p "$root/.github"
  # A fully-covering CODEOWNERS, then rewrite `$surface`'s bare rule to a directory-only trailing-slash one.
  cat > "$root/.github/CODEOWNERS" <<CO
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
  # Replace the exact bare rule "/$surface @team" with the dir-only "/$surface/ @team".
  python3 - "$root/.github/CODEOWNERS" "$surface" <<'PY'
import sys
p, surface = sys.argv[1], sys.argv[2]
text = open(p).read()
text = text.replace("/{} @team".format(surface), "/{}/ @team".format(surface))
open(p, "w").write(text)
PY
  out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$root" 2>&1)" \
    && fail "checker false-certified the FILE surface $surface owned only by a directory-only trailing-slash rule (F46)"
  printf '%s\n' "$out" | grep -qiE "$3" \
    || fail "F46 refusal must name the un-owned file surface $surface; got: $out"
}
f46_refute "validation" "scripts/idc_validation_contract.py" 'idc_validation_contract\.py|valid|owner'
f46_refute "receipt"    "scripts/idc_receipt_check.py"       'idc_receipt_check\.py|receipt|owner'
f46_refute "checker"    "scripts/idc_pathway_check.py"       'idc_pathway_check\.py|checker|owner'
f46_refute "codeowners" ".github/CODEOWNERS"                 'CODEOWNERS|owner'

# Case F46 control — a genuine DIRECTORY surface owned by a TRAILING-SLASH rule still certifies (the
# trailing slash is exactly how a directory IS owned on GitHub). The shipped ruleset's three directory
# surfaces (.github/workflows/**, scripts/hooks/**, .github/rulesets/**) are all owned via trailing-slash
# rules in the shipped-cert check above, so this simply reconfirms the F46 fix did not blanket-ban
# trailing-slash ownership — it fails closed only for FILE surfaces.
F46_DIR_OK="$WORK/co-f46-dir-ok"; mkdir -p "$F46_DIR_OK/.github"
cat > "$F46_DIR_OK/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
python3 "$CHK" --ruleset "$RS" --repo-root "$F46_DIR_OK" >/dev/null \
  || fail "checker false-refused genuine directory surfaces owned by trailing-slash rules (F46 control)"

# Case F47 — the mandatory-class check matches each governance class EXACTLY (basename for file classes,
# path-prefix for dir classes), never an anywhere-substring. A protected_surfaces list of LOOKALIKES that
# merely CONTAIN the class keys (`scripts/not-idc_pathway_check.py`, `tmp/.github/rulesets-backup`,
# `docs/CODEOWNERS.bak`) must NOT satisfy the checker/ruleset/codeowners classes — the ownership gate would
# otherwise validate the owned lookalikes while the real governance files stay unguarded. Red-when-broken
# (pre-fix): the `key in s` substring check accepted the lookalikes and validate_contract returned no
# reasons. Uses a ruleset whose protected_surfaces are the four legit surfaces + three lookalikes.
F47_RS="$WORK/rs-f47.json"
python3 - "$RS" "$F47_RS" <<'PY' || fail "F47 ruleset setup failed"
import json, sys
d = json.load(open(sys.argv[1]))
d["idc_contract"]["protected_surfaces"] = [
    ".github/workflows/**", "scripts/hooks/**",
    "scripts/idc_validation_contract.py", "scripts/idc_receipt_check.py",
    "scripts/not-idc_pathway_check.py",   # lookalike: NOT the real checker
    "tmp/.github/rulesets-backup",        # lookalike: NOT the ruleset dir
    "docs/CODEOWNERS.bak",                # lookalike: NOT CODEOWNERS
]
json.dump(d, open(sys.argv[2], "w"))
PY
out="$(python3 "$CHK" --ruleset "$F47_RS" 2>&1)" \
  && fail "checker accepted a protected_surfaces list where lookalike substrings stand in for the real checker/ruleset/CODEOWNERS governance files (F47)"
printf '%s\n' "$out" | grep -qiE 'checker|ruleset|codeowners|does not cover' \
  || fail "F47 refusal must name the uncovered governance class(es); got: $out"

# Case F49 — the codeowners surface is pinned to `.github/CODEOWNERS`, but GitHub reads whichever of the
# three honored locations is present. When the EFFECTIVE governing file is a ROOT `CODEOWNERS` (no
# `.github/CODEOWNERS`), it must own ITSELF (`/CODEOWNERS`) or it can be weakened without a code-owner
# review. A root CODEOWNERS that owns the declared `.github/CODEOWNERS` path (and every other surface) but
# NOT its own `/CODEOWNERS` path must REFUSE. Red-when-broken (pre-fix): nothing forced the effective file
# to own itself, so this certified. `.github/CODEOWNERS` is deliberately ABSENT so root is the effective file.
F49_ROOT="$WORK/co-f49-root"; mkdir -p "$F49_ROOT"
cat > "$F49_ROOT/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$F49_ROOT" 2>&1)" \
  && fail "checker certified a root CODEOWNERS that owns .github/CODEOWNERS but not its own /CODEOWNERS path (F49 — the effective governing file must own itself)"
printf '%s\n' "$out" | grep -qiE 'own itself|effective|CODEOWNERS' \
  || fail "F49 refusal must name the effective governing file's self-ownership gap; got: $out"

# Case F49 control — the SAME root CODEOWNERS that ALSO owns its own `/CODEOWNERS` path certifies, so the
# self-ownership requirement does not blanket-reject a legitimate root/docs CODEOWNERS placement.
F49_OK="$WORK/co-f49-root-ok"; mkdir -p "$F49_OK"
cat > "$F49_OK/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
/CODEOWNERS @team
CO
python3 "$CHK" --ruleset "$RS" --repo-root "$F49_OK" >/dev/null \
  || fail "checker false-refused a root CODEOWNERS that legitimately owns its own /CODEOWNERS path (F49 control)"

# Case F50 — a bare slashless pattern matches at ANY DEPTH and, having no trailing slash, matches a FILE
# of that name as well as a directory. So a trailing OWNERLESS `CODEOWNERS` line is applied last-match-wins
# by GitHub to the file `.github/CODEOWNERS` itself and UN-OWNS it, even though an earlier anchored rule
# owned it. The checker must see that un-own and REFUSE. Red-when-broken (pre-fix): the FILE reading of an
# unanchored directory-name matcher only checked ANCESTOR components, never a basename match, so the
# ownerless line scored `none`, the un-own was invisible, and the governance file false-certified.
# The slashless rule also matches at any depth for the DIRECTORY surfaces, so those are deliberately
# RE-OWNED after it: that isolates the vector to the CODEOWNERS FILE, whose last matching rule stays the
# ownerless slashless line (none of the re-owning directory rules match `.github/CODEOWNERS`). Without
# this isolation the checker would refuse over the directory surfaces and mask a regression here.
F50_ROOT="$WORK/co-f50"; mkdir -p "$F50_ROOT/.github"
cat > "$F50_ROOT/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CODEOWNERS
/.github/workflows/ @team
/scripts/hooks/ @team
/.github/rulesets/ @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$F50_ROOT" 2>&1)" \
  && fail "checker certified .github/CODEOWNERS while a later ownerless slashless 'CODEOWNERS' rule un-owns it under GitHub last-match-wins (F50)"
printf '%s\n' "$out" | grep -qiE 'CODEOWNERS|no code owner' \
  || fail "F50 refusal must name the un-owned CODEOWNERS surface; got: $out"

# Case F50 control — the SAME fixture with the ownerless slashless line given an OWNER certifies, so the
# added basename leg reads a bare-name rule as ownership too and does not blanket-refuse.
F50_OK="$WORK/co-f50-ok"; mkdir -p "$F50_OK/.github"
sed 's/^CODEOWNERS$/CODEOWNERS @team/' "$F50_ROOT/.github/CODEOWNERS" > "$F50_OK/.github/CODEOWNERS"
python3 "$CHK" --ruleset "$RS" --repo-root "$F50_OK" >/dev/null \
  || fail "checker false-refused a .github/CODEOWNERS owned by a bare-name rule (F50 control)"

# Case F51 — the mandatory governance classes must be declared at their CANONICAL paths. A decoy sharing
# only the basename (`tmp/idc_pathway_check.py`) leaves the REAL checker/validation/receipt files absent
# from protected_surfaces, so `require_code_owner_review` binds no reviewer to the file the workflow
# actually executes — defeating F40 while the contract reports full coverage. Red-when-broken (pre-fix):
# file classes matched on basename ANYWHERE, so the decoys satisfied all three classes and this certified.
F51_RS="$WORK/rs-f51.json"
python3 - "$RS" "$F51_RS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["idc_contract"]["protected_surfaces"] = [
    ".github/workflows/**", "scripts/hooks/**", ".github/rulesets/**", ".github/CODEOWNERS",
    "tmp/idc_validation_contract.py",          # decoy — real file at scripts/ stays unprotected
    "tmp/idc_receipt_check.py",                # decoy
    "tmp/idc_pathway_check.py",                # decoy — the EXECUTED checker
]
json.dump(d, open(sys.argv[2], "w"))
PY
out="$(python3 "$CHK" --ruleset "$F51_RS" 2>&1)" \
  && fail "checker accepted decoy same-basename paths in place of the canonical checker/validation/receipt governance files (F51)"
printf '%s\n' "$out" | grep -qiE 'idc_pathway_check.py|idc_validation_contract.py|idc_receipt_check.py' \
  || fail "F51 refusal must name the uncovered canonical governance file(s); got: $out"

# Case F51 control — CODEOWNERS is the one class GitHub honors at several locations, so declaring it at
# the root path must still satisfy the class (the canonical-exact rule must not break legitimate placement).
F51_OK="$WORK/rs-f51-ok.json"
python3 - "$RS" "$F51_OK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["idc_contract"]["protected_surfaces"] = [
    s for s in d["idc_contract"]["protected_surfaces"] if "CODEOWNERS" not in s] + ["CODEOWNERS"]
json.dump(d, open(sys.argv[2], "w"))
PY
python3 "$CHK" --ruleset "$F51_OK" >/dev/null \
  || fail "checker refused a CODEOWNERS class declared at a GitHub-honored location (F51 control)"

# Case F52 — a FILE declared BENEATH a governance directory class is a file, not the class. Typing it from
# the CLASS's kind let a directory-only trailing-slash rule `covers_all`-certify it, while GitHub reads the
# trailing slash as directory-only and leaves the real file UNOWNED — the F46 vector one level down.
#
# Asserted at the OWNERSHIP-FUNCTION level, deliberately. At whole-contract level this vector is MASKED:
# any rule that un-owns a file inside `.github/workflows` also carves a hole in the mandatory
# `.github/workflows/**` directory surface, so the checker already refuses over the directory and would
# stay green no matter how the descendant was typed. The mis-typing is therefore a defense-in-depth
# defect, not an exploitable contract-level false-certify — and only a direct assertion can prove it is
# fixed. Red-when-broken: restore the class-prefix match in `_surface_declares_class` and the first
# assertion below reports owned=True.
python3 - "$PLUGIN" <<'PY' || fail "F52: descendant-file typing assertions failed (see message above)"
import sys, importlib
sys.path.insert(0, sys.argv[1] + "/scripts")
RC = importlib.import_module("idc_ruleset_check")
S = ".github/workflows/idc-pathway-integrity.yml"

# The declared surface is a FILE and must be typed as one — never as the directory class it sits under.
if RC._authoritative_surface_type(S) == "dir":
    print("FAIL: descendant file %r inherited the directory class's kind (F52)" % S); sys.exit(1)

# A directory-only trailing-slash rule names an owner but GitHub never applies it to a regular file.
dir_only_rule = RC._codeowners_rules("/.github/workflows/idc-pathway-integrity.yml/ @team\n")
if RC._surface_is_owned(S, dir_only_rule):
    print("FAIL: directory-only trailing-slash rule certified the descendant FILE surface %r, which "
          "GitHub leaves unowned (F52)" % S); sys.exit(1)

# Control — a genuine file rule (no trailing slash) still establishes ownership, so the stricter typing
# does not false-refuse legitimate coverage.
file_rule = RC._codeowners_rules("/.github/workflows/idc-pathway-integrity.yml @team\n")
if not RC._surface_is_owned(S, file_rule):
    print("FAIL: genuine file rule was false-refused for descendant surface %r (F52 control)" % S)
    sys.exit(1)

# Control — an ancestor directory rule legitimately covers the file, exactly as GitHub resolves it.
anc = RC._codeowners_rules("/.github/workflows/ @team\n")
if not RC._surface_is_owned(S, anc):
    print("FAIL: ancestor directory rule was false-refused for descendant surface %r (F52 control)" % S)
    sys.exit(1)
PY

# Case F40 — the mandatory ownership set now also covers the governance-of-governance surfaces (the
# deterministic checker scripts/idc_pathway_check.py, the ruleset directory, and CODEOWNERS itself). A
# CODEOWNERS owning ONLY the original four protected surfaces must now REFUSE — otherwise those three
# guard-machinery paths stay weakenable without a code-owner review (strip owners from CODEOWNERS, or
# poison the checker the next PR's trusted base then runs). Red-when-broken (pre-fix): protected_surfaces
# listed only the 4, so a four-surface CODEOWNERS certified.
F40_ONLY4="$WORK/co-only-four"; mkdir -p "$F40_ONLY4/.github"
cat > "$F40_ONLY4/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
CO
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$F40_ONLY4" 2>&1)" \
  && fail "checker certified a CODEOWNERS owning only the 4 original surfaces — the checker/ruleset/CODEOWNERS governance surfaces must be mandated too (F40)"
printf '%s\n' "$out" | grep -qiE 'idc_pathway_check|rulesets|CODEOWNERS' \
  || fail "F40 refusal must name an un-owned governance surface; got: $out"

# Case F41 — a bare `@` (or any malformed owner token) is NOT a valid CODEOWNERS owner: GitHub binds no
# reviewer to it. `/scripts/hooks/ @` must leave the hook surface UNOWNED. Red-when-broken (pre-fix): the
# owner filter counted any `@`-containing token, so a bare `@` certified a surface GitHub bound nobody to.
F41_BARE="$WORK/co-bare-at"; mkdir -p "$F41_BARE/.github"
cat > "$F41_BARE/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
CO
add_gov "$F41_BARE"   # own the governance surfaces so the bare-@ HOOK surface is the sole gap
out="$(python3 "$CHK" --ruleset "$RS" --repo-root "$F41_BARE" 2>&1)" \
  && fail "checker counted a bare '@' as an owner and certified an unbound hook surface (F41)"
printf '%s\n' "$out" | grep -qiE 'hook|owner' \
  || fail "bare-@ refusal must name the un-owned hook surface; got: $out"

# Case F41 control — a valid EMAIL owner (a documented CODEOWNERS owner form) legitimately owns its
# surface, so the fix rejects malformed tokens WITHOUT rejecting the valid non-`@` owner form. Every
# surface (incl. the F40 governance set) is owned by an email address here.
F41_EMAIL="$WORK/co-email-owner"; mkdir -p "$F41_EMAIL/.github"
cat > "$F41_EMAIL/.github/CODEOWNERS" <<'CO'
/.github/workflows/ dev@example.com
/scripts/hooks/ dev@example.com
/scripts/idc_validation_contract.py dev@example.com
/scripts/idc_receipt_check.py dev@example.com
/scripts/idc_pathway_check.py dev@example.com
/.github/rulesets/ dev@example.com
/.github/CODEOWNERS dev@example.com
CO
python3 "$CHK" --ruleset "$RS" --repo-root "$F41_EMAIL" >/dev/null \
  || fail "checker rejected a valid EMAIL owner form (F41 control — @user, @org/team, and email must all bind)"

# --- installer safety guards (no network is reached before these refusals) ----------------------
# A helper: build a throwaway git checkout of a named target repo (its `origin` remote decides identity
# for the F34 gate). With a covering CODEOWNERS it writes ALL SEVEN protected surfaces (F40) and COMMITS
# them on the default branch, because F39 validates the CODEOWNERS GitHub actually enforces — the copy
# COMMITTED on the default branch, not the working tree. An initial commit always exists so the checkout
# has a resolvable branch even without a CODEOWNERS.
#
# It also sets `refs/remotes/origin/HEAD -> origin/main` (as a real clone would), because the installer
# reads the ENFORCED default branch from origin/HEAD and — post-F44 — REFUSES rather than falling back
# to the currently checked-out branch when it is unset. This mirrors a normal clone so the ownership
# cases below exercise the production resolution path; the F44 fail-closed + --default-branch override
# paths get their own dedicated fixtures (cases g/h).
SANDBOX="llamallamaredpajama/ke-idc-test-repo-install"
mk_target() {  # $1=dir  $2=OWNER/REPO for origin  $3=1 to write+commit a covering CODEOWNERS
  git init -q -b main "$1"
  git -C "$1" config user.email idc-test@example.com
  git -C "$1" config user.name "IDC Test"
  git -C "$1" config commit.gpgsign false
  git -C "$1" remote add origin "git@github.com:$2.git"
  echo placeholder > "$1/README.md"
  if [ "$3" = 1 ]; then
    mkdir -p "$1/.github"
    cat > "$1/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
  fi
  git -C "$1" add -A
  git -C "$1" commit -q -m init >/dev/null 2>&1
  # origin/HEAD -> origin/main, pointing at the just-made commit (what a real clone would carry).
  git -C "$1" update-ref refs/remotes/origin/main "$(git -C "$1" rev-parse HEAD)"
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# No --repo -> refuse (never guesses the target board).
python3 "$INS" --ruleset "$RS" >/dev/null 2>&1 \
  && fail "installer acted with NO --repo target (must refuse without an explicit repo)"
# Explicit sandbox repo + a --repo-root that is a genuine checkout OF that repo (matching origin) whose
# CODEOWNERS covers every surface -> dry-run plan, exit 0.
TGT_OK="$WORK/target-ok"; mk_target "$TGT_OK" "$SANDBOX" 1
plan="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_OK" 2>&1)" \
  || fail "installer dry-run against an explicit sandbox repo (with a matching, covered --repo-root) did not succeed"
printf '%s' "$plan" | grep -Fq "idc-pathway-integrity" \
  || fail "installer plan does not name the ruleset it would install"
printf '%s' "$plan" | grep -Fq "idc/pathway-integrity" \
  || fail "installer plan does not name the required check it would enforce"
# A known production repo, even with --apply, is refused BEFORE any mutation (production guard runs
# ahead of the --repo-root requirement, so no --repo-root is even needed to trip it).
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

# (b) A real TARGET checkout (matching origin) with NO CODEOWNERS is refused — require_code_owner_review
#     would bind no reviewer. This is the gap F18 exists to close, now checked on the actual target.
TGT_NOCO="$WORK/target-no-codeowners"; mk_target "$TGT_NOCO" "$SANDBOX" 0
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_NOCO" 2>&1)" \
  && fail "installer did NOT refuse a target checkout whose CODEOWNERS is absent"
printf '%s\n' "$out" | grep -qiE 'codeowner|owner' \
  || fail "target-ownership refusal must name the CODEOWNERS gap; got: $out"

# F34 — requiring --repo-root is not enough: it must be a checkout OF --repo. An operator can point it
# at ANY covering checkout (the plugin `.` is the convenient default when standing in it), and the
# ownership gate would then certify the WRONG repository — re-opening the exact hole F18 closes. The
# installer binds the two with a LOCAL origin-identity check and refuses on mismatch or an unverifiable
# checkout, BEFORE the ownership gate (so a covering-but-unrelated CODEOWNERS never gets a chance to
# false-certify).
#
# (c) A checkout whose origin names a DIFFERENT repo than --repo REFUSES — even though its CODEOWNERS
#     fully covers the surfaces. Red-when-broken (pre-fix): --repo-root was only checked for presence,
#     so a covering unrelated checkout passed the gate for an unowned target.
TGT_WRONG="$WORK/target-wrong-identity"; mk_target "$TGT_WRONG" "someone-else/unrelated-repo" 1
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_WRONG" 2>&1)" \
  && fail "installer certified the target using an UNRELATED checkout's CODEOWNERS (F34 — --repo-root not bound to --repo)"
printf '%s\n' "$out" | grep -qiE 'checkout of|not the --repo target|wrong repository|F34' \
  || fail "identity-mismatch refusal must explain --repo-root is not a checkout of --repo; got: $out"

# (d) A checkout with NO resolvable origin cannot be confirmed as the target and REFUSES (an
#     unverifiable checkout is not proof of the target repo).
TGT_NOORIGIN="$WORK/target-no-origin"; git init -q -b main "$TGT_NOORIGIN"
mkdir -p "$TGT_NOORIGIN/.github"
cat > "$TGT_NOORIGIN/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
CO
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_NOORIGIN" 2>&1)" \
  && fail "installer accepted a --repo-root with no resolvable origin (cannot confirm it is a checkout of --repo)"
printf '%s\n' "$out" | grep -qiE 'origin|confirm|unverifiable' \
  || fail "no-origin refusal must explain the identity cannot be confirmed; got: $out"

# F48 — the identity gate must check the remote HOST, not just the last two path segments. A checkout on
# a NON-GitHub host (an SSH host, GitLab, a local path) that merely ENDS in the target owner/repo is not a
# checkout of the GitHub --repo, so its CODEOWNERS must never certify the real target. Red-when-broken
# (pre-fix): `_normalize_remote` dropped the host, so origin `git@evil.example.com:<SANDBOX>` normalized to
# the sandbox owner/repo, passed the F34 gate, and (with a covering committed CODEOWNERS) reached the plan.
# Everything below matches a real clone EXCEPT the non-GitHub origin host, so the host is the sole difference.
TGT_EVILHOST="$WORK/target-evil-host"; git init -q -b main "$TGT_EVILHOST"
git -C "$TGT_EVILHOST" config user.email idc-test@example.com
git -C "$TGT_EVILHOST" config user.name "IDC Test"
git -C "$TGT_EVILHOST" config commit.gpgsign false
git -C "$TGT_EVILHOST" remote add origin "git@evil.example.com:$SANDBOX.git"   # NON-GitHub host, target path
mkdir -p "$TGT_EVILHOST/.github"
cat > "$TGT_EVILHOST/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
git -C "$TGT_EVILHOST" add -A && git -C "$TGT_EVILHOST" commit -q -m init >/dev/null 2>&1
git -C "$TGT_EVILHOST" update-ref refs/remotes/origin/main "$(git -C "$TGT_EVILHOST" rev-parse HEAD)"
git -C "$TGT_EVILHOST" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_EVILHOST" 2>&1)" \
  && fail "installer certified the GitHub target using a NON-GitHub-host checkout that ends in the same owner/repo (F48)"
printf '%s\n' "$out" | grep -qiE 'github|host|origin|confirm|F48' \
  || fail "F48 refusal must explain the origin is not on the GitHub host; got: $out"

# F53 — checking the HOST is still not enough: the SCHEME and the path SHAPE decide whether a remote is
# really a GitHub clone of --repo. `file://github.com/<target>.git` carries the right host but clones a
# local directory, and `https://github.com/decoy/<target>.git` carries an extra path segment — both used
# to reduce to the target owner/repo and pass the F34/F48 gate, so an unrelated checkout's CODEOWNERS
# could certify the real target. Each fixture below is a real clone EXCEPT its origin URL, so the URL is
# the sole difference. Red-when-broken: accept any scheme (or `len(segs) >= 2`) and these certify.
for f53 in "file://github.com/$SANDBOX.git|scheme" "https://github.com/decoy/$SANDBOX.git|segments"; do
  f53_url="${f53%%|*}"; f53_why="${f53##*|}"
  TGT_F53="$WORK/target-f53-$f53_why"; git init -q -b main "$TGT_F53"
  git -C "$TGT_F53" config user.email idc-test@example.com
  git -C "$TGT_F53" config user.name "IDC Test"
  git -C "$TGT_F53" config commit.gpgsign false
  git -C "$TGT_F53" remote add origin "$f53_url"
  mkdir -p "$TGT_F53/.github"
  cat > "$TGT_F53/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
  git -C "$TGT_F53" add -A && git -C "$TGT_F53" commit -q -m init >/dev/null 2>&1
  git -C "$TGT_F53" update-ref refs/remotes/origin/main "$(git -C "$TGT_F53" rev-parse HEAD)"
  git -C "$TGT_F53" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_F53" 2>&1)" \
    && fail "installer certified the GitHub target from an origin that is not a GitHub clone URL ($f53_why: $f53_url) (F53)"
  printf '%s\n' "$out" | grep -qiE 'github|host|origin|confirm|F53' \
    || fail "F53 refusal ($f53_why) must explain the origin is not a GitHub clone of the target; got: $out"
done

# F39 — GitHub enforces the CODEOWNERS COMMITTED on the default branch, not the working tree. The
# installer reads the committed copy (`git show <default-branch>:.github/CODEOWNERS`), validates THAT,
# and refuses when none is committed or when the working tree differs from it. Both directions below
# are red-when-broken: pre-fix the installer read the working-tree bytes directly and would have
# certified + installed require_code_owner_review while the enforced branch bound no reviewer.
#
# (e) A covering CODEOWNERS WRITTEN to the working tree but NEVER committed must REFUSE.
TGT_UNCOMMITTED="$WORK/target-uncommitted-co"; mk_target "$TGT_UNCOMMITTED" "$SANDBOX" 0  # committed: none
mkdir -p "$TGT_UNCOMMITTED/.github"
cat > "$TGT_UNCOMMITTED/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_UNCOMMITTED" 2>&1)" \
  && fail "installer certified an UNCOMMITTED working-tree CODEOWNERS (F39 — GitHub enforces the committed default-branch copy)"
printf '%s\n' "$out" | grep -qiE 'commit|working[- ]tree|enforce' \
  || fail "F39 uncommitted refusal must explain the committed/working-tree gap; got: $out"

# (f) A CODEOWNERS committed on the default branch but LOCALLY EDITED in the working tree must REFUSE —
#     the committed copy is what GitHub enforces, so a working-tree edit that appears to cover a surface
#     never reaches the enforced branch.
TGT_DIVERGED="$WORK/target-diverged-co"; mk_target "$TGT_DIVERGED" "$SANDBOX" 1   # committed: covering CODEOWNERS
printf '# stray local uncommitted edit\n' >> "$TGT_DIVERGED/.github/CODEOWNERS"
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_DIVERGED" 2>&1)" \
  && fail "installer certified a working tree that DIVERGES from the committed CODEOWNERS (F39)"
printf '%s\n' "$out" | grep -qiE 'differ|working[- ]tree|commit|match' \
  || fail "F39 divergence refusal must name the working-tree/committed mismatch; got: $out"

# F44 — the default branch GitHub ENFORCES is read from origin/HEAD. When origin/HEAD is unset (a
# single-branch clone, actions/checkout, or a locally git-init'd checkout), the installer must REFUSE
# rather than fall back to the currently checked-out branch — that fallback certifies ownership against
# a branch GitHub does not enforce. An explicit --default-branch <ref> is the sanctioned way to name
# the enforced branch for such checkouts, and it is validated to resolve.
#
# (g) origin/HEAD unset + NO --default-branch must REFUSE, even though a covering CODEOWNERS is committed
#     on the current branch. Red-when-broken (pre-fix): _default_branch_ref fell back to the current
#     branch 'main', read its covering CODEOWNERS, and CERTIFIED (printed a plan / exit 0).
TGT_NOHEAD="$WORK/target-no-origin-head"; mk_target "$TGT_NOHEAD" "$SANDBOX" 1
git -C "$TGT_NOHEAD" symbolic-ref -d refs/remotes/origin/HEAD   # simulate single-branch / actions-checkout / git-init
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_NOHEAD" 2>&1)" \
  && fail "installer certified with origin/HEAD unset — it must fail closed (F44), not trust the current branch"
printf '%s\n' "$out" | grep -qiE 'origin/HEAD|default[- ]branch|current|full clone' \
  || fail "F44 origin/HEAD-unset refusal must explain the enforced branch is unresolvable; got: $out"

# (h) The feature-branch flip: a checkout on a NON-default branch that carries a covering CODEOWNERS
#     while the real default branch (main) lacks one. The verdict must be decided by the ENFORCED branch,
#     never by which branch happens to be checked out.
TGT_FLIP="$WORK/target-branch-flip"
git init -q -b main "$TGT_FLIP"
git -C "$TGT_FLIP" config user.email idc-test@example.com
git -C "$TGT_FLIP" config user.name "IDC Test"
git -C "$TGT_FLIP" config commit.gpgsign false
git -C "$TGT_FLIP" remote add origin "git@github.com:$SANDBOX.git"
echo placeholder > "$TGT_FLIP/README.md"
git -C "$TGT_FLIP" add -A && git -C "$TGT_FLIP" commit -q -m init >/dev/null 2>&1   # main: NO CODEOWNERS
git -C "$TGT_FLIP" checkout -q -b add-governance
mkdir -p "$TGT_FLIP/.github"
cat > "$TGT_FLIP/.github/CODEOWNERS" <<'CO'
/.github/workflows/ @team
/scripts/hooks/ @team
/scripts/idc_validation_contract.py @team
/scripts/idc_receipt_check.py @team
/scripts/idc_pathway_check.py @team
/.github/rulesets/ @team
/.github/CODEOWNERS @team
CO
git -C "$TGT_FLIP" add -A && git -C "$TGT_FLIP" commit -q -m codeowners >/dev/null 2>&1   # feature: covering
# (h1) --default-branch main validates MAIN (uncovered) and REFUSES — proving the override selects the
#      named ref, NOT the checked-out 'add-governance'. Red-when-broken (pre-fix): the current-branch
#      fallback read add-governance's covering CODEOWNERS and certified.
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_FLIP" --default-branch main 2>&1)" \
  && fail "installer certified via the checked-out feature branch instead of the named --default-branch main (F44 flip)"
printf '%s\n' "$out" | grep -qiE 'codeowner|commit|owner' \
  || fail "F44 flip refusal must name the missing ownership on the enforced branch; got: $out"
# (h2) Control — --default-branch add-governance validates THAT (covered) ref and reaches the plan, so
#      the override genuinely selects the ref it names (not a blanket refusal).
python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_FLIP" --default-branch add-governance >/dev/null 2>&1 \
  || fail "installer refused --default-branch add-governance whose committed CODEOWNERS covers every surface (F44 override control)"
# (h3) A --default-branch that does not resolve in the checkout REFUSES (validated, never trusted).
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_FLIP" --default-branch nope-not-a-branch 2>&1)" \
  && fail "installer accepted a --default-branch that does not resolve in the checkout (F44)"
printf '%s\n' "$out" | grep -qiE 'does not resolve|resolve' \
  || fail "unresolvable --default-branch refusal must say it does not resolve; got: $out"

# F45 — the working-tree-vs-committed divergence guard compares CONTENT with newlines normalized on both
# sides. The working tree is read in text mode (LF) while the committed copy is raw `git show` bytes
# (keeps CRLF), so a byte-identical CRLF-committed CODEOWNERS must NOT be mistaken for a divergence.
# (i1) A covering CODEOWNERS committed with CRLF endings, working tree byte-identical, must reach the
#      plan. Red-when-broken (pre-fix): the raw-byte comparison saw LF (working tree) != CRLF (committed)
#      and hard-REFUSED a byte-identical file.
TGT_CRLF="$WORK/target-crlf-co"; git init -q -b main "$TGT_CRLF"
git -C "$TGT_CRLF" config core.autocrlf false   # store the CRLF bytes verbatim (no checkout conversion)
git -C "$TGT_CRLF" config user.email idc-test@example.com
git -C "$TGT_CRLF" config user.name "IDC Test"
git -C "$TGT_CRLF" config commit.gpgsign false
git -C "$TGT_CRLF" remote add origin "git@github.com:$SANDBOX.git"
echo placeholder > "$TGT_CRLF/README.md"
mkdir -p "$TGT_CRLF/.github"
printf '/.github/workflows/ @team\r\n/scripts/hooks/ @team\r\n/scripts/idc_validation_contract.py @team\r\n/scripts/idc_receipt_check.py @team\r\n/scripts/idc_pathway_check.py @team\r\n/.github/rulesets/ @team\r\n/.github/CODEOWNERS @team\r\n' > "$TGT_CRLF/.github/CODEOWNERS"
git -C "$TGT_CRLF" add -A && git -C "$TGT_CRLF" commit -q -m init >/dev/null 2>&1
git -C "$TGT_CRLF" update-ref refs/remotes/origin/main "$(git -C "$TGT_CRLF" rev-parse HEAD)"
git -C "$TGT_CRLF" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_CRLF" >/dev/null 2>&1 \
  || fail "installer false-refused a byte-identical CRLF-committed CODEOWNERS (F45 — divergence guard compared LF working tree vs raw CRLF committed bytes)"
# (i2) Control — a genuine CONTENT edit (beyond line endings) still REFUSES, so the normalization does
#      not blind the guard to a real divergence.
printf '/extra/genuine/ @team\r\n' >> "$TGT_CRLF/.github/CODEOWNERS"
out="$(python3 "$INS" --ruleset "$RS" --repo "$SANDBOX" --repo-root "$TGT_CRLF" 2>&1)" \
  && fail "installer certified a genuinely diverged working tree after CRLF normalization (F45 control)"
printf '%s\n' "$out" | grep -qiE 'differ|working[- ]tree|commit|match' \
  || fail "F45 genuine-divergence refusal must name the working-tree/committed mismatch; got: $out"

echo "PASS: ruleset checker enforces PR flow, exact-head required check, force-push/deletion prevention, all seven protected surfaces (incl. the F40 governance-of-governance set: the checker, the ruleset dir, and CODEOWNERS itself), GitHub any-depth/last-match-wins ownership with a strict class allowlist that fails closed on unmodeled patterns, re-types a dotted-basename DIRECTORY surface off the file guess so an interior ownerless hole cannot false-certify (F28), treats a '**/name/' trailing-slash pattern as directory-only (F32) and a bare '/' as matching-nothing (F33), and counts only valid owner tokens so a bare '@' cannot false-certify (F41); installer refuses without --repo, refuses a production repo, requires --repo-root, BINDS it to --repo via a local origin-identity check (F34), and validates the CODEOWNERS COMMITTED on the default branch — refusing an uncommitted or working-tree-diverged copy (F39); reads the enforced branch from origin/HEAD and REFUSES rather than trusting the checked-out branch when it is unset, accepting a validated --default-branch override (F44); and normalizes newlines before the divergence compare so a byte-identical CRLF-committed CODEOWNERS is not false-refused (F45); types KNOWN governance surfaces authoritatively so a directory-only '/<file>/' rule can never certify a protected FILE surface (F46), rejects lookalike substrings standing in for a real governance file (F47), requires the installer's origin-identity remote to be on the GitHub host so a non-GitHub checkout ending in the same owner/repo cannot certify the target (F48), and requires the EFFECTIVE committed CODEOWNERS file (root/docs, not just .github) to own its own path (F49); and — separating class MEMBERSHIP from surface TYPING — reads a bare-name rule as matching the FILE of that name so a later ownerless slashless rule un-owns it instead of being invisible (F50), demands each mandatory class be declared at its CANONICAL path so a same-basename decoy cannot leave the executed checker unprotected (F51), and never lets a descendant entry inherit its directory class's kind, so a directory-only rule cannot certify a FILE beneath a governance directory (F52)"
