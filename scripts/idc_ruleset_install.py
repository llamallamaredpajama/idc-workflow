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
  * Protected-surface OWNERSHIP is a MANDATORY precondition (F18): the ruleset's
    `require_code_owner_review` binds no reviewer unless a CODEOWNERS names every protected surface,
    so the installer refuses (before any network call, in dry-run and apply alike) when the TARGET
    repo's CODEOWNERS does not cover them. The target is the repo named by `--repo`; because its
    ownership is only knowable from a checkout of it, `--repo-root` (a checkout of `--repo`) is
    REQUIRED — the gate is NEVER derived from the ruleset path, which for the shipped default ruleset
    is the plugin itself (a different repository whose CODEOWNERS is irrelevant to the target).
  * The ownership gate validates the CODEOWNERS GitHub actually ENFORCES — the copy COMMITTED on the
    target's default branch, not the working tree (F39). GitHub evaluates CODEOWNERS from the default
    branch, so an uncommitted / stale / locally-edited working-tree CODEOWNERS could certify here yet
    bind no reviewer once the ruleset is live. The installer reads the committed content via a LOCAL
    `git show <default-branch>:.github/CODEOWNERS`, validates THAT, and refuses when no CODEOWNERS is
    committed or when the working-tree copy differs from it — fail closed, clear message.
  * The default branch is read from the checkout's `origin/HEAD` (set by a real clone). It NEVER
    falls back to the currently checked-out branch (F44): on a feature branch that carries a covering
    CODEOWNERS while the real default branch lacks one, that fallback would certify ownership against
    a branch GitHub does not enforce. When `origin/HEAD` is unset (a single-branch clone,
    `actions/checkout`, or a locally `git init`-ed checkout), the installer REFUSES unless the operator
    names the enforced branch explicitly with `--default-branch <ref>` (validated to resolve here).
  * The working-tree-vs-committed divergence check compares CONTENT, normalizing newlines on both
    sides (F45): the working tree is read in text mode (LF) while the committed copy is raw `git show`
    bytes (may be CRLF), so a byte-identical CRLF-committed CODEOWNERS is not mistaken for a divergence.

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

# The F34 identity gate must prove the checkout is the GitHub `--repo`, so a remote only counts when it
# is hosted on GitHub. GH_HOST (the same env `gh` honors, e.g. a GitHub Enterprise host) overrides the
# default; anything else — a non-GitHub SSH host, GitLab, a bare local path — is refused (F48).
_GH_HOST = (os.environ.get("GH_HOST") or "github.com").strip().lower()

# The URI schemes git actually uses to CLONE from a GitHub host. A remote on any other scheme (notably
# `file://`, which reads a local directory) is not evidence the checkout came from GitHub (F53).
_CLONE_SCHEMES = frozenset({"https", "http", "ssh", "git"})


def _normalize_remote(url: str):
    """Normalize a git remote URL to lowercase `owner/repo` IFF it is hosted on the GitHub host, else
    None. Handles the three GitHub forms — `git@github.com:OWNER/REPO(.git)`,
    `https://github.com/OWNER/REPO(.git)`, and `ssh://git@github.com/OWNER/REPO(.git)`. The HOST is
    parsed and checked (F48): dropping it and keeping only the last two path segments let a NON-GitHub
    checkout (`git@evil.example.com:owner/repo`, `https://gitlab.com/owner/repo`, a local path ending in
    `owner/repo`) satisfy the identity gate against `--repo owner/repo`, so an unrelated checkout's
    CODEOWNERS could certify the real GitHub target. A remote whose host is not the GitHub host — or that
    carries no host at all — returns None (unverifiable → refused upstream).

    The SCHEME and the path SHAPE are checked just as strictly (F53). Accepting any URI scheme let
    `file://github.com/owner/repo.git` — which clones nothing from GitHub — pass the gate, and reducing
    any `>= 2`-segment path to its last two let `https://github.com/decoy/owner/repo.git` pass as well.
    Either way an unrelated checkout's CODEOWNERS could certify the real target, defeating the identity
    proof F34/F48 exist to give. Only the network clone schemes GitHub actually serves are accepted, and
    the path must be EXACTLY `owner/repo` — no deeper nesting."""
    text = (url or "").strip()
    if not text:
        return None
    text = re.sub(r"\.git/*$", "", text)
    host = path = None
    m = re.match(r"^([A-Za-z][A-Za-z0-9+.\-]*)://(?:[^@/]+@)?([^/:]+)(?::\d+)?/(.+)$", text)
    if m:                                                   # scheme://[user@]host[:port]/owner/repo
        if m.group(1).lower() not in _CLONE_SCHEMES:
            return None                                     # e.g. file:// — not a GitHub clone URL
        host, path = m.group(2), m.group(3)
    else:
        m = re.match(r"^(?:[^@/]+@)?([^/:]+):(.+)$", text)  # scp-like  [user@]host:owner/repo
        if m:
            host, path = m.group(1), m.group(2)
    if host is None or host.lower() != _GH_HOST:
        return None
    segs = [s for s in path.strip("/").split("/") if s]
    if len(segs) != 2:                                      # EXACTLY owner/repo — never a deeper path
        return None
    return "{}/{}".format(segs[0], segs[1]).lower()


def _repo_root_identity(repo_root: str):
    """The `owner/repo` identity of the checkout at `repo_root`, read from its `origin` remote — a
    LOCAL, no-network check. None if there is no resolvable origin (or `git` is unavailable)."""
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "config", "--get", "remote.origin.url"],
            capture_output=True, text=True)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    return _normalize_remote(out.stdout)


def _default_branch_ref(repo_root: str, override=None):
    """The git ref GitHub enforces CODEOWNERS from, as `(ref, reason)` — a LOCAL, no-network
    resolution (F39/F44). `(ref, None)` on success; `(None, <reason>)` when the enforced branch cannot
    be established, so the caller REFUSES (fail closed).

    With an explicit `override` (the operator-asserted default branch, for the single-branch /
    `actions/checkout` / locally `git init`-ed checkouts where `origin/HEAD` is unset), that ref is
    used AFTER confirming it resolves to a commit in THIS checkout — a typo'd or absent branch returns
    `(None, "override-unresolved")`, never silently trusted.

    Without an override, the default branch is read ONLY from `refs/remotes/origin/HEAD` (set by a real
    clone, e.g. `origin/main`). It deliberately does NOT fall back to the currently checked-out branch
    (F44): a checkout sitting on a NON-default branch would otherwise validate THAT branch's committed
    CODEOWNERS — not the branch GitHub actually enforces — and could certify ownership against a copy
    that binds no reviewer. When `origin/HEAD` is unresolvable it returns `(None, "origin-head-unset")`
    so the caller refuses and points the operator at `--default-branch` (or a full clone)."""
    if override:
        try:
            chk = subprocess.run(
                ["git", "-C", repo_root, "rev-parse", "--verify", "--quiet",
                 "{}^{{commit}}".format(override)],
                capture_output=True, text=True)
        except OSError:
            return None, "git-unavailable"
        if chk.returncode != 0 or not chk.stdout.strip():
            return None, "override-unresolved"
        return override, None
    try:
        out = subprocess.run(
            ["git", "-C", repo_root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            capture_output=True, text=True)
    except OSError:
        return None, "git-unavailable"
    if out.returncode == 0 and out.stdout.strip():
        return out.stdout.strip(), None                     # e.g. "origin/main"
    return None, "origin-head-unset"


def _normalize_newlines(text):
    """Collapse CRLF/CR to LF for a CONTENT-equality comparison only — it never rewrites the file
    (F45). The working-tree copy is read in text mode (universal-newlines → LF) while the committed
    copy is raw `git show` bytes (keeps CRLF), so a byte-identical CRLF-committed CODEOWNERS would
    otherwise spuriously trip the divergence guard."""
    if text is None:
        return None
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _committed_codeowners(repo_root: str, ref: str):
    """`(relpath, text)` of the CODEOWNERS COMMITTED at `ref` (first of the GitHub-honored locations),
    or `(None, None)` if none is committed. Reads via `git show <ref>:<relpath>` — the committed bytes
    GitHub would enforce, not the working tree (F39). Decodes UTF-8 strictly, mirroring the checker's
    `_read_codeowners`: a committed CODEOWNERS whose bytes are not valid UTF-8 returns `(relpath, None)`
    so the caller fails closed via the 'unreadable' path rather than crashing on a decode error."""
    for rel in RC.CODEOWNERS_RELPATHS:
        try:
            out = subprocess.run(
                ["git", "-C", repo_root, "show", "{}:{}".format(ref, rel)],
                capture_output=True)                        # bytes — decode ourselves, strict UTF-8
        except OSError:
            return None, None
        if out.returncode == 0:
            try:
                return rel, out.stdout.decode("utf-8")
            except UnicodeDecodeError:
                return rel, None
    return None, None


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
    parser.add_argument("--repo-root", default=None,
                        help="REQUIRED: a local checkout of the --repo TARGET whose CODEOWNERS must "
                             "cover every protected surface. The ownership gate validates THIS repo, "
                             "never the ruleset-carrying checkout.")
    parser.add_argument("--default-branch", default=None, metavar="REF",
                        help="the branch GitHub enforces CODEOWNERS from, for checkouts where "
                             "origin/HEAD is unset (single-branch clone / actions/checkout / a locally "
                             "git-init'd checkout). Must resolve in --repo-root. Without it the default "
                             "branch is read from origin/HEAD and an unresolvable one is REFUSED — the "
                             "installer never falls back to the currently checked-out branch (F44).")
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

    # Production-repo guard runs BEFORE any network call (and before the ownership gate).
    if args.apply and args.repo in PROTECTED_REPOS:
        print("REFUSE: {} is a protected production repository — this installer will not mutate its "
              "rulesets".format(args.repo), file=sys.stderr)
        return 3

    # F18: ownership coverage is a MANDATORY install precondition, validated against the TARGET repo
    # named by --repo — NOT the ruleset-carrying checkout. For the shipped default ruleset that checkout
    # is the PLUGIN itself, whose CODEOWNERS is irrelevant to the repo being protected; deriving the
    # root from the ruleset path would validate the wrong repository and let the installer bind
    # require_code_owner_review onto a target with no CODEOWNERS at all (F18). The target's ownership is
    # only knowable from a checkout of it, so --repo-root (a checkout of --repo) is REQUIRED; we refuse
    # rather than guess, in dry-run and apply alike, before any network call.
    if not args.repo_root:
        print("REFUSE: --repo-root <checkout of {}> is required so the TARGET repo's CODEOWNERS is the "
              "one validated — require_code_owner_review binds no reviewer unless every protected "
              "surface is owned in the repo being protected, and the ownership gate is never derived "
              "from the ruleset path.".format(args.repo), file=sys.stderr)
        return 2

    # F34: --repo-root must be a checkout OF --repo. Requiring the flag is not enough — an operator can
    # point it at ANY checkout whose CODEOWNERS happens to cover the surfaces (the plugin repo `.` is
    # the convenient default when standing in it), and the ownership gate would then certify the wrong
    # repository, re-opening the exact "validates the wrong repo" hole F18 exists to close. Bind the two
    # with a LOCAL, no-network identity check (the checkout's `origin` remote) and REFUSE on mismatch or
    # when the identity cannot be established — an unverifiable checkout is not proof of the target.
    identity = _repo_root_identity(args.repo_root)
    if identity is None:
        print("REFUSE: cannot confirm the checkout at --repo-root {} is a checkout of {} — its `origin` "
              "remote is absent or not on the GitHub host {!r} (F48). The ownership gate must validate the "
              "TARGET GitHub repo, so an unverifiable or non-GitHub checkout is refused (point --repo-root "
              "at a checkout of {} whose origin names it on GitHub; set GH_HOST for a GitHub Enterprise "
              "host).".format(args.repo_root, args.repo, _GH_HOST, args.repo), file=sys.stderr)
        return 2
    if identity != args.repo.lower():
        print("REFUSE: --repo-root {} is a checkout of {!r}, not the --repo target {!r} — validating an "
              "unrelated checkout's CODEOWNERS would certify ownership of the wrong repository (F34). "
              "Point --repo-root at a checkout of {}.".format(
                  args.repo_root, identity, args.repo.lower(), args.repo), file=sys.stderr)
        return 2

    surfaces = (doc.get("idc_contract") or {}).get("protected_surfaces") or []

    # F39: GitHub enforces the CODEOWNERS COMMITTED on the default branch, not the working tree. Validate
    # that committed copy (via a local `git show`), and refuse when none is committed or when the working
    # tree differs from it — an uncommitted / stale / locally-edited CODEOWNERS could otherwise certify
    # here yet bind NO reviewer once the ruleset is live. Runs after the F34 identity check (so `ref` is
    # the target's own branch), before any network call, in dry-run and apply alike.
    ref, ref_reason = _default_branch_ref(args.repo_root, args.default_branch)
    if ref is None:
        if ref_reason == "override-unresolved":
            print("REFUSE: --default-branch {!r} does not resolve to a commit in the checkout at {} — "
                  "name the branch GitHub enforces (one that exists in this checkout).".format(
                      args.default_branch, args.repo_root), file=sys.stderr)
        else:
            print("REFUSE: cannot determine the branch GitHub will enforce CODEOWNERS from in the "
                  "checkout at --repo-root {} — origin/HEAD is unset (a single-branch clone, "
                  "actions/checkout, or a locally git-init'd checkout) and this tool will NOT fall back "
                  "to the currently checked-out branch, which may not be the default GitHub enforces "
                  "(F44). Run against a full clone, or pass --default-branch <the branch GitHub "
                  "enforces>.".format(args.repo_root), file=sys.stderr)
        return 2
    committed_rel, committed_text = _committed_codeowners(args.repo_root, ref)
    if committed_rel is None:
        print("REFUSE: no CODEOWNERS is committed on {} in the checkout at {} — GitHub enforces the "
              "default-branch CODEOWNERS, so require_code_owner_review would bind no reviewer to any "
              "protected surface. Commit (and push) a CODEOWNERS covering every protected surface before "
              "installing.".format(ref, args.repo_root), file=sys.stderr)
        return 1
    if committed_text is None:
        print("REFUSE: the CODEOWNERS committed on {} ({}) is unreadable (not valid UTF-8) — refusing "
              "to certify ownership from a file GitHub cannot parse.".format(ref, committed_rel),
              file=sys.stderr)
        return 1
    wt_rel, wt_text = RC._read_codeowners(args.repo_root)
    # Compare CONTENT, not raw bytes: the working-tree copy is read in text mode (LF) while the
    # committed copy is raw `git show` bytes (may be CRLF), so normalize newlines on BOTH sides — a
    # byte-identical CRLF-committed CODEOWNERS must not trip this guard (F45). Normalization is for the
    # comparison only (neither file is rewritten); genuinely divergent content still refuses.
    if (wt_rel, _normalize_newlines(wt_text)) != (committed_rel, _normalize_newlines(committed_text)):
        print("REFUSE: the working-tree CODEOWNERS ({}) does not match the copy committed on {} ({}) — "
              "GitHub enforces the committed default-branch copy, not your working tree, so a local edit "
              "or uncommitted file would install require_code_owner_review while binding a different (or "
              "no) reviewer. Commit (and push) the CODEOWNERS you intend to enforce before "
              "installing.".format(wt_rel or "absent", ref, committed_rel), file=sys.stderr)
        return 1

    # Ownership is validated against the COMMITTED content — exactly what GitHub enforces (F39).
    ownership = RC.validate_codeowners_content(committed_rel, committed_text, surfaces)
    if ownership:
        print("REFUSE: protected surfaces are not all owned in the CODEOWNERS committed on {} ({}) — "
              "require_code_owner_review would bind no reviewer; add CODEOWNERS coverage before "
              "installing:".format(ref, committed_rel), file=sys.stderr)
        for r in ownership:
            print("  - {}".format(r), file=sys.stderr)
        return 1

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
