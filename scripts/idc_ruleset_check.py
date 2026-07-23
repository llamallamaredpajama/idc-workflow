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
    args = parser.parse_args(argv)

    reasons = []
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
            reasons += validate_contract(doc.get("idc_contract") or {})
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
            reasons += validate_contract(doc["idc_contract"])

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
