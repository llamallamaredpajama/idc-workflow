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
    names the enforced branch explicitly with `--default-branch <ref>` (validated to resolve here, and
    under `--apply` additionally required to NAME GitHub's live default branch — see LIVE GATES; a SHA
    resolves but names no branch, so it is refused, and a shallow `actions/checkout` needs
    `git fetch origin <D>:<D>` rather than a SHA).
  * The working-tree-vs-committed divergence check compares CONTENT, normalizing newlines on both
    sides (F45): the working tree is read in text mode (LF) while the committed copy is raw `git show`
    bytes (may be CRLF), so a byte-identical CRLF-committed CODEOWNERS is not mistaken for a divergence.
  * A committed CODEOWNERS at or over GitHub's 3 MB load limit is REFUSED on its raw byte size
    (`RC.codeowners_size_problem`). GitHub does not load such a file at all, so installing over it
    would switch on `require_code_owner_review` with ZERO code owners behind it.
  * The OBJECT CHAIN the pinned commit names is re-hashed with `git fsck` before any content is read
    out of it (`_object_chain_problem`, F13), and a non-zero exit REFUSES.

TRUST MODEL — stated explicitly, because these gates only mean something against a named threat. The
checkout's `.git` directory is INSIDE the trust boundary this module defends: a local tamper there is
the very thing the committed-content gates exist to survive, since the premise of the whole module is
that "it resolves locally" is not proof of what GitHub enforces. Two layers implement that, and both
are load-bearing:
  * REF layer — `refs/replace/*` rewires object lookup so `git show` and `git rev-parse` disagree.
    Closed in `_git` by disabling replacement objects on every call.
  * OBJECT layer — git does not verify an object's hash when it READS it, so overwriting the loose
    object file for the committed blob (or the enclosing tree) substitutes content while every oid
    stays unchanged; disabling replacement refs does NOT help here. Closed by `_object_chain_problem`.
What is NOT claimed: this is not a general repository audit, and an attacker who can write to `.git`
retains every other power that grants (including deleting the checkout). The specific, narrow guarantee
is that the CODEOWNERS bytes certified here are the bytes the pinned commit actually names.

LIVE GATES — `--apply` only. Two classes of false-certify are enforced HERE rather than in the checker
because only the installer can make them MANDATORY. The checker does have a live mode
(`idc_ruleset_check.py --repo OWNER/REPO`, which can be combined with `--repo-root`), so "it has no
target repo to interrogate" would be false — but `--repo` there is OPTIONAL, so any check hung off it
is skippable by simply not passing the flag. The installer is about to MUTATE a named repository, so it
always knows the target and can refuse unconditionally, against the real repository, immediately before
mutation:
  * PRINCIPALS. Every distinct owner token in the committed CODEOWNERS must resolve on the target and
    hold write-or-better access — `@user` via `repos/{repo}/collaborators/{user}/permission`,
    `@org/team` via `orgs/{org}/teams/{team}/repos/{repo}`. An email owner is refused as
    live-unverifiable (GitHub exposes no API that resolves one). A deleted handle, a renamed account,
    an ungranted or invisible team, or a read-only collaborator binds NO reviewer, so each refuses.
  * DEFAULT BRANCH. The validation ref must NAME the repo's live `default_branch` (accepted as `<D>`
    or `origin/<D>`) and the local checkout of it must be at the same commit GitHub reports. This
    closes a `--default-branch` pointed at any locally-resolving commit-ish (a SHA, a PR head, a
    feature branch) and a stale `origin/HEAD` left by a default-branch rename — both resolve locally
    while pointing `git show` at bytes GitHub does not enforce.
Any gh failure, non-JSON body, or missing field REFUSES (fail closed). DRY-RUN MAKES NO NETWORK CALL —
it keeps the local-only resolution and prints a note that these two gates run at apply.

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
# ENTRIES ARE LOWERCASE AND MATCHED CASE-FOLDED (F31). GitHub owner and repository names are
# case-insensitive: `LlamaLlamaRedPajama/IDC-Workflow` and `llamallamaredpajama/idc-workflow` are the
# SAME repository, and an exact `in` test would have walked the differently-cased spelling straight
# past the denylist into the live apply path. The adjacent F34 identity gate already compares
# `identity != args.repo.lower()` for precisely this reason, so an exact match here was the odd one
# out. `_is_protected_repo` is the only reader; do not compare against this set directly.
PROTECTED_REPOS = frozenset({
    "llamallamaredpajama/idc-workflow",
})


def _is_protected_repo(repo: str) -> bool:
    """Whether `repo` names a denylisted production repository, compared CASE-FOLDED on both sides
    because GitHub repository names are case-insensitive (F31)."""
    return (repo or "").strip().lower() in {r.lower() for r in PROTECTED_REPOS}

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


def _git(repo_root: str, args: list, text=True):
    """Run `git -C <repo_root> <args>` through the ONE hardened door every git read in this module
    uses. Raises OSError when git cannot be executed (callers fail closed on that).

    REPLACEMENT OBJECTS ARE DISABLED HERE, and that is load-bearing, not hygiene. `git replace`
    installs a `refs/replace/<oid>` mapping that rewires OBJECT lookup: `git show` FOLLOWS it and
    hands back the substituted commit's bytes, while `git rev-parse` keeps reporting the ORIGINAL
    oid. The two commands therefore disagree, and this module's apply path runs exactly that pair —
    it compares `rev-parse`'s oid against GitHub's live tip (which matches, so the staleness gate
    passes) and then reads content with `git show` (which returns attacker-chosen bytes). The result
    was a green `OK: ruleset created` receipt over a repo binding NO reviewer for six of seven
    protected surfaces.

    PINNING THE OID IS NOT A FIX FOR THIS ON ITS OWN — verified: `git show <full-oid>:<path>` still
    follows the replace ref, because replacement is applied at object lookup, below ref resolution.
    Only refusing to read replacement refs closes it, so it is set for EVERY call rather than at the
    one site that reads content: any future git read added here is trust-bearing by default.

    A `refs/replace/*` ref is a deliberate LOCAL tamper (`refs/replace` is not fetched by a default
    clone), so this is not remotely reachable — but the premise of this whole module is that a
    locally-resolving ref is not proof of what GitHub enforces, and a local tamper is precisely the
    threat the committed-content gates exist to survive.

    REF REWIRING IS ONLY THE UPPER LAYER OF THIS VECTOR CLASS. Disabling replacement refs does NOT make
    `git show` trustworthy on its own: git does not verify an object's hash when it reads it, so
    overwriting the loose OBJECT FILE for the committed blob (or the enclosing tree) returns
    attacker-chosen bytes while `rev-parse` reports the unchanged oids and this flag makes no
    difference (measured). That layer is closed by `_object_chain_problem`, which re-hashes the chain
    with `git fsck` before anything is certified. The two are complementary, not alternatives — keep
    both.

    Both the env var and the `--no-replace-objects` flag are set, as belt and braces. The stated
    reason used to be a division of labour between them, and that was inaccurate on both halves: git
    documents the two as equivalent and the FLAG ALONE already exports `GIT_NO_REPLACE_OBJECTS=1` to
    anything git shells out to (verified with an alias probe on git 2.54.0), while `_git` builds its
    own `dict(os.environ)` copy, so there is no caller position from which the env var could be
    scrubbed anyway. They are both set because redundancy on a security-load-bearing flag is cheap,
    not because either covers a gap the other leaves."""
    env = dict(os.environ)
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    kwargs = {"capture_output": True, "env": env}
    if text:
        kwargs["text"] = True
    return subprocess.run(["git", "-C", repo_root, "--no-replace-objects"] + args, **kwargs)


def _repo_root_identity(repo_root: str):
    """The `owner/repo` identity of the checkout at `repo_root`, read from its `origin` remote — a
    LOCAL, no-network check. None if there is no resolvable origin (or `git` is unavailable)."""
    try:
        out = _git(repo_root, ["config", "--get", "remote.origin.url"])
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
            chk = _git(repo_root, ["rev-parse", "--verify", "--quiet",
                                   "{}^{{commit}}".format(override)])
        except OSError:
            return None, "git-unavailable"
        if chk.returncode != 0 or not chk.stdout.strip():
            return None, "override-unresolved"
        return override, None
    try:
        out = _git(repo_root, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    except OSError:
        return None, "git-unavailable"
    if out.returncode == 0 and out.stdout.strip():
        return out.stdout.strip(), None                     # e.g. "origin/main"
    return None, "origin-head-unset"


def _resolve_commit(repo_root: str, ref: str):
    """The immutable commit OID `ref` names in this checkout, or None when it does not resolve.

    Resolved ONCE and then used for BOTH the live tip comparison and the committed-content read, so
    those two can never be answered from different commits — a symbolic ref (`origin/main`) re-read
    between the two calls is a check-then-act window, and an immutable oid is not re-readable."""
    try:
        out = _git(repo_root, ["rev-parse", "--verify", "--quiet", "{}^{{commit}}".format(ref)])
    except OSError:
        return None
    sha = (out.stdout or "").strip()
    if out.returncode != 0 or not sha:
        return None
    return sha


def _object_chain_problem(repo_root: str, ref_oid: str):
    """The refusal reason when the checkout's git OBJECT STORE does not re-hash to the oids naming its
    objects, else None. THE TRUST ANCHOR FOR EVERY `git show` READ IN THIS MODULE (F13).

    WHAT IS ACTUALLY VERIFIED IS THE WHOLE STORE, deliberately a SUPERSET of the chain reachable from
    `ref_oid` (F35). `git fsck` re-hashes every loose object and — with `--full`, its default —
    verifies every pack, whichever heads are named on the command line; naming `ref_oid` scopes the
    REACHABILITY trace, not the hashing. That is more than this gate needs and it is kept that way on
    purpose: the extra coverage is free, it is fail-CLOSED, and narrowing it to the chain would mean
    re-implementing fsck's walk here. The cost is a false refusal on a checkout carrying an unrelated
    corrupt or orphaned object — a crashed write, an aborted fetch, a bad sector on a long-dead branch
    — so the refusal message names that benign cause alongside tampering rather than accusing the
    commit being installed.

    WHY THIS EXISTS. Git does not verify an object's hash when it READS it — it verifies on write and
    trusts the object store thereafter. So an attacker with write access to the checkout's `.git` can
    overwrite the loose object file named for the committed CODEOWNERS blob, and `git show
    <oid>:<path>` hands back their bytes while `rev-parse` still reports the ORIGINAL commit AND blob
    oids. Every other gate in this module is then satisfied BY CONSTRUCTION: the commit oid is
    untouched so the live tip comparison matches GitHub, and the working tree can hold the same
    substituted bytes so the divergence gate passes. The result was `OK: ruleset created` over a repo
    binding a reviewer to one of seven protected surfaces. Disabling replacement refs does not help
    (measured: `GIT_NO_REPLACE_OBJECTS=1 git --no-replace-objects show` returns the substituted bytes
    too) — that closes ref rewiring, one layer above this.

    A TREE-LEVEL VARIANT IS STRICTLY HARDER, and rules out the cheaper fix. Substituting the enclosing
    `.github` TREE object makes `git rev-parse <commit>:.github/CODEOWNERS` report the ATTACKER's blob
    oid, which re-hashes to itself — so re-hashing `git show` output against the reported blob oid is
    self-consistent and certifies. Only re-hashing every object on the chain, against the oid that
    NAMES it, catches both.

    `git fsck` is exactly that re-hash. Measured on git 2.54.0: exit 3 with `hash-path mismatch` for
    BOTH the loose-blob and the tree-object substitution, exit 0 on the clean control. The gate is the
    EXIT STATUS, never the message text — fsck also reports `dangling`/`unreachable` objects on
    perfectly healthy repositories (well over a hundred such lines on this repo's own history when
    measured — an exact count would only rot) and still exits 0, so
    parsing output would be both fragile and noisy.

    SCOPE, HONESTLY. What this BUYS is narrow and specific: *the bytes this module certifies are the
    bytes the pinned commit actually names*. What it RUNS is wider than that (see above), so a failure
    here does not by itself prove the pinned chain is the damaged part. It is not a security audit of
    the repository either — an attacker who can write to `.git` can also delete this checkout.

    An fsck that cannot RUN is itself a refusal (fail closed): "we could not check" must never resolve
    to "certify it", which is the same rule the size and principal gates follow.

    COST. Reachability from a commit includes its ancestors, so this walks history — measured at ~1s
    on this repo. That is paid once per install, against a mutation of repository protection rules,
    and it is the only way to know the bytes are real. Verified NOT to false-refuse the checkout shapes
    this module documents: shallow (`--depth 1` / `fetch-depth: 1`), blobless (`--filter=blob:none`)
    and treeless (`--filter=tree:0`) clones all exit 0, because fsck understands shallow boundaries and
    promisor objects."""
    try:
        out = _git(repo_root, ["fsck", "--no-progress", ref_oid])
    except OSError as exc:
        return ("git could not be invoked to verify the object chain of {} in the checkout at {} ({}) "
                "— the committed CODEOWNERS is read out of that object store, so an unverifiable "
                "store is refused rather than trusted.".format(ref_oid[:12], repo_root, exc))
    if out.returncode != 0:
        return ("the git object store in the checkout at {} FAILED verification — `git fsck` exited "
                "{}. Git does not re-hash objects when it reads them, so a corrupted or TAMPERED "
                "object file makes `git show` return bytes that are not the ones a commit names, "
                "while `rev-parse` keeps reporting the original oids and every other gate here "
                "passes. Refusing to certify CODEOWNERS out of an object store that does not verify. "
                "This check covers the WHOLE store, not only the chain of the commit being installed "
                "({}), so it can also fire on unrelated corrupt or orphaned objects left by a crashed "
                "write or an aborted fetch: run `git fsck` yourself to see what failed, and `git gc "
                "--prune=now` (or a fresh clone) before concluding the commit was "
                "tampered with.".format(repo_root, out.returncode, ref_oid[:12]))
    return None


def _normalize_newlines(text):
    """Collapse CRLF/CR to LF for a CONTENT-equality comparison only — it never rewrites the file
    (F45). The working-tree copy is read in text mode (universal-newlines → LF) while the committed
    copy is raw `git show` bytes (keeps CRLF), so a byte-identical CRLF-committed CODEOWNERS would
    otherwise spuriously trip the divergence guard."""
    if text is None:
        return None
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _committed_codeowners(repo_root: str, ref: str):
    """`(relpath, text, size_bytes)` of the CODEOWNERS COMMITTED at `ref` (first of the GitHub-honored
    locations), or `(None, None, None)` if none is committed. Reads via `git show <ref>:<relpath>` —
    the committed bytes GitHub would enforce, not the working tree (F39). Decodes UTF-8 strictly,
    mirroring the checker's `_read_codeowners`: a committed CODEOWNERS whose bytes are not valid UTF-8
    returns `(relpath, None, size)` so the caller fails closed via the 'unreadable' path rather than
    crashing on a decode error.

    `size_bytes` is the length of the RAW `git show` stdout — the exact byte count GitHub measures
    against its 3 MB load limit. It is taken from the bytes, never from the decoded string, because
    `len(text)` counts CODE POINTS: a multi-byte UTF-8 CODEOWNERS would undercount and could certify a
    file GitHub silently refuses to load."""
    for rel in RC.CODEOWNERS_RELPATHS:
        try:
            # bytes — decode ourselves, strict UTF-8. Goes through `_git`, which DISABLES replacement
            # objects: a `refs/replace/*` ref would otherwise make this read return a substituted
            # commit's bytes while the tip check saw the real oid and passed.
            out = _git(repo_root, ["show", "{}:{}".format(ref, rel)], text=False)
        except OSError:
            return None, None, None
        if out.returncode == 0:
            raw = out.stdout or b""
            try:
                return rel, raw.decode("utf-8"), len(raw)
            except UnicodeDecodeError:
                return rel, None, len(raw)
    return None, None, None


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
    try:
        out = subprocess.run(["gh"] + args, capture_output=True, text=True)
    except OSError as exc:
        # An absent or unexecutable `gh` is a FAILURE TO VERIFY, not a pass. Converting it here — at
        # the single door every live read goes through — means all five call sites fail closed
        # through their existing `except RuntimeError` and print this module's own
        # `REFUSE: …` message, instead of a raw traceback escaping past the gates (the convention
        # already used at the mutation call). Fixing it at the door rather than at each caller also
        # covers any live read added later.
        raise RuntimeError("could not invoke gh: {}".format(exc))
    if out.returncode != 0:
        raise RuntimeError("`gh {}` failed: {}".format(" ".join(args), CS.scrub(out.stderr).strip()[:200]))
    return json.loads(out.stdout or "null")


# The walk below stops at an EMPTY page, so a listing that never empties must be bounded by something.
# At the default 100 items per page this is 10,000 rulesets on a single repository — orders of
# magnitude past anything real, so it can only be reached by a backend that is not paginating as
# documented. See `_gh_json_all_pages` for why reaching it RAISES (F36).
_MAX_LISTING_PAGES = 100


def _gh_json_all_pages(path: str, per_page=100) -> list:
    """Every item of a paginated GitHub LIST endpoint, walked to exhaustion.

    GitHub paginates `repos/{repo}/rulesets` at 30 per page by DEFAULT and the listing INCLUDES
    org-inherited rulesets, so a repository governed by a handful of org rulesets can push ours off
    page one. Reading one page then silently reads "absent from page 1" as "not installed", and the
    idempotent PUT/update becomes a POST/create against a ruleset that already exists — the same
    30-item truncation class this repo already documents in `idc_gh_board.py` and defends against in
    `idc_git_janitor.py` (F24). Pages are walked explicitly rather than with `gh --paginate`, whose
    output shape for array endpoints varies across gh versions (concatenated arrays vs `--slurp`).

    EVERY WAY THIS CAN FAIL TO ESTABLISH THE FULL LISTING REFUSES, because the caller turns the answer
    into a MUTATION: "our ruleset is not in this listing" is what makes `--apply` POST a new one, so a
    listing that is merely unfinished must never be read as a complete one (F34, F36).

    * A NULL/empty body REFUSES. `_gh_json` maps a `gh` that exits 0 with no output to `None`, and
      `None` used to `break` — reading an unverifiable body as "the listing ended", so `--apply`
      created a duplicate ruleset off a read it could not verify, one line above a guard that refuses
      a `{}` body for exactly that reason. It now goes through the same refusal: not a list, not proof
      of absence.
    * A NON-LIST page REFUSES: an unparseable listing is not proof of absence.
    * ONLY AN EMPTY PAGE ENDS THE WALK. Stopping on a SHORT page (`len(body) < per_page`) trusted the
      server to honor `per_page`: a backend serving its 30-item default would end the walk after page
      one holding 30 entries, silently reinstating the very truncation this function exists to close.
      An empty page is the one end-of-listing signal that needs no such trust, at the cost of one
      extra request per listing (GitHub returns `[]` past the last page).
    * A LISTING THAT NEVER EMPTIES REFUSES at `_MAX_LISTING_PAGES` rather than looping forever. This
      is not hypothetical: a stub written for these very tests served a full page one for every page
      and hung the walker, which had to be killed rather than debugged from a failure."""
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


def _existing_ruleset_id(owner_repo: str):
    listing = _gh_json_all_pages("repos/{}/rulesets".format(owner_repo))
    # `isinstance(r, dict)` + `.get`, never `r["id"]`: `_gh_json` guarantees the body is valid JSON,
    # NOT that it has the documented SHAPE. A listing entry carrying the right name but no `id` raised
    # `KeyError: 'id'` — a raw traceback for the literal "missing field" this module's header promises
    # REFUSES (F16). Every consumer of a gh body in this module reads defensively for the same reason.
    match = next((r for r in listing if isinstance(r, dict) and r.get("name") == RULESET_NAME), None)
    if match is None:
        return None
    ruleset_id = match.get("id")
    if ruleset_id is None:
        raise RuntimeError(
            "a ruleset named {!r} is listed on {} but carries no 'id' — refusing to update an "
            "unidentifiable ruleset (and refusing to create a duplicate over "
            "it)".format(RULESET_NAME, owner_repo))
    return ruleset_id


# --- LIVE apply-path gates ------------------------------------------------------------------------
# Everything below reaches the network and therefore runs ONLY under --apply. Dry-run stays a purely
# local, no-network plan (a documented contract of this tool) and prints a note saying these gates run
# at apply. Each gate FAILS CLOSED: any gh failure, non-JSON body, or missing field REFUSES rather than
# assuming the permissive answer.

# An effective grant that can actually satisfy `require_code_owner_review`. GitHub's
# `/collaborators/{user}/permission` reports the legacy `permission` field (admin|write|read|none) and
# the modern `role_name` (which surfaces `maintain`/`triage` and custom roles); `maintain` reports as
# `write` in the legacy field on some paths and only as `role_name` on others, so BOTH are consulted.
_WRITE_OR_BETTER = frozenset({"admin", "write", "maintain"})

# `permission` IS THE AUTHORITATIVE FIELD; `role_name` is a FALLBACK, not an independent proof. The two
# used to be OR'd (`perm not in W and role not in W`), which let ANY value in `role_name` grant access
# on its own — and `role_name` carries ORG-DEFINED CUSTOM ROLE NAMES, which are free-form. A custom
# role named "Write" (or "admin") that grants no push at all would then case-fold into this set and
# satisfy the gate while the authoritative `permission` field said `read`. That inverts the module's
# whole posture: the gate exists to prove a code owner CAN approve, so the field GitHub defines
# normatively must be the one that decides. `role_name` is now consulted ONLY when `permission` is
# absent or empty — the case the fallback was documented for — so it can still rescue a body that omits
# the legacy field, but can no longer OVERRIDE one that reports read/triage/none.
#
# Residual, stated honestly: when `permission` is missing entirely, a colliding custom role name is
# still accepted. There is nothing more authoritative left to consult at that point, and refusing every
# body that omits the legacy field would break any GitHub Enterprise version that does not send it.
# The exposure needs an org to have BOTH defined a custom role named like a built-in AND be served a
# body with no `permission` field.
_ROLE_ONLY_ACCEPTED = _WRITE_OR_BETTER


def _distinct_owner_tokens(text: str) -> list:
    """Every DISTINCT owner token in CODEOWNERS `text`, in first-appearance order. Only SYNTACTICALLY
    valid owners are returned — `RC._codeowners_rules` already drops malformed tokens (F41), which the
    ownership gate has by then refused on if they left a surface unowned."""
    seen, tokens = set(), []
    for _pattern, owners in RC._codeowners_rules(text):
        for tok in owners:
            if tok not in seen:
                seen.add(tok)
                tokens.append(tok)
    return tokens


def _principal_problem(owner_repo: str, tok: str):
    """The refusal reason when owner `tok` cannot be CONFIRMED to hold write-or-better access on
    `owner_repo`, else None. One live `gh api` read per principal; any failure refuses.

    A CODEOWNERS rule that names a principal GitHub cannot resolve — a deleted/renamed handle, a team
    that does not exist or was never granted the repo, an outside collaborator downgraded to read —
    binds NO reviewer for that rule. File CONTENT cannot show this; it takes a live read against the
    target. The checker can perform live reads (its `--repo` mode does), but that flag is OPTIONAL
    there, so a gate hung off it is skippable. The installer always knows the repository it is about to
    mutate, so this is the one place the claim can be tested against reality UNCONDITIONALLY, before
    protection is switched on."""
    if not tok.startswith("@"):
        # An email owner only binds when it matches a committer identity GitHub can map to a user with
        # access; there is no API that resolves it, so it is live-UNVERIFIABLE. Fail closed and say so.
        return ("owner {!r} is an email address — GitHub exposes no API to confirm an email owner "
                "resolves to a user with write access on {}, so it cannot be verified before "
                "protection is switched on. Name the owner as an @handle or @org/team "
                "instead.".format(tok, owner_repo))
    rest = tok[1:]
    if "/" in rest:
        org, _, team = rest.partition("/")
        try:
            doc = _gh_json(["api", "-H", "Accept: application/vnd.github.v3.repository+json",
                            "orgs/{}/teams/{}/repos/{}".format(org, team, owner_repo)])
        except (RuntimeError, ValueError) as exc:
            # 404 covers all three indistinguishable cases: the team does not exist, it is invisible to
            # this token, or it has no grant on the repo. None of them binds a reviewer.
            return ("team owner {!r} could not be confirmed to have write access on {} — the team is "
                    "absent, invisible to this token, or has no grant on the repo ({}). A team that "
                    "cannot be resolved binds no reviewer.".format(tok, owner_repo, exc))
        if not isinstance(doc, dict):
            # `_gh_json` guarantees valid JSON, NOT the documented shape: a bare list/string/number
            # body reached `.get` and raised AttributeError instead of refusing (F16).
            return ("team owner {!r}: GitHub returned a {} rather than the documented object for its "
                    "grant on {} — refusing to assume access from a body this module cannot "
                    "parse.".format(tok, type(doc).__name__, owner_repo))
        perms = doc.get("permissions")
        if not isinstance(perms, dict):
            return ("team owner {!r}: GitHub returned no permissions object for its grant on {} — "
                    "refusing to assume access.".format(tok, owner_repo))
        # `is True`, not truthiness: GitHub documents these as JSON booleans, and every non-boolean a
        # malformed/proxied body could carry — the STRING "false", "0", "no" — is truthy in Python and
        # would grant write access on a body we could not actually parse. Only a real `true` counts;
        # anything else falls through to the read/triage refusal, which is the fail-closed direction.
        if not any(perms.get(k) is True for k in ("push", "maintain", "admin")):
            return ("team owner {!r} has only read/triage access on {} — a code owner without write "
                    "access cannot satisfy require_code_owner_review.".format(tok, owner_repo))
        return None
    try:
        doc = _gh_json(["api", "repos/{}/collaborators/{}/permission".format(owner_repo, rest)])
    except (RuntimeError, ValueError) as exc:
        return ("owner {!r} could not be confirmed as a collaborator on {} — the account does not "
                "exist, was renamed, or has no access ({}). A handle GitHub cannot resolve binds no "
                "reviewer.".format(tok, owner_repo, exc))
    if not isinstance(doc, dict):
        return ("owner {!r}: GitHub returned a {} rather than the documented permission object for "
                "{} — refusing to assume access from a body this module cannot parse.".format(
                    tok, type(doc).__name__, owner_repo))
    perm = str(doc.get("permission") or "").strip().lower()
    role = str(doc.get("role_name") or "").strip().lower()
    # `permission` decides when it is present; `role_name` is consulted only to rescue a body that
    # omits it (see `_ROLE_ONLY_ACCEPTED`). A free-form custom role name must not out-vote the
    # authoritative field.
    granted = perm in _WRITE_OR_BETTER if perm else role in _ROLE_ONLY_ACCEPTED
    if not granted:
        return ("owner {!r} has {!r} access on {} — a code owner without write access cannot satisfy "
                "require_code_owner_review.".format(tok, perm or role or "no", owner_repo))
    return None


def verify_owner_principals(owner_repo: str, text: str) -> list:
    """Refusal reasons for every DISTINCT owner principal in the COMMITTED CODEOWNERS `text` that
    cannot be confirmed to exist AND hold write-or-better access on `owner_repo` (live)."""
    problems = []
    for tok in _distinct_owner_tokens(text):
        problem = _principal_problem(owner_repo, tok)
        if problem:
            problems.append(problem)
    return problems


def _names_default_branch(ref: str, default_branch: str) -> bool:
    """Whether the validation ref NAMES `default_branch` — accepted as exactly `<D>` or `origin/<D>`,
    the only two spellings that denote that branch in a checkout. A SHA, a PR head ref, or any other
    branch name is not the default branch, however cleanly it resolves locally."""
    return ref == default_branch or ref == "origin/{}".format(default_branch)


def live_default_branch_problem(owner_repo: str, repo_root: str, ref: str, override, local_sha=None):
    """The refusal reason when the validation ref is not bound to `owner_repo`'s LIVE default branch on
    GitHub (or the local checkout of it is stale), else None.

    `_default_branch_ref` proves the ref RESOLVES here; it cannot prove it is the branch GitHub
    ENFORCES CODEOWNERS from. Two holes remain after it: an operator-supplied `--default-branch` may
    name any locally-resolving commit-ish (a SHA, a PR head, a feature branch), and a checkout's
    `origin/HEAD` may be stale after the repo's default branch was renamed. Either way the committed
    CODEOWNERS validated by `git show` is not the one GitHub enforces, so the receipt is green over
    protection that does not exist. Both are closed here, plus a tip-equality check that pins `git
    show` to the exact bytes live on GitHub.

    `local_sha` is the caller's ALREADY-RESOLVED oid for `ref` (`_resolve_commit`). The same oid is
    handed to `_committed_codeowners`, so the commit compared against GitHub here and the commit the
    content is read from are the same object by construction, not by re-resolving a symbolic ref
    twice. Passing None makes this resolve it itself (kept for direct callers and tests).

    RESIDUAL, stated honestly (not closable here): this is a check-then-act against a LIVE remote.
    GitHub's default branch and tip are read before the principal lookups and before the mutation, so
    a push that lands in that window is not reflected at mutation time — the ruleset would be applied
    against a tip one commit behind what the operator saw certified. Re-reading immediately before
    the PUT/POST would narrow the window but never close it (there is no compare-and-swap on the
    rulesets API), and every gate here already fails closed, so the residual is DOCUMENTED rather
    than chased. The exposure is bounded by the fact that the newly pushed commit still had to pass
    the repo's own protection to land."""
    try:
        repo_doc = _gh_json(["api", "repos/{}".format(owner_repo)])
    except (RuntimeError, ValueError) as exc:
        return ("cannot read the default branch of {} from GitHub ({}) — apply binds validation to the "
                "branch GitHub actually enforces CODEOWNERS from, so an unverifiable default branch is "
                "refused.".format(owner_repo, exc))
    # isinstance, not `(repo_doc or {})`: a valid-JSON body of the wrong SHAPE (a list, a string)
    # reached `.get` and raised AttributeError instead of this module's REFUSE convention (F16).
    if not isinstance(repo_doc, dict):
        return ("GitHub returned a {} rather than the documented repository object for {} — refusing "
                "to certify against a body this module cannot parse.".format(
                    type(repo_doc).__name__, owner_repo))
    default_branch = str(repo_doc.get("default_branch") or "").strip()
    if not default_branch:
        return ("GitHub reported no default_branch for {} — refusing to certify ownership against an "
                "unconfirmed branch.".format(owner_repo))
    if not _names_default_branch(ref, default_branch):
        if override:
            return ("--default-branch {!r} is not the branch GitHub enforces on {} — its live default "
                    "branch is {!r}. GitHub reads CODEOWNERS only from the default branch, so "
                    "validating a SHA, a PR head, or another branch would certify ownership GitHub "
                    "never applies. Pass --default-branch {} (or origin/{}).".format(
                        override, owner_repo, default_branch, default_branch, default_branch))
        return ("this checkout's origin/HEAD names {!r} but GitHub's live default branch for {} is "
                "{!r} — origin/HEAD is stale, so validation would read the wrong branch's CODEOWNERS. "
                "Refresh it with `git remote set-head origin -a`, or pass --default-branch "
                "{}.".format(ref, owner_repo, default_branch, default_branch))
    try:
        branch_doc = _gh_json(["api", "repos/{}/branches/{}".format(owner_repo, default_branch)])
    except (RuntimeError, ValueError) as exc:
        return ("cannot read the tip of {}'s default branch {!r} from GitHub ({}) — refusing to certify "
                "against bytes that may not be the ones GitHub enforces.".format(
                    owner_repo, default_branch, exc))
    # Both levels are shape-checked (F16): `{"commit":"abc"}` — a string where the object belongs —
    # raised AttributeError on the inner `.get` before this refused.
    if not isinstance(branch_doc, dict):
        return ("GitHub returned a {} rather than the documented branch object for {}'s {!r} — "
                "refusing to certify against a body this module cannot parse.".format(
                    type(branch_doc).__name__, owner_repo, default_branch))
    commit_doc = branch_doc.get("commit")
    remote_sha = str((commit_doc.get("sha") if isinstance(commit_doc, dict) else "") or "").strip()
    if not remote_sha:
        return ("GitHub reported no tip commit for {}'s default branch {!r} — refusing to certify "
                "against an unconfirmed tip.".format(owner_repo, default_branch))
    if local_sha is None:
        local_sha = _resolve_commit(repo_root, ref)
    if not local_sha:
        return ("{!r} no longer resolves in the checkout at {} — cannot compare it with GitHub's "
                "tip.".format(ref, repo_root))
    if local_sha != remote_sha:
        return ("the checkout's {} is at {} but GitHub's {} is at {} — this checkout is STALE, so "
                "`git show` would validate bytes GitHub is not enforcing. Run `git fetch` (and update "
                "the remote-tracking ref) before installing.".format(
                    ref, local_sha[:12], default_branch, remote_sha[:12]))
    return None


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
                             "git-init'd checkout). Must resolve in --repo-root AND, under --apply, "
                             "must NAME the repo's live default branch: pass the branch name D (or "
                             "origin/D). A SHA is REFUSED even though it resolves — it names no branch. "
                             "Under actions/checkout the branch name often does not resolve locally "
                             "while the SHA does; fix that with `git fetch origin D:D` (or "
                             "fetch-depth: 0), not by passing the SHA. Without this flag the default "
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
    if args.apply and _is_protected_repo(args.repo):
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

    # At APPLY, bind the validation ref to the branch GitHub actually enforces CODEOWNERS from, and
    # pin it to the exact commit live on GitHub. `_default_branch_ref` above only proves the ref
    # resolves LOCALLY — a `--default-branch` naming a SHA/PR head/feature branch, or a stale
    # `origin/HEAD` left behind by a default-branch rename, both resolve cleanly while pointing at
    # bytes GitHub does not enforce. Runs BEFORE the `git show` read below so the committed CODEOWNERS
    # that gets validated is the enforced one. Dry-run keeps today's local-only resolution and makes NO
    # network call.
    # Resolve the validation ref to an IMMUTABLE oid ONCE, and use that oid for both the live tip
    # comparison and the committed-content read below. A symbolic ref re-read per call is a
    # check-then-act window between "the commit we vouched for" and "the commit we read bytes from";
    # an oid cannot drift between the two. (The replace-ref hole that made those two calls disagree
    # outright is closed in `_git`, which this goes through.)
    ref_oid = _resolve_commit(args.repo_root, ref)
    if ref_oid is None:
        print("REFUSE: {!r} does not resolve to a commit in the checkout at {} — the branch GitHub "
              "enforces CODEOWNERS from must be readable here before anything can be certified "
              "against it.".format(ref, args.repo_root), file=sys.stderr)
        return 2

    # F13: the pinned oid names an object CHAIN, and git trusts its object store on read rather than
    # re-hashing it. Verify that chain BEFORE anything is read out of it. This sits here — between
    # resolving the oid and the first `git show` — deliberately: it is the single door every certify
    # path passes through, so dry-run and apply are covered by one gate rather than by a check bolted
    # onto each reader. Placing it after the committed read would certify the bytes first and check
    # them second; placing it inside `if args.apply:` would leave dry-run printing a green plan over a
    # tampered store. It is purely LOCAL (no network), so the dry-run no-network contract is intact.
    chain_problem = _object_chain_problem(args.repo_root, ref_oid)
    if chain_problem:
        print("REFUSE: {}".format(chain_problem), file=sys.stderr)
        return 1

    if args.apply:
        live_problem = live_default_branch_problem(
            args.repo, args.repo_root, ref, args.default_branch, local_sha=ref_oid)
        if live_problem:
            print("REFUSE: {}".format(live_problem), file=sys.stderr)
            return 1

    committed_rel, committed_text, committed_size = _committed_codeowners(args.repo_root, ref_oid)
    # GitHub does not load a CODEOWNERS of 3 MB or more AT ALL, so an oversized file would install
    # require_code_owner_review over ZERO code owners. Gate the raw committed byte size FIRST — ahead
    # of the readability and working-tree-divergence checks — so the refusal names the real reason
    # (the size) instead of a downstream symptom.
    if committed_rel is not None:
        oversize = RC.codeowners_size_problem(committed_rel, committed_size)
        if oversize:
            print("REFUSE: {} (committed on {})".format(oversize, ref), file=sys.stderr)
            return 1
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

    # Ownership is validated against the COMMITTED content — exactly what GitHub enforces (F39), with
    # the raw committed byte size threaded in so the shared validator applies the same 3 MB load-limit
    # gate the checker does (defense in depth behind the explicit size refusal above).
    # `read_problem=None` explicitly: that parameter carries the CHECKER's filesystem-read causes
    # (symlink / non-regular entry / unreadable — F14, F21). This read came out of `git show`, which
    # has no such states, so there is genuinely no cause to report. It is passed by name rather than
    # defaulted for the same reason `size_bytes` is required — a caller must not be able to forget a
    # fail-closed input (see `RC.validate_codeowners_content`).
    ownership = RC.validate_codeowners_content(
        committed_rel, committed_text, surfaces, size_bytes=committed_size, read_problem=None)
    if ownership:
        print("REFUSE: protected surfaces are not all owned in the CODEOWNERS committed on {} ({}) — "
              "require_code_owner_review would bind no reviewer; add CODEOWNERS coverage before "
              "installing:".format(ref, committed_rel), file=sys.stderr)
        for r in ownership:
            print("  - {}".format(r), file=sys.stderr)
        return 1

    # At APPLY, every owner principal named in the committed CODEOWNERS must actually EXIST on the
    # target and hold write-or-better access. The ownership gate above proves the FILE covers every
    # protected surface; it cannot prove the principals it names are real. That takes a live read, and
    # while the checker CAN read live (`--repo`), the flag is optional there and so the check would be
    # skippable; here it is unconditional because the installer always knows the repo it is mutating.
    # Without it, a rule naming a deleted handle or an ungranted team certifies while binding no
    # reviewer on GitHub. This is the last gate before mutation.
    if args.apply:
        principals = verify_owner_principals(args.repo, committed_text)
        if principals:
            print("REFUSE: owner principals in the CODEOWNERS committed on {} ({}) could not be "
                  "verified on {} — require_code_owner_review would bind no reviewer for "
                  "them:".format(ref, committed_rel, args.repo), file=sys.stderr)
            for p in principals:
                print("  - {}".format(p), file=sys.stderr)
            return 1

    for line in _plan_lines(gh, args.repo, args.apply):
        print(line)

    if not args.apply:
        print("(dry-run: pass --apply to create/update; nothing was changed)")
        print("  note: --apply additionally binds validation to {}'s LIVE default branch (and its "
              "current tip) and live-verifies every CODEOWNERS owner principal has write access. "
              "Dry-run makes no network calls, so neither is checked here.".format(args.repo))
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
