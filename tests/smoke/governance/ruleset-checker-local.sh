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

echo "PASS: ruleset checker enforces PR flow, exact-head required check, force-push/deletion prevention, all seven protected surfaces (incl. the F40 governance-of-governance set: the checker, the ruleset dir, and CODEOWNERS itself), GitHub any-depth/last-match-wins ownership with a strict class allowlist that fails closed on unmodeled patterns, re-types a dotted-basename DIRECTORY surface off the file guess so an interior ownerless hole cannot false-certify (F28), treats a '**/name/' trailing-slash pattern as directory-only (F32) and a bare '/' as matching-nothing (F33), and counts only valid owner tokens so a bare '@' cannot false-certify (F41); installer refuses without --repo, refuses a production repo, requires --repo-root, BINDS it to --repo via a local origin-identity check (F34), and validates the CODEOWNERS COMMITTED on the default branch — refusing an uncommitted or working-tree-diverged copy (F39)"
