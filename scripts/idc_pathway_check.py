#!/usr/bin/env python3
"""Deterministic `idc/pathway-integrity` integration check (spec §2.3).

This is the fixed checker the version-pinned `.github/workflows/idc-pathway-integrity.yml` runs on
every pull request. It emits a single verdict — no LLM, no arbitrary generated script, no network
beyond the git checkout CI already provides. It PASSES only when three things hold together, and
REFUSES (non-zero) otherwise:

  1. EXACT HEAD — the proposed head SHA the check was asked to bind to equals the repository HEAD the
     checkout actually landed on. A stale head (the check ran against an older commit than the one a
     merge would land) is refused. This is the "required check at the exact proposed head commit"
     guarantee: the workflow passes `--head ${{ github.event.pull_request.head.sha }}` and checks out
     that same SHA, so a mismatch means the binding was tampered with or the checkout drifted.
  2. PINNED SOURCE — the check source the workflow presents (`--source`) equals the version-pinned
     expected source. Substituting a wrong or stale source (a forged/renamed check, or an old pinned
     revision) is refused. In `app-locked` repositories this is the "expected check source" pin.
  3. PROTECTED SURFACES — every IDC integrity surface (the pathway workflow, the hook surface, the
     validation surface, and the receipt surface) is present in the repository. Their presence is the
     structural evidence that the governance machinery a merge relies on has not been stripped out.

The checker is intentionally structural and deterministic so it is honestly green on the governed IDC
source repository itself (this repo IS governed by the run's own receipts) while going red the moment
any binding or protected surface is weakened. It does not re-run the whole IDC lifecycle — the smoke
suite does that; this check guards the *integration boundary*.

Compiles under the repo's ambient Python 3.9 (`from __future__ import annotations`).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

CHECK_NAME = "idc/pathway-integrity"

# The pathway contract is version-pinned; the workflow must present exactly this source token, and the
# ruleset pins the required check to the same name. Bumping the contract is a deliberate, reviewed act.
PATHWAY_CONTRACT_VERSION = 1
EXPECTED_CHECK_SOURCE = "idc/pathway-integrity@v{}".format(PATHWAY_CONTRACT_VERSION)

# The IDC integrity surfaces a merge depends on. A file OR a directory satisfies each entry; the point
# is that the machinery exists in the tree the check bound to. Keep these aligned with the ruleset's
# `idc_contract.protected_surfaces` (workflow / hook / validation / receipt classes).
PROTECTED_SURFACES = (
    ".github/workflows/idc-pathway-integrity.yml",  # workflow surface
    "scripts/hooks",                                # hook surface (directory)
    "scripts/idc_validation_contract.py",           # validation surface
    "scripts/idc_receipt_check.py",                 # receipt surface
    "scripts/idc_pathway_check.py",                 # the checker itself
)

_HEX = set("0123456789abcdef")


def _is_hex(value: str) -> bool:
    return bool(value) and all(c in _HEX for c in value.lower())


def _sha_matches(proposed: str, actual: str) -> bool:
    """Exact-head equality, tolerating an abbreviated (>=7 hex) proposed SHA."""
    p, a = proposed.strip().lower(), actual.strip().lower()
    if not p or not a:
        return False
    if p == a:
        return True
    # Only accept a prefix match when both are hex and the shorter is a real abbreviation.
    if _is_hex(p) and _is_hex(a) and len(p) >= 7 and (a.startswith(p) or p.startswith(a)):
        return True
    return False


def _repo_head(repo: str) -> str | None:
    try:
        out = subprocess.run(
            ["git", "-C", repo, "rev-parse", "HEAD"],
            capture_output=True, text=True,
        )
    except OSError:
        return None
    if out.returncode != 0:
        return None
    head = out.stdout.strip()
    return head or None


def check(repo: str, head: str, source: str, expected_source: str,
          surfaces: tuple) -> list:
    """Return a list of refusal reasons (empty list = the check passes)."""
    reasons = []

    # 1. exact head
    if not head.strip():
        reasons.append("no proposed head SHA was bound (--head is empty) — the check is unpinned")
    else:
        actual = _repo_head(repo)
        if actual is None:
            reasons.append(
                "could not resolve the repository HEAD (is {!r} a git checkout?)".format(repo))
        elif not _sha_matches(head, actual):
            reasons.append(
                "stale head: the check bound to {} but the repository HEAD is {} — the check did not "
                "run at the exact proposed head".format(head.strip(), actual))

    # 2. pinned source
    if source.strip() != expected_source.strip():
        reasons.append(
            "wrong check source: got {!r}, expected the version-pinned {!r}".format(
                source.strip(), expected_source.strip()))

    # 3. protected surfaces present
    for surface in surfaces:
        if not os.path.exists(os.path.join(repo, surface)):
            reasons.append("missing protected surface: {}".format(surface))

    return reasons


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Deterministic idc/pathway-integrity integration check (exact head + pinned "
                    "source + protected surfaces).")
    parser.add_argument("--repo", default=".",
                        help="repository checkout to check (default: current directory)")
    parser.add_argument("--head", required=True,
                        help="the exact proposed head SHA the check binds to "
                             "(github.event.pull_request.head.sha)")
    parser.add_argument("--source", required=True,
                        help="the check source identity the workflow presents")
    parser.add_argument("--expected-source", default=EXPECTED_CHECK_SOURCE,
                        help="the version-pinned source the check must equal "
                             "(default: %(default)s)")
    parser.add_argument("--surface", action="append", default=None,
                        help="override the protected-surface set (repeatable); default is the "
                             "built-in IDC integrity surfaces")
    args = parser.parse_args(argv)

    surfaces = tuple(args.surface) if args.surface else PROTECTED_SURFACES
    reasons = check(args.repo, args.head, args.source, args.expected_source, surfaces)

    if reasons:
        print("{}: REFUSE".format(CHECK_NAME))
        for r in reasons:
            print("  - {}".format(r))
        return 1

    print("{}: PASS (head bound, source {} pinned, {} protected surfaces present)".format(
        CHECK_NAME, args.expected_source.strip(), len(surfaces)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
