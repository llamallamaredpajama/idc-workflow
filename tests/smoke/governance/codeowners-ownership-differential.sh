#!/bin/bash
# idc-assert-class: behavior
# codeowners-ownership-differential.sh — the STRUCTURAL guard for the CODEOWNERS ownership matcher.
#
# WHY THIS EXISTS. The `scripts/idc_ruleset_check.py` ownership classifier has false-certified a
# protected surface FOUR review rounds in a row (F20 x3, F28, F32, F33), each time via a
# hand-enumerated pattern class a human reviewer happened to think of. Hand audits keep leaking. This
# lane STOPS relying on human enumeration: it MECHANICALLY compares the validator's whole-surface
# owned/unowned verdict against an INDEPENDENT oracle — `git check-ignore`, the gitignore-family
# matcher GitHub's CODEOWNERS semantics follow (the same oracle reviewer-5 used to prove F32/F33) —
# across a full grid of pattern classes x surface shapes x {owned, ownerless-override}. Any cell where
# the validator CERTIFIES a surface the oracle leaves unowned FAILS the lane (a false-certify — the
# recurring security bug). Any cell where the validator false-REFUSES a surface the oracle owns, for a
# pattern class it is supposed to model precisely, ALSO fails (a false-refusal — F20 case G was one).
#
# THE ORACLE AND ITS TWO DOCUMENTED DIVERGENCES. `git check-ignore` IS gitignore-family matching, which
# CODEOWNERS inherits — but two GitHub-documented CODEOWNERS exceptions mean raw git check-ignore is a
# SUPERSET matcher, so the oracle applies two corrections, each cited:
#   (1) "the star `*` cannot cross a `/` boundary" — GitHub CODEOWNERS reference ("Example of a
#       CODEOWNERS file": `/apps/logs/* @octocat` owns files "at the root of the repository", not a
#       nested subtree). git check-ignore, once a one-level `*` matches a DIRECTORY name, stops
#       descending and reports every file under it as ignored — over-matching a nested subtree. The
#       oracle corrects a `<dir>/*` (and `/*`) pattern to own EXACTLY the direct children of <dir>.
#   (2) unsupported syntax — GitHub CODEOWNERS reference ("Syntax exceptions"): `!`, `[ ]`, `{ }`, `?`,
#       and `\` are NOT supported. git check-ignore supports `[ ]`/`?`, so it would match patterns
#       CODEOWNERS cannot honor. Such patterns are handled in a SEPARATE fail-closed assertion (the
#       validator must never lean on an unmodeled pattern to certify), not the git-oracle grid.
# A pattern the validator deliberately leaves UNMODELED (a mid-path `**`, unsupported syntax) may
# fail-closed (refuse to certify a surface the oracle owns); that is the intended conservatism (F20),
# recorded as a documented divergence, never a failure. Only false-CERTIFY and a false-refusal of a
# PRECISELY-MODELED class fail the lane.
#
# Red-when-broken: revert the F32 fix (`**/name/` -> file), the F33 fix (bare `/` -> root), or the F46
# fix (an anchored directory-only `/scripts/idc_validation_contract.py/` no longer certifies the FILE
# surface — grid pattern below) in idc_ruleset_check.py and this lane FAILS, reporting the exact
# false-certifying cell. Demonstrated during development against each reverted fix.
#
# Usage: bash tests/smoke/governance/codeowners-ownership-differential.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CHK="$PLUGIN/scripts/idc_ruleset_check.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$CHK" ] || fail "ruleset checker not present: scripts/idc_ruleset_check.py"
command -v git >/dev/null 2>&1 || fail "git is required as the ground-truth matcher oracle"

python3 - "$PLUGIN/scripts" <<'PY'
import os, subprocess, sys, tempfile, shutil

SCRIPTS = sys.argv[1]
sys.path.insert(0, SCRIPTS)
import idc_ruleset_check as RC

# --- the ground-truth git repo: materialize the representative-file universe ---------------------
REPO = tempfile.mkdtemp(prefix="codeowners-diff-")
def _git(*a):
    return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True)
_git("init", "-q", "-b", "main")
_git("config", "core.excludesFile", "/dev/null")     # isolate from any global/user gitignore

# Representative files. The dir surface deliberately carries a NON-.py file so a suffix rule (`*.py`)
# cannot be mistaken for owning the WHOLE directory (a real GitHub gap the validator must respect).
REP_UNIVERSE = [
    "scripts/idc_validation_contract.py",   # the FILE surface itself, and a direct child of scripts/
    "scripts/hooks/gate.py",                # direct .py child of the dir surface
    "scripts/hooks/sub/deep.py",            # NESTED .py under the dir surface
    "scripts/hooks/README.md",              # NON-.py direct child of the dir surface
]
for rel in REP_UNIVERSE:
    ap = os.path.join(REPO, rel)
    os.makedirs(os.path.dirname(ap), exist_ok=True)
    open(ap, "w").close()

# --- gi(): git check-ignore as a SINGLE-pattern matcher, cached per pattern ----------------------
_GI_CACHE = {}
def gi(pattern):
    """Set of REP_UNIVERSE files matched by `pattern` alone, per `git check-ignore` (the gitignore
    oracle). One subprocess per unique pattern."""
    if pattern in _GI_CACHE:
        return _GI_CACHE[pattern]
    with open(os.path.join(REPO, ".gitignore"), "w") as fh:
        fh.write(pattern + "\n")
    out = subprocess.run(["git", "-C", REPO, "check-ignore", *REP_UNIVERSE],
                         capture_output=True, text=True)
    matched = {ln.strip() for ln in out.stdout.splitlines() if ln.strip()}
    _GI_CACHE[pattern] = matched
    return matched

def _one_level_prefix(p):
    """If `p` is a one-level `*` pattern (`/*` or `<prefix>/*` with no other wildcard), return its
    <prefix> (no leading/trailing slash); else None. These are the patterns subject to divergence (1)."""
    p = p.strip()
    if p == "/*":
        return ""
    if p.endswith("/*") and not any(c in p[:-2] for c in "*?["):
        return p[:-2].strip("/")
    return None

def codeowners_matches(pattern, f):
    """Does GitHub CODEOWNERS's matcher match file `f` with `pattern`? git check-ignore, corrected for
    divergence (1): a one-level `*` owns EXACTLY the direct children of its directory (`*` cannot cross
    `/`), never a nested subtree the way git's directory-descent reports."""
    prefix = _one_level_prefix(pattern)
    if prefix is not None:
        parent = f.rsplit("/", 1)[0] if "/" in f else ""
        return parent == prefix
    return f in gi(pattern)

def surface_owned_truth(rep_files, rules):
    """Whole-surface ownership under GitHub last-match-wins over the corrected oracle. `rules` is an
    ordered list of (pattern, has_owner). A surface is fully owned iff every representative file's LAST
    matching pattern names an owner."""
    for f in rep_files:
        matched = False
        last_has_owner = False
        for pattern, has_owner in rules:
            if codeowners_matches(pattern, f):
                matched = True
                last_has_owner = has_owner
        if not matched or not last_has_owner:
            return False
    return True

def validator_owned(surface_decl, rules):
    return RC._surface_is_owned(surface_decl, [(p, ["@team"] if o else []) for p, o in rules])

def expect_precise(p):
    """The validator is expected to model this pattern class PRECISELY (exact agreement with the
    oracle). False for patterns it deliberately leaves unmodeled/fail-closed: unsupported syntax
    (divergence 2) and a MID-path `**` (a reach the surface-granularity matcher cannot bound)."""
    if any(c in p for c in "[]?{}\\!"):
        return False
    core = p
    if core.startswith("**/"):
        core = core[3:]
    if core.endswith("/**"):
        core = core[:-3]
    return "**" not in core

# --- the grid: pattern classes x surface shapes x {owned, ownerless-override} --------------------
# git-check-ignore-faithful patterns (CODEOWNERS-supported syntax; divergence (1) auto-corrected).
PATTERNS = [
    "scripts/hooks/",                       # internal-slash anchored dir (recursive)
    "/scripts/hooks/",                      # leading-slash anchored dir (recursive)
    "/scripts/hooks/**",                    # anchored dir, explicit recursive
    "/scripts/hooks/*",                     # anchored dir, ONE level (divergence 1)
    "/scripts/*",                           # anchored one level under scripts (divergence 1)
    "/*",                                   # root one level (divergence 1)
    "hooks/",                               # SLASHLESS trailing-slash dir, any depth
    "hooks",                                # SLASHLESS bare name, any depth
    "idc_validation_contract.py",           # SLASHLESS dotted basename (file), any depth
    "idc_validation_contract.py/",          # SLASHLESS dotted + TRAILING slash -> dir-only, any depth
    "/scripts/idc_validation_contract.py/", # ANCHORED file path + TRAILING slash -> dir-only (F46)
    "**/idc_validation_contract.py/",       # **/ prefixed + TRAILING slash + dotted -> dir-only (F32)
    "**/hooks",                             # **/ prefixed bare name
    "**/hooks/",                            # **/ prefixed trailing-slash dir
    "**/*.py",                              # **/ prefixed suffix
    "*.py",                                 # suffix, any depth
    "/scripts/idc_validation_contract.py",  # anchored EXACT file
    "*",                                    # root
    "/**",                                  # root (explicit recursive)
    "/",                                    # bare slash -> matches NOTHING (F33)
    "/scripts/**/hooks",                    # MID-path ** -> unmodeled/fail-closed (allowed divergence)
]
SURFACES = [
    ("file", "scripts/idc_validation_contract.py", ["scripts/idc_validation_contract.py"]),
    ("dir",  "scripts/hooks/",
     ["scripts/hooks/gate.py", "scripts/hooks/sub/deep.py", "scripts/hooks/README.md"]),
]

# Assertion directions:
#   * FALSE-CERTIFY (validator owned=True, oracle unowned) — the recurring security bug — is checked
#     in EVERY cell, owned and ownerless-override alike (F20 E/F are ownerless-override false-certifies).
#   * FALSE-REFUSE (validator owned=False, oracle owns) is checked ONLY in the OWNED direction, where a
#     precisely-modeled class must certify (F20 case G was a false-refusal here). It is NOT asserted in
#     the ownerless-override direction: there the validator is deliberately filesystem-BLIND at surface
#     granularity — a slashless-file or unmodeled ownerless rule that COULD carve an interior hole in a
#     directory fail-closed un-owns it, even though no concrete file falls in the hole. That is the safe
#     (never-false-certify) direction, recorded as a conservative un-own, never a failure.
failures = []
divergences = []
conservative = 0
cells = 0
for pattern in PATTERNS:
    precise = expect_precise(pattern)
    for skind, sdecl, reps in SURFACES:
        for mode, rules in (
            ("owned",    [(pattern, True)]),
            ("ownerless-override", [("*", True), (pattern, False)]),
        ):
            cells += 1
            truth = surface_owned_truth(reps, rules)
            got = validator_owned(sdecl, rules)
            cell = f"[{skind} surface {sdecl!r}] pattern {pattern!r} ({mode})"
            if got and not truth:
                failures.append(f"FALSE-CERTIFY {cell}: validator owned=True but the oracle leaves the "
                                f"surface UNOWNED (a false-certify — the recurring bug class)")
            elif (not got) and truth:
                if mode == "owned" and precise:
                    failures.append(f"FALSE-REFUSE {cell}: validator owned=False but the oracle OWNS "
                                    f"the surface, for a precisely-modeled pattern class (false-refusal)")
                elif mode == "owned":
                    divergences.append(f"{cell}: validator fails closed (owned=False) on an unmodeled "
                                       f"pattern the oracle owns — intended conservatism")
                else:
                    conservative += 1   # ownerless-override fail-closed un-own — safe, expected

# --- divergence (2): unsupported syntax must fail closed, never certify --------------------------
# git check-ignore supports `[ ]`/`?`; CODEOWNERS does not (cited above). The validator must refuse to
# certify a surface reachable only through such a pattern — asserted directly, not via the git oracle,
# because git-check-ignore is not a faithful CODEOWNERS oracle for these.
UNSUPPORTED = ["scripts/hooks/[a-z]*.py", "scripts/hooks/gate?.py", "scripts/hook{s,z}/"]
for pattern in UNSUPPORTED:
    got = validator_owned("scripts/hooks/", [(pattern, True)])
    if got:
        failures.append(f"UNSUPPORTED-SYNTAX-CERTIFY: validator certified scripts/hooks/ off {pattern!r}, "
                        f"a pattern CODEOWNERS does not support — it must fail closed")
    else:
        divergences.append(f"[dir surface 'scripts/hooks/'] pattern {pattern!r} (owned): validator fails "
                           f"closed on CODEOWNERS-unsupported syntax (git check-ignore would match it)")

shutil.rmtree(REPO, ignore_errors=True)

print(f"differential grid: {cells} git-oracle cells + {len(UNSUPPORTED)} unsupported-syntax cells "
      f"({conservative} ownerless-override fail-closed un-owns — safe)")
if divergences:
    print("documented git-check-ignore vs CODEOWNERS divergences (validator correctly fails closed):")
    for d in divergences:
        print("  ~ " + d)
if failures:
    print("DIFFERENTIAL FAILURES:")
    for f in failures:
        print("  X " + f)
    sys.exit(1)
print("ok: across every grid cell the validator never certifies a surface the oracle leaves unowned, "
      "and never false-refuses a precisely-modeled owned surface")
PY
rc=$?
[ "$rc" -eq 0 ] || fail "the CODEOWNERS ownership matcher disagrees with the git check-ignore oracle (see above)"

echo "PASS: the CODEOWNERS ownership classifier agrees with the git check-ignore ground-truth matcher across the full pattern-class x surface x owned/ownerless grid — no false-certify, no precise-class false-refusal (F20/F28/F32/F33 structural guard)"
