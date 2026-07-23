#!/usr/bin/env python3
"""Install / update the IDC pathway-integrity ruleset on a repository, idempotently.

Reads `.github/rulesets/idc-pathway-integrity.json`, validates it (never installs a weakened
ruleset), and applies the `github_ruleset` payload via `gh api`. It creates the ruleset if absent and
updates it in place if a ruleset of the same name already exists.

SAFETY — this tool mutates repository protection rules, so it is deliberately hard to fire by
accident:
  * `--repo OWNER/REPO` is REQUIRED. There is no implicit "current repository" default, so it can
    never silently mutate wherever you happen to be standing.
  * Nothing is applied without `--apply`. The default is a DRY-RUN that prints exactly what would be
    installed and touches nothing.
  * A built-in denylist refuses `--apply` against known production repositories, before any network
    call.

Live sandbox use (the only repos this run may mutate) is gated further by the caller — see
`tests/live/pathway-github-integration.sh`, which refuses anything but a disposable sandbox.

Compiles under ambient Python 3.9.
"""
from __future__ import annotations

import argparse
import json
import os
import re
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

import idc_ruleset_check as RC  # noqa: E402 — sibling checker; reuse its validation

RULESET_NAME = "idc-pathway-integrity"

# Repositories this installer must never mutate, even with --apply. Defense in depth: the live test
# also refuses anything but a disposable sandbox. The production source repo of this very plugin is
# the one an in-run agent is most likely to be standing next to, so it is named explicitly.
PROTECTED_REPOS = frozenset({
    "llamallamaredpajama/idc-workflow",
})

_REPO_RE = re.compile(r"^[^/\s]+/[^/\s]+$")


def _load_payload(ruleset_path: str):
    with open(ruleset_path) as fh:
        doc = json.load(fh)
    gh = doc.get("github_ruleset")
    contract = doc.get("idc_contract") or {}
    reasons = []
    if gh is None:
        reasons.append("top-level 'github_ruleset' object is missing")
    else:
        reasons += RC.validate_github_ruleset(gh)
    reasons += RC.validate_contract(contract)
    return doc, gh, reasons


def _gh_json(args: list):
    out = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("`gh {}` failed: {}".format(" ".join(args), CS.scrub(out.stderr).strip()[:200]))
    return json.loads(out.stdout or "null")


def _existing_ruleset_id(owner_repo: str):
    listing = _gh_json(["api", "repos/{}/rulesets".format(owner_repo)])
    match = next((r for r in (listing or []) if r.get("name") == RULESET_NAME), None)
    return match["id"] if match else None


def _plan_lines(gh: dict, owner_repo: str, apply: bool) -> list:
    rules = [r.get("type") for r in gh.get("rules", []) if isinstance(r, dict)]
    checks = []
    for r in gh.get("rules", []):
        if isinstance(r, dict) and r.get("type") == "required_status_checks":
            checks = [c.get("context") for c in (r.get("parameters") or {}).get(
                "required_status_checks", []) if isinstance(c, dict)]
    return [
        "{} ruleset {!r} on {}".format("APPLY:" if apply else "DRY-RUN:", RULESET_NAME, owner_repo),
        "  target:        {}".format(gh.get("target")),
        "  enforcement:   {}".format(gh.get("enforcement")),
        "  rules:         {}".format(", ".join(rules)),
        "  required check: {}".format(", ".join(checks) or "(none)"),
    ]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Install/update the IDC pathway-integrity ruleset (idempotent; dry-run by "
                    "default).")
    parser.add_argument("--repo", default=None,
                        help="OWNER/REPO to install the ruleset on (REQUIRED — no implicit default)")
    parser.add_argument("--ruleset", default=RC.DEFAULT_RULESET,
                        help="path to the ruleset JSON (default: the shipped one)")
    parser.add_argument("--apply", action="store_true",
                        help="actually create/update the ruleset (default: dry-run, touches nothing)")
    args = parser.parse_args(argv)

    if not args.repo:
        print("REFUSE: --repo OWNER/REPO is required — this tool never guesses the target "
              "repository", file=sys.stderr)
        return 2
    if not _REPO_RE.match(args.repo):
        print("REFUSE: --repo {!r} is not OWNER/REPO".format(args.repo), file=sys.stderr)
        return 2

    if not os.path.isfile(args.ruleset):
        print("REFUSE: ruleset file not found: {}".format(args.ruleset), file=sys.stderr)
        return 2
    try:
        doc, gh, reasons = _load_payload(args.ruleset)
    except ValueError as exc:
        print("REFUSE: ruleset is not valid JSON: {}".format(exc), file=sys.stderr)
        return 2
    if reasons:
        print("REFUSE: ruleset fails its own contract — refusing to install a weakened ruleset:",
              file=sys.stderr)
        for r in reasons:
            print("  - {}".format(r), file=sys.stderr)
        return 1

    # Production-repo guard runs BEFORE any network call.
    if args.apply and args.repo in PROTECTED_REPOS:
        print("REFUSE: {} is a protected production repository — this installer will not mutate its "
              "rulesets".format(args.repo), file=sys.stderr)
        return 3

    for line in _plan_lines(gh, args.repo, args.apply):
        print(line)

    if not args.apply:
        print("(dry-run: pass --apply to create/update; nothing was changed)")
        return 0

    # Live mutation — idempotent: PUT to update an existing same-name ruleset, else POST to create.
    try:
        existing = _existing_ruleset_id(args.repo)
    except (RuntimeError, ValueError) as exc:  # pragma: no cover — requires live gh
        print("REFUSE: {}".format(exc), file=sys.stderr)
        return 1

    if existing is None:
        method, endpoint, action = "POST", "repos/{}/rulesets".format(args.repo), "created"
    else:
        method, endpoint, action = "PUT", "repos/{}/rulesets/{}".format(
            args.repo, existing), "updated"

    # `gh api --input -` reads the JSON payload from stdin.
    try:
        proc = subprocess.run(
            ["gh", "api", "--method", method, endpoint, "--input", "-"],
            input=json.dumps(gh), capture_output=True, text=True)
    except OSError as exc:  # pragma: no cover — requires live gh
        print("REFUSE: could not invoke gh: {}".format(exc), file=sys.stderr)
        return 1
    if proc.returncode != 0:
        print("REFUSE: gh api {} {} failed: {}".format(method, endpoint, CS.scrub(proc.stderr).strip()[:200]),
              file=sys.stderr)
        return 1

    print("OK: ruleset {!r} {} on {}".format(RULESET_NAME, action, args.repo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
