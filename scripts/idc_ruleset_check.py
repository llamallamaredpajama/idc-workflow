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
    `protected_surfaces` covering the workflow / hook / validation / receipt classes AND the
    governance-of-governance classes (the deterministic checker, the ruleset directory, and
    CODEOWNERS itself — F40).

Any missing or weakened entry is a refusal (non-zero). Compiles under ambient Python 3.9.
"""
from __future__ import annotations

import argparse
import errno
import json
import os
import re
import stat
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

# Each protected-surface CLASS must be represented by at least one entry, matched EXACTLY against a
# canonical path — never an anywhere-substring, which a lookalike (`scripts/not-idc_pathway_check.py`,
# `docs/CODEOWNERS.bak`, `tmp/.github/rulesets-backup`) would satisfy while leaving the real governance
# file outside the ownership gate (F47). Each row carries the class's authoritative file/dir TYPE, so a
# KNOWN surface is typed from what it IS rather than inferred from the CODEOWNERS rules under validation
# (F46). F40 mandates the governance-of-governance classes (the deterministic checker, the ruleset
# directory, and CODEOWNERS itself) so a downstream repo cannot certify while leaving those weakenable
# without a code-owner review.
#   (label, kind, canonical)   kind ∈ {"file", "dir"}
# CODEOWNERS is the one class GitHub reads from several locations; `CODEOWNERS_RELPATHS` (below) lists
# them and `CODEOWNERS_CANONICAL` is the one the contract pins.
CODEOWNERS_CANONICAL = ".github/CODEOWNERS"
SURFACE_CLASSES = (
    ("workflow",   "dir",  ".github/workflows"),
    ("hook",       "dir",  "scripts/hooks"),
    ("validation", "file", "scripts/idc_validation_contract.py"),
    ("receipt",    "file", "scripts/idc_receipt_check.py"),
    ("checker",    "file", "scripts/idc_pathway_check.py"),
    # N1: THIS file. The ownership checker governed every surface except itself — an unreviewed PR
    # could weaken the script that decides whether protected surfaces are owned, and the weakening
    # would certify clean. Same class as the deterministic checker above, so same treatment.
    ("ownership",  "file", "scripts/idc_ruleset_check.py"),
    ("ruleset",    "dir",  ".github/rulesets"),
    ("codeowners", "file", CODEOWNERS_CANONICAL),
)


def _surface_declares_class(surface: str, kind: str, canonical: str) -> bool:
    """MEMBERSHIP: does protected-surface `surface` declare the governance class `(kind, canonical)` —
    i.e. does it put the class's CANONICAL path under protection?

    Matched canonical-EXACTLY (F51). A decoy at another path — `tmp/idc_pathway_check.py`,
    `backup/idc_validation_contract.py` — shares the basename but leaves the REAL file at its canonical
    path unlisted, so nothing forces CODEOWNERS to own the checker the workflow actually executes; the
    earlier basename-anywhere match let such a decoy satisfy the mandatory class and defeat F40. A DIR
    class likewise requires its canonical ROOT: declaring a subdirectory (`.github/workflows/ci/**`)
    protects a slice, not the surface, so it cannot stand in for the class.

    The single exception is CODEOWNERS, which GitHub reads from whichever of three honored locations is
    present — any of those is a legitimate declaration of the class (`_read_codeowners` resolves which
    one actually governs, and F49 forces the effective file to own itself).

    This is deliberately SEPARATE from `_authoritative_surface_type` below. Membership answers "is the
    class covered?"; typing answers "is THIS surface a file or a directory?". Fusing them let a class's
    kind be applied to a surface that was not the class's canonical path — the F52 false-certify."""
    path = _surface_target(surface)[1]
    if kind == "file":
        if canonical == CODEOWNERS_CANONICAL:
            return path in CODEOWNERS_RELPATHS
        return path == canonical
    return path == canonical


def _authoritative_surface_type(surface: str):
    """TYPING: the AUTHORITATIVE file/dir type of a surface, or None when we cannot know it from the
    governance model alone (a descendant entry or a downstream / non-standard declaration).

    Only a surface that IS a class's canonical path gets the class's kind. A surface merely living
    UNDER a directory class is NOT the class and must never inherit its `dir` kind: a FILE beneath
    `.github/workflows` (`.github/workflows/idc-pathway-integrity.yml`) is a file, and typing it `dir`
    let a directory-only trailing-slash rule `covers_all`-certify it while GitHub — reading the trailing
    slash as directory-only — leaves the FILE unowned (F52, the F46 vector re-opened one level down).

    The ownership check types a KNOWN surface from what it IS — never inferred from the CODEOWNERS rules
    being validated, or a directory-only `/<file>/ @owner` rule could re-type a protected FILE surface
    into a directory and certify it (F46). Descendant entries fall through to `_surface_is_owned`'s
    structural handling, which fails CLOSED on a file/directory conflict rather than picking a side."""
    for _label, kind, canonical in SURFACE_CLASSES:
        if _surface_declares_class(surface, kind, canonical):
            return kind
    return None


def _is_governance_descendant(surface: str) -> bool:
    """Whether `surface` lives strictly UNDER a governance directory class without being a class itself.
    Such an entry is governance-relevant (it is inside the machinery the pathway check protects) but has
    no authoritative type, so `_surface_is_owned` resolves a file/dir ambiguity by requiring BOTH
    readings to be owned — fail-closed — instead of letting the rules under validation pick the reading
    that certifies (F52)."""
    path = _surface_target(surface)[1]
    return any(kind == "dir" and path.startswith(canonical + "/")
               for _label, kind, canonical in SURFACE_CLASSES)


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
        for label, kind, canonical in SURFACE_CLASSES:
            if not any(isinstance(s, str) and _surface_declares_class(s, kind, canonical)
                       for s in surfaces):
                reasons.append(
                    "protected_surfaces does not cover the {} surface (no entry naming "
                    "{!r})".format(label, canonical))
    return reasons


# CODEOWNERS is looked for at the three locations GitHub honors, in precedence order.
CODEOWNERS_RELPATHS = (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS")

# GitHub does not load a CODEOWNERS file of 3 MB or more AT ALL — every rule in it is ignored, so
# `require_code_owner_review` binds NO reviewer to any protected surface even though the file parses
# perfectly here. That is a false-certify of exactly the kind F6/F39 exist to prevent (a green receipt
# over protection GitHub never applies), so the size is a fail-closed refusal at the same door.
#
# "3 MB" IS AMBIGUOUS IN GITHUB'S DOCS and this gate resolves it DOWNWARD, deliberately (F29). Decimal
# reads as 3,000,000; binary as 3,145,728. Picking the binary value would leave the 3,000,000–3,145,727
# window certifying HERE while GitHub refuses to load the file — a fail-OPEN gap of ~146 KB in the one
# gate that exists to stop exactly that false-certify. Picking the decimal value can only ever refuse a
# file GitHub would have loaded, which is the safe direction and costs nothing real: a CODEOWNERS is
# realistically a few KB, so no honest repository comes near either number. A fail-closed gate rounds
# an ambiguous limit DOWN.
CODEOWNERS_MAX_BYTES = 3 * 1000 * 1000


def codeowners_size_problem(rel, size_bytes):
    """The refusal reason when the CODEOWNERS at `rel` is at/over GitHub's 3 MB load limit, else None.

    `size_bytes` is the file's RAW BYTE size and must never be a decoded text length: `len(text)`
    counts CODE POINTS, so a multi-byte UTF-8 file undercounts, and a text-mode read additionally
    collapses each CRLF to one LF — either is enough to certify a file GitHub refuses to load. Both
    call sites therefore take the size from the SAME byte string they decode (`len(raw)`), never from
    a separate `stat`, so no second read can disagree with the bytes actually validated.

    `size_bytes is None` means the size COULD NOT BE ESTABLISHED, and that is a REFUSAL, not a skipped
    check. An unmeasurable file cannot be shown to be under the limit, and "cannot prove it is safe"
    must never resolve to "certify it" — this gate exists precisely because an oversized CODEOWNERS
    parses perfectly here while binding no reviewer on GitHub."""
    if rel is None:
        return None
    if size_bytes is None:
        return ("the RAW byte size of the CODEOWNERS file {} could not be determined, so it cannot be "
                "shown to be under GitHub's {}-byte (3 MB) load limit. GitHub does not load a "
                "CODEOWNERS at or over that limit AT ALL, which would leave every protected surface "
                "without a code owner, so an unmeasurable file is refused rather than "
                "certified.".format(rel, CODEOWNERS_MAX_BYTES))
    if size_bytes >= CODEOWNERS_MAX_BYTES:
        return ("the CODEOWNERS file {} is {} bytes — GitHub does not load a CODEOWNERS of {} bytes "
                "(3 MB) or more, so it would bind NO code owner to ANY protected surface and "
                "require_code_owner_review would pass every change through unreviewed. Shrink it "
                "below the limit before installing.".format(rel, size_bytes, CODEOWNERS_MAX_BYTES))
    return None


# How much is read at a time while counting the tail of an over-limit file. Only ever used to COUNT —
# the bytes are discarded immediately, so peak memory stays bounded by CODEOWNERS_MAX_BYTES + 1 + this,
# no matter how large the file on disk is.
_SIZE_COUNT_CHUNK = 1024 * 1024


def _location_unexaminable_problem(rel: str, exc) -> str:
    """Refusal reason when a CODEOWNERS location cannot be INSPECTED at all (a directory component we
    may not list or open). Refusing beats falling through to a lower-precedence file GitHub would not
    be reading."""
    return ("the CODEOWNERS location {} could not be examined ({}) — GitHub honors it ahead of "
            "the remaining locations, so it cannot be skipped in favour of a lower-precedence "
            "file. Fix the permissions on it (or remove it) before installing.".format(rel, exc))


def _unreadable_problem(rel: str, exc) -> str:
    """Refusal reason when the CODEOWNERS FILE exists but its bytes cannot be read (permissions, an
    I/O error). Reported as its own cause: routing this through the unknown-size refusal told the
    operator their file might exceed 3 MB when the real problem was `chmod 000` (F21). The size gate
    still refuses an unknown size on its own — this only makes the message name the true cause."""
    return ("the CODEOWNERS file {} could not be read ({}) — check its permissions. Neither its "
            "ownership rules nor its size can be established, and a file that cannot be shown to "
            "cover the protected surfaces is refused rather than certified.".format(rel, exc))


def _open_repo_file(root_fd: int, rel: str):
    """`(fd, problem)` for the entry GIT RECORDS at exactly `rel`, opened one path component at a time
    beneath the already-open directory `root_fd`.

      `(fd, None)`     an open read-only fd on a REGULAR file at exactly `rel`. The caller owns it.
      `(None, None)`   git records nothing GitHub would read at `rel` — look at the next location.
      `(None, reason)` something IS there, but not something GitHub reads owner rules out of: REFUSE.

    WHAT THIS GUARDS, MECHANICALLY. Each component is opened with `O_NOFOLLOW` relative to its parent's
    fd, and its type is taken from `fstat` on the fd that was actually opened. A component that is a
    symlink therefore fails with ELOOP instead of being resolved by the kernel, and the file whose
    bytes are read is the file whose type was checked — there is no path re-resolution between the two.

    WHY COMPONENT-AT-A-TIME (F33). The predecessor called `os.lstat` on the WHOLE path. `lstat` refuses
    to follow only the LAST component; every directory above it is still resolved, so `ln -s
    .github-real .github` walked straight through the symlink guard: the checker read the target's
    rules and printed `OK`, while git recorded `.github` as a mode-120000 blob, GitHub found no
    `.github/CODEOWNERS` tree entry at all, and `require_code_owner_review` bound NO reviewer to ANY
    protected surface. That is the F6/F39 false-certify the leaf guard exists to prevent, reached one
    directory level up. The rule is now a property of the WHOLE path: what this module certifies must
    be the entry git records at that exact path, so every component is checked, not just the leaf.

    THE THREE OUTCOMES ARE CHOSEN TO MATCH WHAT GITHUB ACTUALLY LOADS:

    * A SYMLINK anywhere in the path REFUSES. At the leaf, git stores a mode-120000 blob whose CONTENT
      IS THE TARGET PATH STRING, GitHub loads that string as the file body, parses no owner rules out
      of it, and binds no reviewer — so falling through to a lower-precedence file would certify rules
      GitHub does not honor at the location it DOES read. At a directory component, git records
      nothing beneath the blob, so GitHub does look on — but this checker reads the WORKING TREE, and a
      symlinked directory is exactly the state in which the working tree and the committed tree can
      disagree in either direction (a local `ln -s` dedupe over a still-committed `.github/`, or a
      committed symlink under a real local directory). Neither can be told apart from here, and one of
      them false-certifies, so the fail-closed answer is the only one that is right in both. The
      refusal names the component and the remedy.
    * A REGULAR-FILE component, or a name absent at that EXACT spelling, is "nothing here" — the
      caller looks on, because that is precisely what GitHub does. A regular file at `.github` means
      git holds a blob there and no `.github/CODEOWNERS` tree entry exists, so GitHub falls through to
      `CODEOWNERS` / `docs/CODEOWNERS` and so do we.
    * ANY OTHER component type REFUSES (F37). Those two states above are the only ones git can record
      as "nothing GitHub reads here": a name that is absent, and a blob. Git cannot record a FIFO or a
      device AT ALL, so finding one at a CODEOWNERS path component is positive proof that the working
      tree diverges from the committed tree — and nothing on this side can say which file GitHub is
      therefore reading. That is the same both-directions ambiguity the symlinked-DIRECTORY arm above
      refuses on, reached by a type git has no mode for rather than by a link, so it gets the same
      fail-closed answer. (A UNIX SOCKET never reaches this type check at all: `open(2)` cannot open
      one, so it is refused one arm earlier by the catch-all errno branch, with the less specific
      "could not be examined" diagnosis. Both fail closed — do NOT try to unify them.)
    * A non-REGULAR leaf REFUSES, as before: a location GitHub reads no rules from binds no reviewer,
      and it must not be skipped in favour of a lower-precedence file.

    THE EXACT-SPELLING CHECK (`name not in os.listdir(parent)`) exists because macOS ships a
    CASE-INSENSITIVE filesystem by default. `.GitHub/CODEOWNERS` opens perfectly there while git
    records — and GitHub looks for — `.github/CODEOWNERS`, so without it the checker certifies rules
    from a path GitHub never reads. On a case-sensitive filesystem the check is a no-op (the open would
    have failed anyway). GitHub documents its three locations with exact spellings; if it were in fact
    case-folding, the cost here is a fall-through to the next location and, at worst, a fail-closed
    "no CODEOWNERS file found" — the same direction this module resolves every other ambiguity in
    (see `CODEOWNERS_MAX_BYTES`).

    A LISTING WE CANNOT READ IS A REFUSAL, not a fall-through: "we could not check" must never resolve
    to "certify it", which is the rule the size, principal and object-chain gates all follow."""
    parts = rel.split("/")
    last = len(parts) - 1
    dir_fd, dir_is_ours = root_fd, False
    try:
        for i, name in enumerate(parts):
            here = "/".join(parts[:i + 1])
            try:
                listing = os.listdir(dir_fd)
            except OSError as exc:
                return None, _location_unexaminable_problem(rel, exc)
            if name not in listing:
                return None, None          # not recorded at this exact spelling; GitHub looks on too
            try:
                # O_NONBLOCK so a FIFO planted at one of these names cannot hang the checker waiting
                # for a writer; it has no effect on a regular file or a directory.
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
            except OSError as exc:
                if exc.errno == errno.ELOOP:
                    return None, (_leaf_symlink_problem(rel) if i == last
                                  else _component_symlink_problem(rel, here))
                if exc.errno in (errno.ENOENT, errno.ENOTDIR):
                    return None, None      # raced away, or a blob where a directory would be
                return None, (_unreadable_problem(rel, exc) if i == last
                              else _location_unexaminable_problem(rel, exc))
            try:
                st = os.fstat(fd)
            except OSError as exc:                                     # pragma: no cover — defensive
                os.close(fd)
                return None, _unreadable_problem(rel, exc)
            if i == last:
                if not stat.S_ISREG(st.st_mode):
                    os.close(fd)
                    return None, _nonregular_leaf_problem(rel)
                return fd, None
            if not stat.S_ISDIR(st.st_mode):
                os.close(fd)
                if stat.S_ISREG(st.st_mode):
                    return None, None      # a blob where a directory would be; GitHub looks on
                # Anything else here is a type git cannot record, so the working tree provably
                # diverges from the tree GitHub reads: refuse rather than fall through (F37).
                return None, _component_nonregular_problem(rel, here)
            if dir_is_ours:
                os.close(dir_fd)
            dir_fd, dir_is_ours = fd, True
    finally:
        if dir_is_ours:
            os.close(dir_fd)
    return None, None                                                  # pragma: no cover — unreachable


def _leaf_symlink_problem(rel: str) -> str:
    return ("the CODEOWNERS at {} is a SYMLINK. Git stores a symlink as a mode-120000 blob whose "
            "content is the TARGET PATH STRING, and GitHub loads that string as the file body — "
            "so it declares NO owner rules and binds NO reviewer to any protected surface, while "
            "reading through the link here would certify the target's rules instead. Replace it "
            "with a regular file holding the rules GitHub must enforce.".format(rel))


def _component_symlink_problem(rel: str, component: str) -> str:
    return ("the CODEOWNERS location {} is reached through {}, which is a SYMLINK. Git stores a "
            "symlink as a mode-120000 blob and records NOTHING beneath it, so the tree GitHub reads "
            "has no {} in it at all and binds no reviewer from it — while following the link here "
            "would certify whatever rules the link's target happens to hold. Replace {} with a real "
            "directory and commit the CODEOWNERS at the path GitHub reads.".format(
                rel, component, rel, component))


def _component_nonregular_problem(rel: str, component: str) -> str:
    """Refusal reason when a non-last path component is NEITHER a directory NOR a regular file (F37).
    Deliberately NOT a reuse of `_component_symlink_problem`: that text asserts the component IS a
    symlink, which would be a false diagnosis for a FIFO or a device — and it is the message the
    symlinked-directory case pins its assertion on."""
    return ("the CODEOWNERS location {} is reached through {}, which is NEITHER a directory NOR a "
            "regular file — it is a named pipe, a device, or another special entry. Git CANNOT RECORD "
            "an entry of this kind at all, so the working tree here provably diverges from the "
            "committed tree GitHub reads, and nothing on this side can say which CODEOWNERS (if any) "
            "GitHub would honor at {}. Remove {} — or restore a real directory in its place — and "
            "commit the CODEOWNERS at the path GitHub reads.".format(
                rel, component, rel, component))


def _nonregular_leaf_problem(rel: str) -> str:
    return ("the CODEOWNERS at {} is not a regular file. GitHub honors this location ahead of the "
            "remaining ones, so it cannot be skipped in favour of a lower-precedence CODEOWNERS: "
            "a location GitHub reads no rules from binds no reviewer to any protected "
            "surface.".format(rel))


def _read_codeowners_sized(repo_root: str):
    """`(relpath, text, size_bytes, read_problem)` for the first CODEOWNERS GitHub would honor, or
    `(None, None, None, None)` when none of the three locations exists. `size_bytes` is the RAW
    on-disk byte count; `read_problem` is a ready-to-print refusal reason when the entry exists but
    cannot be read AS GITHUB WOULD READ IT, else None.

    ONE read, in BINARY, supplies content and size. The size used to be a separate `os.path.getsize`,
    which was wrong twice over: an `OSError` from that call left `size=None` and SILENTLY DISABLED the
    3 MB gate (a file at the limit certified instead of refusing), and stat-ing the path then
    re-opening it validated one snapshot's content against another snapshot's size if the file changed
    in between. Taking `len(raw)` from the very bytes we decode makes those two disagreements
    impossible. **Do not reintroduce a separate `stat` for the size** — that is the bug F2 closed.

    THE READ IS BOUNDED (F30). Reading an unbounded `fh.read()` meant a pathological CODEOWNERS had to
    fit in memory BEFORE the gate that exists to refuse it could run, so the failure mode of an
    oversized file was `MemoryError` rather than this module's REFUSE convention. At most
    `CODEOWNERS_MAX_BYTES + 1` bytes are held: one byte over the limit is already proof the file is
    over it. The exact size is still reported — the tail is COUNTED in `_SIZE_COUNT_CHUNK` pieces that
    are discarded as they are read — so the refusal names a real number rather than a lower bound, and
    an over-limit file is never decoded at all.

    THE PATH IS OPENED COMPONENT BY COMPONENT, NEVER FOLLOWING A SYMLINK (F14, F33) — see
    `_open_repo_file`, which owns that guard and documents which outcomes REFUSE and which fall
    through to the next location, and why each matches what GitHub loads. This function only decides
    what to do with a file it has been handed an fd on.

    The decoded text reproduces text-mode universal-newline translation exactly (CRLF/CR -> LF),
    because callers compare this string against the committed copy and parse ownership rules out of
    it: only the SIZE's provenance changed here, never the text's meaning."""
    try:
        # One fd on the checkout root, reused for all three locations. `repo_root` itself is the
        # BOUNDARY, not part of the certified path: git records paths relative to it, and the operator
        # may legitimately name it through symlinks (`/tmp` -> `/private/tmp` on macOS), so its own
        # components are not walked. Everything BELOW it is.
        root_fd = os.open(repo_root, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as exc:
        # `rel` is the highest-precedence location: it is the one whose examination failed first, and
        # `validate_codeowners_content` only reports a read_problem when a location is named.
        return CODEOWNERS_RELPATHS[0], None, None, (
            "the repository checkout at {} could not be opened ({}), so no CODEOWNERS location under "
            "it could be examined — ownership cannot be shown to cover any protected surface, and an "
            "unverifiable checkout is refused rather than certified.".format(repo_root, exc))
    try:
        for rel in CODEOWNERS_RELPATHS:
            fd, problem = _open_repo_file(root_fd, rel)
            if problem:
                return rel, None, None, problem
            if fd is None:
                continue                                 # nothing here; GitHub looks on too
            try:
                fh = os.fdopen(fd, "rb")                 # takes ownership of fd
            except OSError as exc:                       # pragma: no cover — defensive
                os.close(fd)
                return rel, None, None, _unreadable_problem(rel, exc)
            try:
                with fh:
                    raw = fh.read(CODEOWNERS_MAX_BYTES + 1)
                    if len(raw) > CODEOWNERS_MAX_BYTES:
                        # Already over the limit. Count the rest without retaining it, so the refusal
                        # can name the real size, and never decode it.
                        size = len(raw)
                        while True:
                            chunk = fh.read(_SIZE_COUNT_CHUNK)
                            if not chunk:
                                break
                            size += len(chunk)
                        return rel, None, size, None
            except OSError as exc:
                # Opened as an entry but not readable as a FILE (an I/O error mid-read). Same cause,
                # same message as a refused open — see `_unreadable_problem` (F21).
                return rel, None, None, _unreadable_problem(rel, exc)
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                # A CODEOWNERS with invalid UTF-8 is treated as unreadable and fails closed via the
                # `text is None` path — a clean refusal, never an uncaught UnicodeDecodeError
                # traceback out of the checker/installer (F35). The size IS known here.
                return rel, None, len(raw), None
            return rel, text.replace("\r\n", "\n").replace("\r", "\n"), len(raw), None
        return None, None, None, None
    finally:
        os.close(root_fd)


def _read_codeowners(repo_root: str):
    """`(relpath, text)` for the first CODEOWNERS GitHub would honor, or `(None, None)`. The size-free
    view, for callers that only compare CONTENT (the installer's working-tree-vs-committed check).

    `text` is None whenever the entry could not be read AS GITHUB READS IT. FIVE causes reach that
    state: unreadable bytes; invalid UTF-8; a size STRICTLY OVER the load limit; a symlink or other
    non-regular entry on the path; and — the one that is not about the file at all — a CHECKOUT ROOT
    that could not be opened, where the returned `rel` names the highest-precedence location as a
    placeholder for a path that was never actually examined. Every caller of this view compares the
    result against the committed copy, so a None text yields a divergence refusal: fail-closed in all
    five cases. The fifth is fail-closed with an IMPRECISE diagnosis — the installer reports divergence
    at `.github/CODEOWNERS` when the real problem is that the checkout root would not open — and that
    is accepted deliberately: plumbing the precise cause through this size-free view is a signature
    change, for a corner in which the checkout root itself cannot be opened.

    THE LIMIT BOUNDARY, precisely. `text` is None only STRICTLY over `CODEOWNERS_MAX_BYTES` (the reader
    refuses to decode when `len(raw) > CODEOWNERS_MAX_BYTES`). A file of EXACTLY that size returns real
    text from this view, while `codeowners_size_problem` refuses it independently at `size_bytes >=
    CODEOWNERS_MAX_BYTES`. The two comparisons deliberately differ: this view is not the size gate, and
    a caller must not read a non-None text here as "the size gate would pass it"."""
    rel, text, _size, _problem = _read_codeowners_sized(repo_root)
    return rel, text


# GitHub CODEOWNERS owners take exactly three documented forms — `@username`, `@org/team`, and an
# email address. Anything else (a bare `@`, a handle that is only punctuation, a trailing-space typo, a
# deleted handle) binds NO reviewer on GitHub, so counting it as an owner false-certifies a surface the
# required review leaves unbound — defeating F6's whole purpose (F41). We validate the owner FORMS and
# treat any token that matches none of them as "no owner" (fail closed).
_GH_LOGIN = re.compile(r"^[A-Za-z0-9](?:-?[A-Za-z0-9]){0,38}$")   # user/org login: alnum + single hyphens, <=39
_TEAM_SLUG = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _is_owner_token(tok: str) -> bool:
    """True iff `tok` is a syntactically valid CODEOWNERS owner (`@user`, `@org/team`, or an email).
    A bare `@`, `@/team`, `@-bad`, or a non-owner token is rejected (F41)."""
    if tok.startswith("@"):
        rest = tok[1:]
        if "/" in rest:
            org, _, team = rest.partition("/")
            return bool(_GH_LOGIN.match(org)) and bool(_TEAM_SLUG.match(team))
        return bool(_GH_LOGIN.match(rest))
    return bool(_EMAIL.match(tok))


def _codeowners_rules(text: str) -> list:
    """Parse CODEOWNERS into `(pattern, owners)` pairs, dropping comments and blank lines. Only
    syntactically valid owner tokens count as owners (`_is_owner_token`, F41)."""
    rules = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        pattern = parts[0]
        owners = [tok for tok in parts[1:] if _is_owner_token(tok)]
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


def _name_matcher(anchored: bool, body: str):
    """A wildcard-free, no-trailing-slash pattern. GitHub matches a FILE or a DIRECTORY of this name
    (recursively, if a directory). A dotted basename is modelled as a file; a dotless one as a
    recursive directory-name that ALSO matches a file of that name (`dir_only=False`) — the safe
    over-match, since treating a name as a recursive directory can only broaden what counts as owned or
    un-owned, never certify a surface a narrower reading would refuse. The `dir_only=False` flag is
    load-bearing: unlike a TRAILING-SLASH pattern (directory-only), a bare name owns a FILE surface of
    that exact name (`/.github/CODEOWNERS @owner` owns the FILE `.github/CODEOWNERS`), so it must stay
    distinct from the directory-only patterns that must NOT (F46)."""
    d = body.rstrip("/")
    base = d.rsplit("/", 1)[-1]
    if "." in base:
        return ("file", anchored, d)
    return ("dir_rec", anchored, d, False)


def _rule_matcher(pattern: str):
    """Classify a CODEOWNERS pattern into one of a FIXED set of documented matcher classes we can
    reason about at surface granularity. Anything that does not reduce cleanly to a modeled class is
    `unmodeled` and can NEVER establish ownership — only ever fail closed (F20).

    GitHub's CODEOWNERS follows gitignore semantics, whose two load-bearing rules here are:
      * ANCHORING — a pattern with a slash at its start OR middle is relative to the repo ROOT; a
        pattern that is slashless or carries only a TRAILING slash matches at ANY DEPTH (GitHub docs:
        `*.js` matches "anywhere"; `apps/` matches "any file in an apps directory anywhere");
      * DIRECTORY vs FILE — a trailing `/` matches a directory and everything under it; no trailing
        slash matches a file OR a directory of that name (recursively, if a directory).
    `*` matches within a single path segment (never crossing `/`); `**` / `?` / `[…]` — and any
    pattern mixing a wildcard with structure we do not model — are `unmodeled`.

    Returns (each `anchored` flag: True = repo-root-relative, False = matches at any depth):
        ("root",)                  every file in the repo            `*`  `/`  ``  `**`  `/**`
        ("dir_rec", anchored, D, dir_only)   directory D and everything under it, recursively.
                                   dir_only=True for a TRAILING-SLASH / `/**` pattern (directory-only —
                                   never matches a regular FILE named D); dir_only=False for a bare NAME
                                   (`Makefile`, `.github/CODEOWNERS`) that also matches a file of that name.
        ("dir_one", D)             files DIRECTLY under anchored D (one level)  `/D/*`  `D/*`  (`/*`->"")
        ("suffix", ".ext")         any file with that suffix, at any depth      `*.ext`  `**/*.ext`
        ("file", anchored, F)      a file named F (basename match when any-depth)
        ("unmodeled", locality)    cannot reduce; locality = the anchored wildcard-free leading dir,
                                   or "" when the pattern could match anywhere (fail closed)
    """
    p = pattern.strip()
    if p in ("*", "**", "/**"):
        return ("root",)                                            # matches every file in the repo
    if p in ("", "/"):
        # git (and thus CODEOWNERS) matches NOTHING for a lone `/` or an empty pattern — it is neither
        # repo-wide nor a real surface. Modeled as `unmodeled` so it can NEVER establish ownership; a
        # degenerate `/ @owner` rule must not be read as owning every surface (F33, fail closed).
        return ("unmodeled", "")

    # Leading `**/` = "match at any depth" (documented: `**/logs`). Modeled only for a CLEAN tail — a
    # bare name, a `name/` directory, or a `*.ext` suffix; anything more structured is `unmodeled` and
    # fails closed as a could-be-anywhere pattern (the `anchored = "/" in ...` test below would
    # otherwise mis-read the middle slash of `**/x` as a root anchor).
    if p.startswith("**/"):
        tail = p[3:]
        if not tail or tail in ("*", "**"):
            return ("root",)
        if tail.startswith("*.") and not _has_wildcard(tail[1:]):
            return ("suffix", tail[1:])
        body = tail.rstrip("/")
        if "/" not in body and not _has_wildcard(body):
            # A TRAILING slash means DIRECTORY-ONLY (gitignore/CODEOWNERS): `**/name/` matches a
            # directory named `name` at any depth and everything under it — NEVER a regular file. It
            # must classify as `dir_rec`, not `_name_matcher` (which would read a dotted basename like
            # `**/idc_validation_contract.py/` as a FILE and drop the dir-only constraint, false-
            # certifying the file surface `scripts/idc_validation_contract.py` that GitHub leaves
            # unowned — F32).
            if tail.endswith("/"):
                return ("dir_rec", False, body, True)               # `**/logs/` -> any-depth DIRECTORY (dir-only)
            return _name_matcher(False, body)                       # `**/logs` -> any-depth dir/file
        return ("unmodeled", "")

    body = p[1:] if p.startswith("/") else p
    anchored = "/" in p.rstrip("/")            # a slash that is not purely trailing anchors to root

    if body == "*":                                                 # `/*` — one level at the root
        return ("dir_one", "")
    if not anchored and body.startswith("*.") and not _has_wildcard(body[1:]):
        return ("suffix", body[1:])                                 # `*.py` -> ".py" (any depth)
    if body.endswith("/*") and not _has_wildcard(body[:-2]):
        return ("dir_one", body[:-2].rstrip("/"))                   # `/scripts/*` — one level (anchored)
    if body.endswith("/**") and not _has_wildcard(body[:-3]):
        return ("dir_rec", anchored, body[:-3].rstrip("/"), True)   # `/scripts/**` (directory-only)
    if body.endswith("/") and not _has_wildcard(body.rstrip("/")):
        return ("dir_rec", anchored, body.rstrip("/"), True)        # `/docs/`(root) `apps/`(any depth) dir-only
    if not _has_wildcard(body):
        return _name_matcher(anchored, body)                        # `/path/f.py`  `Makefile`(any depth)

    # Unmodeled — a wildcard in a position we do not model. An ANCHORED pattern is confined under its
    # wildcard-free leading directory; an UNANCHORED one may match at any depth, so its locality is ""
    # (touches every surface). Neither can ever certify ownership (fail closed).
    if anchored:
        cut = len(body)
        for i, ch in enumerate(body):
            if ch in _WILDCARD_CHARS:
                cut = i
                break
        return ("unmodeled", _dirname(body[:cut]).rstrip("/"))
    return ("unmodeled", "")


def _relationship(matcher, target):
    """How a rule matcher relates to a surface target: `covers_all` (every file in the surface is
    matched by this rule), `touches` (some, not provably all), or `none`. Only `covers_all` + an owner
    *establishes* whole-surface ownership; `touches` + ownerless carves a hole that defeats it. An
    `unmodeled` matcher is never `covers_all` — it can only fail closed."""
    kind = matcher[0]
    tkind, tpath = target
    tcomps = tpath.split("/") if tpath else []

    if kind == "root":
        return "covers_all"

    if kind == "dir_rec":
        anchored, D = matcher[1], matcher[2]
        dir_only = matcher[3] if len(matcher) > 3 else True
        if anchored:
            if D == "" or tpath.startswith(D + "/"):
                return "covers_all"                                # D is an ancestor of the surface (its subtree)
            if tpath == D:
                # D names the surface itself. A DIRECTORY-ONLY pattern (trailing slash / `/**`) owns the
                # directory D and its subtree but matches NOTHING for a regular FILE named D on GitHub, so
                # it must never certify a protected FILE surface (F46). A bare-NAME pattern (no trailing
                # slash) matches a file OR a directory of that name, so it does own a file surface named D.
                if tkind == "dir":
                    return "covers_all"
                return "none" if dir_only else "covers_all"
            if tkind == "dir" and D.startswith(tpath + "/"):
                return "touches"                                   # D is a strict descendant of the surface dir
            return "none"
        # any-depth directory NAME (single segment): owns any dir of that name and its whole subtree.
        if tkind == "file":
            # A bare NAME (`dir_only=False`, e.g. `CODEOWNERS`) is not directory-only: GitHub matches a
            # FILE of that name at ANY depth as well. Without this basename leg the FILE reading scored
            # `none`, so a trailing OWNERLESS slashless rule — which GitHub applies last-match-wins to
            # un-own the file — was invisible and the surface false-certified (F50). A TRAILING-SLASH
            # pattern (`dir_only=True`) keeps the ancestor-only reading: it never matches a regular file.
            if not dir_only and tcomps and tcomps[-1] == D:
                return "covers_all"                                # the FILE itself is named D
            return "covers_all" if D in tcomps[:-1] else "none"    # an ANCESTOR dir of the file is named D
        if D in tcomps:
            return "covers_all"                                    # a component IS D -> that dir holds the surface
        return "touches"                                           # a D dir may be nested under the surface

    if kind == "dir_one":
        D = matcher[1]
        if tkind == "dir":
            return "touches" if (D == tpath or D.startswith(tpath + "/")) else "none"
        return "covers_all" if _dirname(tpath) == D else "none"    # a file directly in D is fully matched

    if kind == "suffix":
        if tkind == "dir":
            return "touches"                                       # some files under the surface may carry it
        return "covers_all" if tpath.endswith(matcher[1]) else "none"

    if kind == "file":
        anchored, F = matcher[1], matcher[2]
        if anchored:
            if tkind == "file":
                return "covers_all" if tpath == F else "none"
            return "touches" if (F == tpath or F.startswith(tpath + "/")) else "none"
        # any-depth basename match
        if tkind == "file":
            return "covers_all" if tcomps[-1] == F else "none"
        return "touches"                                           # a file named F could live under the surface

    # unmodeled — locality-scoped, and NEVER covers_all (it can only fail closed, never certify).
    SP = matcher[1]
    if SP == "" or tpath == SP or tpath.startswith(SP + "/") or SP.startswith(tpath + "/"):
        return "touches"
    return "none"


def _declares_directory(surface_path: str, rules: list) -> bool:
    """Whether some CODEOWNERS rule STRUCTURALLY proves `surface_path` is a directory, not a leaf file:
    a trailing-slash / `/**` / `/*` rule ON it, or any anchored rule matching a path strictly BELOW
    `surface_path/`. A leaf file has no interior and takes no trailing slash, so such a rule can only
    exist when the surface is a directory — a fail-closed-safe signal to switch a dot-in-basename
    surface that `_surface_target` GUESSED was a file (`config/my.dir`, `.github`) over to the stricter
    directory reading (F28). Without it, the file reading only un-owns on an EXACT-name match, so a
    later ownerless rule carving a hole INSIDE the directory (`/config/my.dir/secret.txt`) is invisible
    and the surface false-certifies. Unanchored / any-depth patterns are deliberately NOT treated as
    directory signals — they do not prove the surface is a directory and would false-REFUSE a genuine
    dotted file that a suffix (`*.py`) or any-depth rule legitimately owns."""
    below = surface_path.rstrip("/") + "/"
    for pattern, _owners in rules:
        m = _rule_matcher(pattern)
        kind = m[0]
        if kind == "dir_one":                          # `/D/*` — always anchored; D is a directory
            D = m[1]
            if D == surface_path or D.startswith(below):
                return True
        elif kind == "dir_rec" and m[1]:               # anchored `/D/` or `/D/**` — D is a directory
            D = m[2]
            if D == surface_path or D.startswith(below):
                return True
        elif kind == "file" and m[1]:                  # anchored `/F` matching strictly BELOW the surface
            if m[2].startswith(below):
                return True
    return False


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
    cannot certify `scripts/hooks/**` off `/scripts/*` or `/*`; and a slashless / trailing-slash-only
    rule (`hooks/`, a bare `idc_validation_contract.py`) matches at ANY DEPTH, so a later ownerless one
    un-owns the surface it sits within (F20). Patterns we cannot reduce to a modeled class are
    `unmodeled`: they never establish ownership and, when ownerless and possibly relevant, fail closed
    by un-owning. The consequence is a strict fail-closed bias — an exotic or one-level CODEOWNERS may
    be refused with a clear message telling the operator to add an anchored recursive rule.

    Scope of the fail-closed guarantee: for a protected surface declared with the standard conventions
    (a directory carrying a `/`, `/*` or `/**` suffix, or a genuine file), this never certifies a
    surface GitHub would leave unowned — including a `**/name/` trailing-slash directory pattern, which
    is directory-only and cannot own a file surface (F32), and a directory-only `/<file>/` rule on a
    KNOWN governance FILE surface, which `_authoritative_surface_type` types from what the surface IS so
    the rule can never re-type it to a directory and certify it (F46). The ONE documented residual is an
    UNKNOWN dotted surface outside the modeled governance classes (a downstream `config/my.dir` with no
    `/`-family suffix and no authoritative type) whose directory-ness is inferred from the rules: a
    trailing-slash self-rule can still read it as a directory. That inference is deliberately confined to
    non-governance surfaces — it cannot touch the F40-protected files — and closing it fully for arbitrary
    downstream declarations would need a filesystem stat and would false-REFUSE genuine dotted files; it
    is the review's accepted 'non-standard declaration' tradeoff (F28 residual), not a false-certify of
    any standard-declared or governance surface."""
    base = _surface_target(surface)
    # F46: a KNOWN governance surface is typed from what it AUTHORITATIVELY is — a file or a directory —
    # never inferred from the CODEOWNERS rules under validation. Otherwise a directory-only
    # `/<file>/ @owner` rule (trailing slash) re-types a protected FILE surface to a directory and then
    # `covers_all`-certifies it, while GitHub reads the trailing slash as directory-only and leaves the
    # FILE unowned — the exact false-certify F40's file surfaces exist to prevent.
    auth = _authoritative_surface_type(surface)
    if auth in ("file", "dir"):
        targets = [(auth, base[1])]
    # `_surface_target` types a bare dotted-basename path as a FILE, but the same spelling can name a
    # DIRECTORY (`config/my.dir`, a dotfile dir). When a rule STRUCTURALLY proves it is a directory the
    # two readings disagree, and which one we pick decides the verdict — so who decides matters:
    elif base[0] == "file" and _declares_directory(base[1], rules):
        if _is_governance_descendant(surface):
            # Inside the governance machinery, the rules under validation must NOT get to pick the
            # reading that certifies. Require BOTH readings to be owned — the fail-closed resolution.
            # This is what closes F52: for `.github/workflows/idc-pathway-integrity.yml` a directory-only
            # `/.github/workflows/idc-pathway-integrity.yml/ @team` rule satisfies the DIR reading but
            # scores `none` under the FILE reading, so the surface is correctly REFUSED rather than
            # certified while GitHub leaves the real file unowned.
            targets = [("file", base[1]), ("dir", base[1])]
        else:
            # F28 (unknown / non-standard downstream surfaces only): read it as the directory the rules
            # prove it to be, so a later ownerless interior-hole rule un-owns it (invisible to the
            # exact-file match otherwise). Confined to surfaces outside the governance machinery, where
            # requiring both readings would false-REFUSE a legitimately owned dotted directory.
            targets = [("dir", base[1])]
    else:
        targets = [base]
    return all(_owned_under(target, rules) for target in targets)


def _owned_under(target, rules: list) -> bool:
    """Walk `rules` in file order under ONE file/dir reading of the surface, tracking a single ownership
    state the way GitHub resolves last-match-wins per file (see `_surface_is_owned`)."""
    owned = False
    for pattern, owners in rules:
        rel = _relationship(_rule_matcher(pattern), target)
        if rel == "covers_all":
            owned = bool(owners)
        elif rel == "touches" and not owners:
            owned = False
    return owned


def validate_codeowners_content(rel, text, surfaces, size_bytes, read_problem) -> list:
    """Refusal reasons for CODEOWNERS `(rel, text)` against `surfaces` — the shared core of the
    working-tree check (`validate_codeowners`, F6) and the installer's COMMITTED-content check (F39).
    `rel is None` means no CODEOWNERS was found; `text is None` means it was found but unreadable.

    `size_bytes` is the file's RAW BYTE size and is REQUIRED — deliberately not defaulted. It is gated
    against GitHub's 3 MB load limit BEFORE any rule is read: an oversized file parses fine here but is
    not loaded by GitHub at all, so ownership derived from its rules would be pure fiction. It carried
    a `=None` default once, and that made W1 opt-in: any future caller that simply forgot the kwarg
    would have silently disabled the limit check with nothing going red, because the installer's own
    size gate is defence-in-depth and would have masked it. `None` remains a legal VALUE (the size is
    unknown) but it now REFUSES; what is no longer possible is failing to pass it at all.

    `read_problem` is REQUIRED for the same reason, and reported FIRST. It carries the reader's own
    precise cause when the file exists but cannot be read the way GitHub reads it — a symlink, a
    non-regular entry, an OS-level read failure (F14/F21). Without it, all three arrived here as
    `size_bytes=None` and were reported with the SIZE refusal, telling an operator whose CODEOWNERS was
    `chmod 000` that their file might exceed 3 MB. Reporting it ahead of the size gate is a DIAGNOSTIC
    ordering only: the size gate still refuses an unknown size on its own, so the fail-closed behaviour
    F2 established is unchanged — only which true statement gets printed. The installer's committed
    read has no such cause (it reads bytes out of `git show`) and passes None explicitly."""
    if rel is None:
        return ["no CODEOWNERS file found (looked at {}) — require_code_owner_review cannot bind a "
                "reviewer to any protected surface".format(", ".join(CODEOWNERS_RELPATHS))]
    if read_problem:
        return [read_problem]
    oversize = codeowners_size_problem(rel, size_bytes)
    if oversize:
        return [oversize]
    if text is None:
        return ["the CODEOWNERS file {} is unreadable".format(rel)]
    rules = _codeowners_rules(text)
    if not rules:
        return ["{} declares no owner rules — every protected surface is unowned".format(rel)]
    reasons = []
    declared = {s for s in (surfaces or []) if isinstance(s, str)}
    for surface in surfaces or []:
        if isinstance(surface, str) and surface and not _surface_is_owned(surface, rules):
            reasons.append(
                "protected surface {!r} has no code owner in {} — add a CODEOWNERS rule for it".format(
                    surface, rel))
    # F49: the contract pins the codeowners surface to `.github/CODEOWNERS`, but GitHub reads whichever
    # of the three honored locations is present (`rel`) — which may be root `CODEOWNERS` or `docs/CODEOWNERS`.
    # When the EFFECTIVE governing file is not the declared surface, nothing above forces it to own ITSELF,
    # so a code owner could weaken the real governing file without a review. Require `/<rel>` to be owned
    # too, wherever it lives (skipped when `rel` IS a declared surface — the loop already covers it).
    if rel not in declared and not _surface_is_owned(rel, rules):
        reasons.append(
            "the effective CODEOWNERS file {!r} does not own itself — the governing file must name an "
            "owner for its own path, or it can be weakened without a code-owner review (F49)".format(rel))
    return reasons


def validate_codeowners(repo_root: str, surfaces) -> list:
    """Refusal reasons for protected-surface ownership in the WORKING TREE at `repo_root`: a CODEOWNERS
    must exist and name an owner for every protected surface, so `require_code_owner_review` actually
    binds a reviewer to each (F6). The installer additionally validates the COMMITTED content GitHub
    enforces on the default branch, not the working tree (F39). The file's RAW byte size is threaded in
    so a CODEOWNERS at/over GitHub's 3 MB load limit is refused rather than certified, and a symlinked
    or otherwise unreadable location is refused rather than followed (F14)."""
    rel, text, size_bytes, read_problem = _read_codeowners_sized(repo_root)
    return validate_codeowners_content(rel, text, surfaces, size_bytes=size_bytes,
                                       read_problem=read_problem)


def _gh_json(args: list, repo_flag=None):
    cmd = ["gh"] + args
    try:
        out = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as exc:
        # An absent or unexecutable `gh` is a FAILURE TO VERIFY, not a pass. Converted here — at the
        # single door every live read in this module goes through — so `--repo` mode refuses through
        # this module's own `REFUSE (live)` convention instead of escaping as a raw FileNotFoundError
        # traceback past the gates. The installer carries the identical conversion (F10); this module
        # is its own door and did not inherit it (F15).
        raise RuntimeError("could not invoke gh: {}".format(exc))
    if out.returncode != 0:
        raise RuntimeError("`{}` failed: {}".format(" ".join(cmd), CS.scrub(out.stderr).strip()[:200]))
    return json.loads(out.stdout or "null")


# GitHub paginates `repos/{repo}/rulesets` at 30 per page by DEFAULT, and the listing includes
# org-inherited rulesets, so a repository governed by a handful of org rulesets can push ours off page
# one. Reading a single page then means "absent from page 1" is silently read as "not installed" — the
# exact 30-item truncation class this repo already documents in `idc_gh_board.py` and defends against
# in `idc_git_janitor.py` (F24). Pages are walked explicitly rather than with `gh --paginate`, whose
# output shape for array endpoints varies across gh versions (concatenated arrays vs `--slurp`).
_RULESETS_PER_PAGE = 100

# The walk stops at an EMPTY page, so a listing that never empties must be bounded by something. At
# `_RULESETS_PER_PAGE` items per page this is 10,000 rulesets on one repository — orders of magnitude
# past anything real, so it can only be reached by a backend that is not paginating as documented.
# Reaching it RAISES rather than returning what was collected: a truncated listing is not proof of
# absence, which is the same rule the non-list page follows (F36).
_MAX_LISTING_PAGES = 100


def _gh_json_all_pages(path: str, per_page=_RULESETS_PER_PAGE) -> list:
    """Every item of a paginated GitHub LIST endpoint, walked to exhaustion. Shares its termination
    and refusal contract with the installer's copy — see `idc_ruleset_install._gh_json_all_pages` for
    the full rationale (a null body, a non-list body, and a listing that never ends all REFUSE; only
    an EMPTY page ends the walk)."""
    items, page = [], 1
    while True:
        if page > _MAX_LISTING_PAGES:
            raise RuntimeError(
                "`{}` had not returned an empty page after {} pages of up to {} entries — refusing "
                "to keep walking a listing that does not terminate, and refusing to answer from the "
                "truncated part of it".format(path, _MAX_LISTING_PAGES, per_page))
        body = _gh_json(["api", "{}?per_page={}&page={}".format(path, per_page, page)])
        if not isinstance(body, list):
            raise RuntimeError(
                "`{}` returned {}, not the documented JSON array — refusing to read an unparseable "
                "listing as an empty one".format(
                    path, "an empty body" if body is None else type(body).__name__))
        if not body:
            break
        items.extend(body)
        page += 1
    return items


def load_live_ruleset(owner_repo: str) -> dict:
    """Fetch the installed `idc-pathway-integrity` ruleset for OWNER/REPO and return its payload."""
    listing = _gh_json_all_pages("repos/{}/rulesets".format(owner_repo))
    match = next((r for r in listing if isinstance(r, dict) and r.get("name") == RULESET_NAME), None)
    if match is None:
        raise RuntimeError(
            "no ruleset named {!r} is installed on {}".format(RULESET_NAME, owner_repo))
    # `.get("id")`, not `["id"]`: a listing entry that carries the right name but no id is a malformed
    # body, and the module's contract is that a missing field REFUSES rather than raising KeyError.
    ruleset_id = match.get("id")
    if ruleset_id is None:
        raise RuntimeError(
            "the ruleset named {!r} on {} was listed without an 'id' — refusing to read an "
            "unidentifiable ruleset".format(RULESET_NAME, owner_repo))
    return _gh_json(["api", "repos/{}/rulesets/{}".format(owner_repo, ruleset_id)])


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
