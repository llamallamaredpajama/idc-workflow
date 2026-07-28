#!/usr/bin/env python3
"""Deterministic `idc/pathway-integrity` integration check — the STRUCTURAL leg of spec §2.3.

This is the fixed checker the version-pinned `.github/workflows/idc-pathway-integrity.yml` runs on
every pull request. It emits a single verdict — no LLM, no arbitrary generated script, no network
beyond the git checkout CI already provides. It PASSES only when three things hold together, and
REFUSES (non-zero) otherwise:

  1. EXACT HEAD — the proposed head SHA the check was asked to bind to equals the repository HEAD the
     checkout actually landed on. A stale head (the check ran against an older commit than the one a
     merge would land) is refused. This is the "required check at the exact proposed head commit"
     guarantee: the workflow passes `--head ${{ github.event.pull_request.head.sha }}` and checks out
     that same SHA, so a mismatch means the binding was tampered with or the checkout drifted. Only a
     FULL, exact SHA match is accepted — an abbreviated prefix is refused.
  2. PINNED SOURCE — the check source the workflow presents (`--source`) equals the version-pinned
     expected source. Substituting a wrong or stale source (a forged/renamed check, or an old pinned
     revision) is refused. In `app-locked` repositories this is the "expected check source" pin.
  3. PROTECTED SURFACES — every IDC integrity surface (the pathway workflow, the hook surface, the
     validation surface, the receipt surface, and the governance-of-governance surfaces: this
     checker, the ruleset directory and CODEOWNERS) is present AND carries content (not a gutted
     empty stub or an emptied directory). Their presence-with-content is the structural evidence that
     the governance machinery a merge relies on has not been stripped out.

SCOPE — WHAT THIS CHECK DOES *NOT* DO. Spec §2.3 requires that a merge be refused when tracker,
graph, journal, authorization, validation, review, or finish evidence is missing, stale, corrupt, or
divergent. This deterministic, head-bound checker does NOT — and cannot — evaluate those live
evidence classes: they depend on the tracker board, the git-directory receipts, and the review/gate
state at merge time, not on a static checkout. That evidence-bound merge refusal is owned by the
mechanisms that hold the evidence — the finisher/gate receipts (`idc_build_receipt.py`,
`idc_validation_contract.py`, the review-verdict chain) and the ruleset's review/ownership rules
(`require_code_owner_review` + CODEOWNERS, enforced by `idc_ruleset_check.py`). This check guards the
narrower *structural* integration boundary: the exact-head binding, the pinned source, and the
presence-with-content of the protected surfaces. The published contract is exactly that — no more.

For the checker itself to be trustworthy the workflow runs it from a TRUSTED (base-ref) copy, not the
PR-head copy it is judging, so a PR cannot weaken the judge; see the workflow header.

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
# is that the machinery exists in the tree the check bound to. These are kept aligned with the
# ruleset's `idc_contract.protected_surfaces` (workflow / hook / validation / receipt classes, plus
# the governance-of-governance surfaces) — and that alignment is no longer just a comment: the
# governance lane `tests/smoke/governance/pathway-check-surface-alignment.sh` reds when the two lists
# diverge. (F61: the ruleset declared seven surfaces while this tuple guarded five, so a tree with
# `.github/CODEOWNERS` and the whole `.github/rulesets/` directory deleted still passed the required
# check while the docstring claimed the lists matched.)
PROTECTED_SURFACES = (
    ".github/workflows/idc-pathway-integrity.yml",  # workflow surface
    "scripts/hooks",                                # hook surface (directory)
    "scripts/idc_validation_contract.py",           # validation surface
    "scripts/idc_receipt_check.py",                 # receipt surface
    "scripts/idc_pathway_check.py",                 # the checker itself
    ".github/rulesets",                             # the ruleset directory (directory)
    ".github/CODEOWNERS",                           # the ownership surface the review rules lean on
)

def _sha_matches(proposed: str, actual: str) -> bool:
    """Exact-head equality — a FULL, exact SHA match only.

    An abbreviated hex prefix is deliberately refused: the ruleset pins this check at the exact
    proposed head, so a merge must bind the whole commit id the checker verified. Accepting a >=7-char
    prefix would let a merge land a commit the check never pinned in full (two commits can share a
    short prefix, and the workflow always passes the complete `github.event.pull_request.head.sha`)."""
    p, a = proposed.strip().lower(), actual.strip().lower()
    return bool(p) and bool(a) and p == a


def _surface_has_content(path: str) -> bool:
    """Whether a protected surface carries content, not just a path. A file must be non-empty; a
    directory must hold at least one non-empty regular file. This turns the surface check from mere
    existence into a check that rejects a FULLY hollow surface (F1): a file gutted to zero bytes, or a
    directory with no non-empty file at all, no longer passes.

    This is a shallow STRUCTURAL check, not content protection. It does NOT catch a GUTTED-BUT-NONEMPTY
    surface — a directory keeping one junk file while its load-bearing hooks are deleted, or a 1-byte
    `# stub` replacing idc_validation_contract.py — which still passes here (F22). Deeper 'the right
    content is still present' protection is deliberately deferred to code-owner review of the protected
    surfaces (CODEOWNERS + require_code_owner_review), whose ownership validator must therefore be sound
    (F20). See the workflow header for the disclosed scope boundary."""
    if os.path.isdir(path):
        for root, _dirs, files in os.walk(path):
            for name in files:
                try:
                    if os.path.getsize(os.path.join(root, name)) > 0:
                        return True
                except OSError:
                    continue
        return False
    try:
        return os.path.getsize(path) > 0
    except OSError:
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

    # 3. protected surfaces present AND carry content (not a gutted empty stub / emptied dir)
    for surface in surfaces:
        path = os.path.join(repo, surface)
        if not os.path.exists(path):
            reasons.append("missing protected surface: {}".format(surface))
        elif not _surface_has_content(path):
            reasons.append(
                "hollow protected surface: {} exists but carries no content (a gutted file or an "
                "emptied directory)".format(surface))

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
