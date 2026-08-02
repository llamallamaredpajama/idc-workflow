#!/bin/bash
# idc-assert-class: behavior
# ruleset-validator-completeness.sh — F38 + F41 + F49: the validator must check what it certifies.
#
# Three completeness holes, all of the same species (a green line claiming a property nothing
# verified):
#
#   F38  `validate_github_ruleset` asserted only the PRESENCE of a `pull_request` rule and never read
#        its parameters, so a ruleset with `require_code_owner_review: false` (or absent) passed —
#        the ONE flag every CODEOWNERS/ownership gate downstream exists to make meaningful.
#        `bypass_actors` was likewise never read, so a ruleset granting an actor a full bypass of
#        every rule certified as protection.
#
#   F41  `--repo` live mode with a MISSING local ruleset file left `contract=None`; with
#        `--repo-root` given, the ownership check then ran against an EMPTY surface list and the
#        module printed `OK (... protected surfaces)` having validated NONE — a vacuous green over
#        the one check the caller explicitly asked for.
#
#   F49  a CODEOWNERS line carrying a valid owner PLUS a syntax-invalid token kept the valid owner —
#        but GitHub documents that a line containing invalid syntax is SKIPPED ENTIRELY, so
#        `* @alice docs@` binds NOBODY on GitHub while the checker certified every surface off it.
#        One typo, no adversary needed.
#
# Red-when-broken:
#   * drop the require_code_owner_review check -> (1a) certifies a ruleset with the flag off;
#   * drop the bypass_actors check             -> (1b) certifies a ruleset with a bypass actor;
#   * drop main()'s F41 elif branch            -> (2a)'s guarded run prints the vacuous OK (rc=0);
#   * restore drop-the-bad-token parsing       -> (3a)'s guarded run certifies off `* @alice docs@`.
#
# Usage: bash tests/smoke/governance/ruleset-validator-completeness.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CHK="$PLUGIN/scripts/idc_ruleset_check.py"
RS="$PLUGIN/.github/rulesets/idc-pathway-integrity.json"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$CHK" ] || fail "missing checker: scripts/idc_ruleset_check.py"
[ -f "$RS" ]  || fail "missing ruleset: .github/rulesets/idc-pathway-integrity.json"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
. "$(dirname "$0")/../lib/fail-closed.sh"

# --- (1) F38: require_code_owner_review + bypass_actors are validated, not assumed ------------------

mk_weakened() {  # $1=out.json  $2=python mutation over doc (the shipped ruleset, parsed)
  python3 - "$RS" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(doc, open(sys.argv[2], "w"))
PY
}

# (1a) require_code_owner_review flipped OFF -> REFUSE naming the flag; absent -> same.
for mutation in \
  'doc["github_ruleset"]["rules"][0]["parameters"]["require_code_owner_review"] = False' \
  'del doc["github_ruleset"]["rules"][0]["parameters"]["require_code_owner_review"]'; do
  mk_weakened "$WORK/weak-rcor.json" "$mutation" || fail "1a fixture: could not weaken the ruleset"
  # Fixture realness: the weakened file must genuinely lack the true flag.
  python3 - "$WORK/weak-rcor.json" <<'PY' || fail "1a fixture: the weakened ruleset still sets require_code_owner_review true"
import json, sys
p = json.load(open(sys.argv[1]))["github_ruleset"]["rules"][0]["parameters"]
sys.exit(0 if p.get("require_code_owner_review") is not True else 1)
PY
  assert_fail_closed "1a: a ruleset without require_code_owner_review must refuse (F38)" \
    "require_code_owner_review is not true" \
    -- python3 "$CHK" --ruleset "$WORK/weak-rcor.json" \
    -- python3 "$CHK" --ruleset "$RS"
done
# ...and the pull_request rule with NO parameters object at all also refuses (not a KeyError, not a pass).
mk_weakened "$WORK/weak-noparams.json" 'del doc["github_ruleset"]["rules"][0]["parameters"]' \
  || fail "1a fixture: could not strip the pull_request parameters"
assert_fail_closed "1a: a pull_request rule with no parameters must refuse (F38)" \
  "no parameters object" \
  -- python3 "$CHK" --ruleset "$WORK/weak-noparams.json" \
  -- python3 "$CHK" --ruleset "$RS"

# (1b) a NON-EMPTY bypass_actors list -> REFUSE naming the bypass; a malformed (non-list) one -> REFUSE.
mk_weakened "$WORK/weak-bypass.json" \
  'doc["github_ruleset"]["bypass_actors"] = [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}]' \
  || fail "1b fixture: could not add a bypass actor"
assert_fail_closed "1b: a ruleset granting a bypass actor must refuse (F38)" \
  "bypass_actors names 1 actor" \
  -- python3 "$CHK" --ruleset "$WORK/weak-bypass.json" \
  -- python3 "$CHK" --ruleset "$RS"
mk_weakened "$WORK/weak-bypass-shape.json" 'doc["github_ruleset"]["bypass_actors"] = "none"' \
  || fail "1b fixture: could not malform bypass_actors"
assert_fail_closed "1b: a malformed bypass_actors must refuse, never read as empty (F38)" \
  "not a list" \
  -- python3 "$CHK" --ruleset "$WORK/weak-bypass-shape.json" \
  -- python3 "$CHK" --ruleset "$RS"
# Control: an explicitly EMPTY list is fine (the live API reports [] on a clean ruleset).
mk_weakened "$WORK/ok-bypass-empty.json" 'doc["github_ruleset"]["bypass_actors"] = []' \
  || fail "1b fixture: could not set an empty bypass_actors"
python3 "$CHK" --ruleset "$WORK/ok-bypass-empty.json" >/dev/null 2>&1 \
  || fail "1b control: an EMPTY bypass_actors list was refused — the check must catch grants, not the field"

# --- (2) F41: live mode must not vacuously certify ownership without a surface list -----------------

# A canned gh serving the SHIPPED ruleset as the live installed one (paged listing + detail), so the
# live half genuinely succeeds and only the local-file half varies.
LIVE_STUB="$WORK/live-stub"; mkdir -p "$LIVE_STUB"
python3 - "$RS" "$LIVE_STUB" <<'PY' || fail "2 fixture: could not build the live stub bodies"
import json, sys
doc = json.load(open(sys.argv[1]))
json.dump([{"id": 4242, "name": "idc-pathway-integrity"}], open(sys.argv[2] + "/page1.json", "w"))
json.dump(doc["github_ruleset"], open(sys.argv[2] + "/detail.json", "w"))
PY
cat > "$LIVE_STUB/gh" <<'STUB'
#!/bin/sh
case "$2" in
  *"&page=1") cat "$STUB_PAGES/page1.json" ;;
  *"&page="*) echo '[]' ;;
  */rulesets/4242) cat "$STUB_PAGES/detail.json" ;;
  *) echo "stub: unexpected gh api path: $2" >&2; exit 1 ;;
esac
STUB
chmod +x "$LIVE_STUB/gh"
# Stub self-check: the live read really certifies when a local ruleset IS available.
out="$(PATH="$LIVE_STUB:$PATH" STUB_PAGES="$LIVE_STUB" python3 "$CHK" --ruleset "$RS" \
        --repo "idc-stub-owner/idc-stub-target" --repo-root "$PLUGIN" 2>&1)" \
  || fail "2 stub self-check: live mode with a local ruleset + this repo's CODEOWNERS did not certify; got: $out"

# A repo-root whose CODEOWNERS is EMPTY of rules — so if the ownership loop runs with real surfaces
# it must refuse, and the ONLY way the guarded run below could go green is the F41 vacuous path.
TGT_BARE="$WORK/tgt-bare"; mkdir -p "$TGT_BARE/.github"
printf '# no rules at all\n' > "$TGT_BARE/.github/CODEOWNERS"

# (2a) live + --repo-root + NO local ruleset -> REFUSE (the surface list is unavailable), not OK.
assert_fail_closed "2a: live mode with --repo-root and no local ruleset must refuse, not certify zero surfaces (F41)" \
  "certify vacuously (F41)" \
  -- env PATH="$LIVE_STUB:$PATH" STUB_PAGES="$LIVE_STUB" python3 "$CHK" \
       --ruleset "$WORK/no-such-ruleset.json" --repo "idc-stub-owner/idc-stub-target" --repo-root "$TGT_BARE" \
  -- env PATH="$LIVE_STUB:$PATH" STUB_PAGES="$LIVE_STUB" python3 "$CHK" \
       --ruleset "$RS" --repo "idc-stub-owner/idc-stub-target" --repo-root "$PLUGIN"

# (2b) the same missing-file live run WITHOUT --repo-root still passes (the structural rules were
#      validated live) but its OK line must SAY ownership was not checked — never claim it.
out="$(PATH="$LIVE_STUB:$PATH" STUB_PAGES="$LIVE_STUB" python3 "$CHK" \
        --ruleset "$WORK/no-such-ruleset.json" --repo "idc-stub-owner/idc-stub-target" 2>&1)" \
  || fail "2b: live mode without --repo-root should still validate the structural rules; got: $out"
printf '%s\n' "$out" | grep -Fq "protected surfaces NOT checked" \
  || fail "2b: the OK line must disclose that protected surfaces were NOT checked; got: $out"

# --- (3) F49: an invalid owner token voids its LINE, exactly as GitHub skips it ---------------------

mk_owned() {  # $1=dir  $2=the CODEOWNERS content
  rm -rf "$1"; mkdir -p "$1/.github"
  printf '%s\n' "$2" > "$1/.github/CODEOWNERS"
}

# (3a) `* @alice docs@` — a covering rule with one typo'd token — must certify NOTHING.
mk_owned "$WORK/tgt-typo" '* @alice docs@'
mk_owned "$WORK/tgt-clean" '* @alice'
assert_fail_closed "3a: a covering line carrying a syntax-invalid token must not certify (GitHub skips the whole line — F49)" \
  "has no code owner in" \
  -- python3 "$CHK" --ruleset "$RS" --repo-root "$WORK/tgt-typo" \
  -- python3 "$CHK" --ruleset "$RS" --repo-root "$WORK/tgt-clean"

# (3b) the parser-level contract, pinned: a mixed line yields NO owners; an all-valid line keeps
#      them; a deliberately OWNERLESS line (valid un-own syntax) is untouched.
python3 - "$PLUGIN/scripts" <<'PY' || fail "3b: the F49 whole-line parse contract does not hold"
import sys
sys.path.insert(0, sys.argv[1])
import idc_ruleset_check as RC
import idc_ruleset_install as INS

mixed = RC._codeowners_rules("docs/** @alice docs@\n")
if mixed != [("docs/**", [])]:
    print("MIXED-LINE-KEPT-OWNERS: %r — GitHub skips the whole line, so keeping @alice certifies "
          "a surface GitHub leaves unowned (F49)" % (mixed,)); sys.exit(1)
clean = RC._codeowners_rules("docs/** @alice @acme/reviewers dev@example.com\n")
if clean != [("docs/**", ["@alice", "@acme/reviewers", "dev@example.com"])]:
    print("VALID-LINE-BROKEN: %r" % (clean,)); sys.exit(1)
unown = RC._codeowners_rules("docs/generated/\n")
if unown != [("docs/generated/", [])]:
    print("UNOWN-LINE-BROKEN: %r — a pattern with no tokens is valid GitHub syntax" % (unown,)); sys.exit(1)
# and the installer's principal enumeration sees NO principal from a voided line, so the live
# verification cannot green-light a token GitHub never binds.
toks = INS._distinct_owner_tokens("* @alice docs@\n/scripts/ @bob\n")
if toks != ["@bob"]:
    print("VOIDED-LINE-LEAKED-PRINCIPAL: %r" % (toks,)); sys.exit(1)
print("3b ok: mixed lines void, valid lines keep owners, un-own lines survive, principals follow")
PY

echo "PASS: the validator checks what it certifies (F38/F41/F49) — require_code_owner_review must be true and bypass_actors empty (a weakened or malformed ruleset refuses while the shipped one passes), live mode with --repo-root refuses when no local ruleset supplies the protected-surface list instead of vacuously certifying zero surfaces (and without --repo-root the OK line discloses ownership was NOT checked), and a CODEOWNERS line carrying any syntax-invalid owner token binds nothing — exactly as GitHub skips the line — in the checker's ownership walk and the installer's principal enumeration alike"
