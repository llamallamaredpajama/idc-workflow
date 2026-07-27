#!/usr/bin/env python3
"""Validate the IDC pathway-integrity ruleset against the protected acceptance boundary (spec §2.3).

Two modes:

  * LOCAL FILE (default, hermetic, no network):
        idc_ruleset_check.py --ruleset .github/rulesets/idc-pathway-integrity.json
    Validates both the `github_ruleset` payload (the rules GitHub enforces) and the `idc_contract`
    metadata (the protected surfaces IDC additionally requires).

  * LIVE (optional, real `gh`):
        idc_ruleset_check.py --repo OWNER/REPO
    Fetches the installed ruleset named `idc-pathway-integrity` via `gh api` and validates its rules.
    Live rulesets do not carry the `idc_contract` metadata, so the protected-surface check is only
    performed when a local ruleset file is also available (`--ruleset`).

The contract, in both modes:
  * required PR flow (a `pull_request` rule);
  * a required status check whose context is `idc/pathway-integrity`, bound at the EXACT head
    (`strict_required_status_checks_policy: true`);
  * force-push prevention (`non_fast_forward`) and branch-deletion prevention (`deletion`);
  * (file mode) `idc_contract.exact_head` true, `required_check` == the ruleset context, and
    `protected_surfaces` covering the workflow / hook / validation / receipt classes.

Any missing or weakened entry is a refusal (non-zero). Compiles under ambient Python 3.9.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

# THE CREDENTIAL SCRUB DOOR — see `idc_credential_shapes.scrub`. Every read of a CHILD PROCESS's
# stderr in this module passes through it AT THE READ, and `tests/smoke/phase11-honesty-repro.sh` R28
# is the census that keeps that true across every module in scripts/.
#
# THE IMPORT IS TOLERANT BECAUSE SEVERAL MODULES HERE RUN AS LONE RELOCATED COPIES. The smoke and
# governance suites copy a single script to a temp directory and execute it there to prove a deleted
# guard was the one doing the work (`phase1-pipe-safety` F, `governance/external-intake-completeness`,
# `phase4-completion-honesty` F) — a hard sibling import makes those copies die on ImportError. The
# fallback FAILS CLOSED: with no table to scrub with, a child's stderr is WITHHELD, never passed
# through. This block is byte-identical everywhere it appears and R28 asserts that, so no copy of it
# can drift into a pass-through.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import idc_credential_shapes as CS  # noqa: E402
except ImportError:                                      # a lone relocated copy — fail closed
    class CS:                                            # noqa: N801 — stand-in for the shared table
        scrub = staticmethod(
            lambda text: text and "[child output withheld — the credential table is not importable]")

REQUIRED_CHECK = "idc/pathway-integrity"
RULESET_NAME = "idc-pathway-integrity"

DEFAULT_RULESET = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", ".github", "rulesets", "idc-pathway-integrity.json"))

# Each protected-surface CLASS must be represented by at least one entry whose path contains the key.
SURFACE_CLASSES = (
    ("workflow", ".github/workflows"),
    ("hook", "scripts/hooks"),
    ("validation", "valid"),
    ("receipt", "receipt"),
)


def _rule(rules: list, rule_type: str):
    return next((r for r in rules if isinstance(r, dict) and r.get("type") == rule_type), None)


def validate_github_ruleset(gh: dict) -> list:
    """Refusal reasons for the `github_ruleset` payload (the rules GitHub enforces)."""
    reasons = []
    if not isinstance(gh, dict):
        return ["github_ruleset is not an object"]

    rules = gh.get("rules")
    if not isinstance(rules, list):
        return ["github_ruleset.rules is missing or not a list"]

    if gh.get("enforcement") != "active":
        reasons.append("ruleset enforcement is not 'active' (a disabled ruleset enforces nothing)")

    # required PR flow
    if _rule(rules, "pull_request") is None:
        reasons.append("no 'pull_request' rule — pull requests are not required for protected branches")

    # required status check at the exact head
    rsc = _rule(rules, "required_status_checks")
    if rsc is None:
        reasons.append("no 'required_status_checks' rule — the pathway check is not required")
    else:
        params = rsc.get("parameters") or {}
        if params.get("strict_required_status_checks_policy") is not True:
            reasons.append(
                "required_status_checks is not strict (strict_required_status_checks_policy must be "
                "true so the check is bound at the exact, up-to-date head)")
        contexts = params.get("required_status_checks") or []
        names = [c.get("context") for c in contexts if isinstance(c, dict)]
        if REQUIRED_CHECK not in names:
            reasons.append(
                "the required check {!r} is not in required_status_checks (found {})".format(
                    REQUIRED_CHECK, names))

    # force-push + deletion prevention
    if _rule(rules, "non_fast_forward") is None:
        reasons.append("no 'non_fast_forward' rule — force pushes are not prevented")
    if _rule(rules, "deletion") is None:
        reasons.append("no 'deletion' rule — protected-branch deletion is not prevented")

    return reasons


def validate_contract(contract: dict) -> list:
    """Refusal reasons for the IDC `idc_contract` metadata (protected surfaces, exact-head flag)."""
    reasons = []
    if not isinstance(contract, dict):
        return ["idc_contract is not an object"]

    if contract.get("exact_head") is not True:
        reasons.append("idc_contract.exact_head must be true (the check must bind the exact head)")
    if contract.get("required_check") != REQUIRED_CHECK:
        reasons.append(
            "idc_contract.required_check must be {!r} (got {!r})".format(
                REQUIRED_CHECK, contract.get("required_check")))

    surfaces = contract.get("protected_surfaces")
    if not isinstance(surfaces, list) or not surfaces:
        reasons.append("idc_contract.protected_surfaces is missing or empty")
    else:
        for label, key in SURFACE_CLASSES:
            if not any(isinstance(s, str) and key in s for s in surfaces):
                reasons.append(
                    "protected_surfaces does not cover the {} surface (no entry containing "
                    "{!r})".format(label, key))
    return reasons


# CODEOWNERS is looked for at the three locations GitHub honors, in precedence order.
CODEOWNERS_RELPATHS = (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS")


def _read_codeowners(repo_root: str):
    """`(relpath, text)` for the first CODEOWNERS GitHub would honor, or `(None, None)`."""
    for rel in CODEOWNERS_RELPATHS:
        path = os.path.join(repo_root, rel)
        if os.path.isfile(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    return rel, fh.read()
            except OSError:
                return rel, None
    return None, None


def _codeowners_rules(text: str) -> list:
    """Parse CODEOWNERS into `(pattern, owners)` pairs, dropping comments and blank lines."""
    rules = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        pattern = parts[0]
        owners = [tok for tok in parts[1:] if tok.startswith("@") or "@" in tok]
        rules.append((pattern, owners))
    return rules


_WILDCARD_CHARS = ("*", "?", "[")


def _has_wildcard(text: str) -> bool:
    return any(ch in text for ch in _WILDCARD_CHARS)


def _dirname(path: str) -> str:
    return path.rsplit("/", 1)[0] if "/" in path else ""


def _surface_target(surface: str):
    """Reduce a protected-surface entry to what it names, one of:
        ("dir", D)   all files under directory D, recursively   (`D/**`, `D/*`, `D/`, or a bare dir)
        ("file", F)  one exact file
    A bare path is a file when its basename looks like a filename (has a dot), else a directory."""
    text = str(surface).strip().lstrip("/").rstrip()
    for suffix in ("/**", "/*", "/"):
        if text.endswith(suffix):
            return ("dir", text[: -len(suffix)].rstrip("/"))
    base = text.rsplit("/", 1)[-1]
    return ("file", text) if "." in base else ("dir", text)


def _rule_matcher(pattern: str):
    """Classify a CODEOWNERS pattern into a matcher we can reason about at surface granularity, modelling
    GitHub's gitignore-style semantics rather than treating every glob as recursive (F20). Returns:

        ("root",)          every file in the repo, recursively        `*`  `/`  ``  `**`  `/**`
        ("dir_rec", D)     every file under D, recursively            `/D/`  `/D/**`  `D/`  `D/**`  `/D`
        ("dir_one", D)     files DIRECTLY in D only (one level)       `/D/*`  `D/*`  (`/*` -> D="")
        ("suffix", ".ext") any file with that suffix, at any depth    `*.ext`  (slashless)
        ("file", F)        one exact file                             `/path/to/file.ext`
        ("unmodeled", SP)  cannot reduce cleanly; SP = wildcard-free leading directory (fail closed)

    GitHub anchors a pattern containing a non-trailing slash to the repo root; a slashless pattern
    matches at any depth; a single `*` does not cross a `/`. Anything we cannot reduce to a clean
    anchored directory/file (mid-pattern globs, `?`, ranges) is `unmodeled` and handled conservatively
    by the caller so it can never *establish* ownership — only ever fail closed."""
    p = pattern.strip()
    if p in ("", "/", "**", "/**"):
        return ("root",)
    anchored = p.startswith("/") or ("/" in p.rstrip("/"))
    body = p[1:] if p.startswith("/") else p
    if body == "*":
        return ("dir_one", "") if anchored else ("root",)          # `/*` one-level root vs `*` all
    if not anchored and body.startswith("*.") and not _has_wildcard(body[1:]):
        return ("suffix", body[1:])                                 # `*.py` -> ".py"
    if body.endswith("/*") and not _has_wildcard(body[:-2]):
        return ("dir_one", body[:-2].rstrip("/"))
    if body.endswith("/**") and not _has_wildcard(body[:-3]):
        return ("dir_rec", body[:-3].rstrip("/"))
    if body.endswith("/") and not _has_wildcard(body[:-1]):
        return ("dir_rec", body[:-1].rstrip("/"))
    if not _has_wildcard(body):
        base = body.rsplit("/", 1)[-1]
        return ("file", body) if "." in base else ("dir_rec", body.rstrip("/"))
    # Unmodeled: keep the wildcard-free leading DIRECTORY so the caller can decide whether the pattern
    # could plausibly touch the surface (and, if so, fail closed).
    cut = len(body)
    for i, ch in enumerate(body):
        if ch in _WILDCARD_CHARS:
            cut = i
            break
    return ("unmodeled", _dirname(body[:cut]).rstrip("/"))


def _relationship(matcher, target):
    """How a rule matcher relates to a surface target: `covers_all` (every file in the surface is
    matched), `touches` (some but not necessarily all), or `none`. `covers_all` + owner is the only way
    a rule *establishes* whole-surface ownership; `touches` + ownerless carves a hole that defeats it."""
    kind = matcher[0]
    tkind, tpath = target
    if kind == "root":
        return "covers_all"
    if kind == "dir_rec":
        R = matcher[1]
        if R == "" or tpath == R or tpath.startswith(R + "/"):
            return "covers_all"                                    # R is an ancestor-or-self of the surface
        if tkind == "dir" and R.startswith(tpath + "/"):
            return "touches"                                       # R is a strict descendant of the surface dir
        return "none"
    if kind == "dir_one":
        R = matcher[1]
        if tkind == "dir":
            return "touches" if R == tpath else "none"             # one level overlaps only the surface's own dir
        return "covers_all" if _dirname(tpath) == R else "none"    # a file directly in R is fully matched
    if kind == "suffix":
        if tkind == "dir":
            return "touches"                                       # some files under the surface may carry it
        return "covers_all" if tpath.endswith(matcher[1]) else "none"
    if kind == "file":
        F = matcher[1]
        if tkind == "dir":
            return "touches" if F == tpath or F.startswith(tpath + "/") else "none"
        return "covers_all" if F == tpath else "none"
    # unmodeled — locality-scoped, and never `covers_all` (it can only fail closed, never certify).
    SP = matcher[1]
    if SP == "" or tpath == SP or tpath.startswith(SP + "/") or SP.startswith(tpath + "/"):
        return "touches"
    return "none"


def _surface_is_owned(surface: str, rules: list) -> bool:
    """Whether the WHOLE protected surface is owned under GitHub's LAST-MATCH-WINS, glob-aware
    precedence. GitHub applies the *last* matching CODEOWNERS pattern to each file, so whole-surface
    ownership means: some rule owns the whole surface AND no later rule un-owns any part of it.

    We walk rules in file order tracking a single ownership state, mirroring GitHub's per-file
    last-match resolution at surface granularity:
      * a rule that COVERS the whole surface (an ancestor-or-self recursive rule, `*`, or the exact
        file) sets ownership to whether it names an owner;
      * a later rule that only TOUCHES part of the surface and names NO owner carves a hole, so the
        whole surface is no longer owned;
      * a rule that only touches part of the surface WITH an owner is partial — it neither establishes
        nor removes whole-surface ownership.
    Crucially, a NON-recursive one-level rule (`dir/*`, `/*`) does NOT cover a nested subtree, so it
    cannot certify `scripts/hooks/**` off `/scripts/*` or `/*` (F20). Patterns we cannot reduce to a
    clean anchored directory/file are `unmodeled`: they never establish ownership and, when ownerless
    and locally relevant, fail closed by un-owning. The consequence is a fail-closed bias — an exotic
    or one-level CODEOWNERS may be refused with a clear message telling the operator to add an anchored
    recursive rule — never a false-certify."""
    target = _surface_target(surface)
    owned = False
    for pattern, owners in rules:
        rel = _relationship(_rule_matcher(pattern), target)
        if rel == "covers_all":
            owned = bool(owners)
        elif rel == "touches" and not owners:
            owned = False
    return owned


def validate_codeowners(repo_root: str, surfaces) -> list:
    """Refusal reasons for protected-surface ownership: a CODEOWNERS must exist and name an owner for
    every protected surface, so `require_code_owner_review` actually binds a reviewer to each (F6)."""
    rel, text = _read_codeowners(repo_root)
    if rel is None:
        return ["no CODEOWNERS file found (looked at {}) — require_code_owner_review cannot bind a "
                "reviewer to any protected surface".format(", ".join(CODEOWNERS_RELPATHS))]
    if text is None:
        return ["the CODEOWNERS file {} is unreadable".format(rel)]
    rules = _codeowners_rules(text)
    if not rules:
        return ["{} declares no owner rules — every protected surface is unowned".format(rel)]
    reasons = []
    for surface in surfaces or []:
        if isinstance(surface, str) and surface and not _surface_is_owned(surface, rules):
            reasons.append(
                "protected surface {!r} has no code owner in {} — add a CODEOWNERS rule for it".format(
                    surface, rel))
    return reasons


def _gh_json(args: list, repo_flag=None):
    cmd = ["gh"] + args
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("`{}` failed: {}".format(" ".join(cmd), CS.scrub(out.stderr).strip()[:200]))
    return json.loads(out.stdout or "null")


def load_live_ruleset(owner_repo: str) -> dict:
    """Fetch the installed `idc-pathway-integrity` ruleset for OWNER/REPO and return its payload."""
    listing = _gh_json(["api", "repos/{}/rulesets".format(owner_repo)])
    match = next((r for r in (listing or []) if r.get("name") == RULESET_NAME), None)
    if match is None:
        raise RuntimeError(
            "no ruleset named {!r} is installed on {}".format(RULESET_NAME, owner_repo))
    return _gh_json(["api", "repos/{}/rulesets/{}".format(owner_repo, match["id"])])


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate the IDC pathway-integrity ruleset (PR flow, exact-head required check, "
                    "force-push/deletion prevention, protected surfaces).")
    parser.add_argument("--ruleset", default=None,
                        help="path to the ruleset JSON (default: the shipped "
                             ".github/rulesets/idc-pathway-integrity.json)")
    parser.add_argument("--repo", default=None,
                        help="OWNER/REPO — validate the LIVE installed ruleset via `gh api` "
                             "instead of a local file")
    parser.add_argument("--repo-root", default=None,
                        help="repository checkout root — additionally validate that a CODEOWNERS file "
                             "names an owner for every protected surface (F6). When omitted, ownership "
                             "coverage is not checked (the ruleset structure still is).")
    args = parser.parse_args(argv)

    reasons = []
    contract = None
    if args.repo:
        try:
            gh = load_live_ruleset(args.repo)
        except (RuntimeError, ValueError) as exc:
            print("idc-pathway-integrity ruleset: REFUSE (live)")
            print("  - {}".format(exc))
            return 1
        reasons += validate_github_ruleset(gh)
        # protected-surface metadata only lives in the local file; validate it if one is available.
        local = args.ruleset or DEFAULT_RULESET
        if os.path.isfile(local):
            with open(local) as fh:
                doc = json.load(fh)
            contract = doc.get("idc_contract") or {}
            reasons += validate_contract(contract)
        else:
            print("  note: protected-surface metadata not checked (no local ruleset file available)")
    else:
        path = args.ruleset or DEFAULT_RULESET
        if not os.path.isfile(path):
            print("idc-pathway-integrity ruleset: REFUSE")
            print("  - ruleset file not found: {}".format(path))
            return 1
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except ValueError as exc:
            print("idc-pathway-integrity ruleset: REFUSE")
            print("  - ruleset is not valid JSON: {}".format(exc))
            return 1
        if "github_ruleset" not in doc:
            reasons.append("top-level 'github_ruleset' object is missing")
        else:
            reasons += validate_github_ruleset(doc["github_ruleset"])
        if "idc_contract" not in doc:
            reasons.append("top-level 'idc_contract' object is missing")
        else:
            contract = doc["idc_contract"]
            reasons += validate_contract(contract)

    # Protected-surface OWNERSHIP: when a repo root is supplied, a CODEOWNERS must name an owner for
    # every protected surface, or require_code_owner_review binds no reviewer to them (F6).
    if args.repo_root:
        surfaces = (contract or {}).get("protected_surfaces") if isinstance(contract, dict) else None
        reasons += validate_codeowners(args.repo_root, surfaces or [])

    if reasons:
        print("idc-pathway-integrity ruleset: REFUSE")
        for r in reasons:
            print("  - {}".format(r))
        return 1

    print("idc-pathway-integrity ruleset: OK (PR flow, exact-head {} check, force-push/deletion "
          "prevention, protected surfaces)".format(REQUIRED_CHECK))
    return 0


if __name__ == "__main__":
    sys.exit(main())
