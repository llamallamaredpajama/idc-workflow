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


def _normalize_owned_path(value: str) -> str:
    """A surface glob / CODEOWNERS pattern reduced to a comparable repo-relative directory-or-file."""
    text = str(value).strip().lstrip("/")
    for suffix in ("/**", "/*"):
        if text.endswith(suffix):
            text = text[: -len(suffix)]
    return text.rstrip("/")


def _surface_is_owned(surface: str, rules: list) -> bool:
    """Whether the WHOLE protected surface is owned: some CODEOWNERS entry with >=1 owner is the
    surface itself or an ancestor directory of it (a deeper pattern owns only part, so it does not
    count). A root pattern (`*` / `/`) owns everything."""
    target = _normalize_owned_path(surface)
    for pattern, owners in rules:
        if not owners:
            continue
        owned = _normalize_owned_path(pattern)
        if owned in ("", "*"):
            return True
        if target == owned or target.startswith(owned + "/"):
            return True
    return False


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
