#!/usr/bin/env python3
"""Freeze and execute source-owned build validation contracts.

U6 adds a machine-owned validation contract for Build:
  * baseline classification (expected-red vs expected-green) before implementation;
  * an immutable frozen contract the builder cannot edit;
  * source-owned execution receipts for the frozen verification commands.
"""
from __future__ import annotations

import argparse
import calendar
import contextlib
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:                                      # non-POSIX (e.g. Windows) — no advisory locks
    fcntl = None

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

import idc_matrix_check  # noqa: E402
import idc_schema_check  # noqa: E402

SCHEMA_VERSION = 1
CONTRACT_KIND = "build-validation-contract"
EXECUTION_KIND = "verification-execution"
WITNESS_FILE = "idc-build-validation-witnesses.json"

# THE SINGLE SURFACE→EVIDENCE TABLE. It lives in `idc_schema_check` (the module that owns every fixed
# schema surface) and is IMPORTED here rather than restated. There were two independent literal copies
# — one here, one there — with nothing asserting they agreed, and the registry resolver
# (`idc_verification_handles.resolve_handle`) types handles from the schema-check copy while this
# module froze contracts from its own. A one-sided edit therefore produced a registry-LEGAL handle that
# freezes an ILLEGAL contract, and no test in the repo could see it. One name, one dict, no lock-step
# assertion to forget: an equality test only detects drift, deleting the duplicate makes drift
# impossible. The import is HARD (not tolerant) exactly like `idc_matrix_check` above — a relocated
# lone copy of this module has never been able to run without its siblings.
SURFACE_EVIDENCE_TABLE = idc_schema_check.SURFACE_EVIDENCE_TABLE

# Positive producibility patterns: a command set must contain at least one command that can plausibly
# emit the declared evidence kind. `pane-capture` deliberately has NO entry here — see
# `_static_check_problem`: "any command at all produces a pane capture" is true and therefore useless,
# so the CLI slot is guarded by the all-static rule instead of a pattern that matches everything.
EVIDENCE_PATTERNS = {
    "response-body": [re.compile(r"\b(curl|httpie|wget|fetch)\b", re.I)],
    "screenshot-or-recording": [re.compile(r"\b(playwright|cypress|selenium|puppeteer|screenshot|record)\b", re.I)],
    "public-import-sample": [re.compile(r"\b(import\b|require\(|python\s+-c\b|node\s+-e\b|ruby\s+-e\b)", re.I)],
    "agent-run-capture": [re.compile(r"\b(claude|codex|pi|agent)\b", re.I)],
    "check-run": [re.compile(r"\b(gh\s+run|gh\s+workflow|check-run|ci)\b", re.I)],
}

# ── the all-static verification surface, as a MACHINE rule ────────────────────────────────────────
# `skills/idc-review-engine/SKILL.md` already states this as prose a reviewer must judge: "a surface
# whose commands are ALL static checks (file-exists, parse, lint/typecheck, `terraform validate`/`fmt`,
# arch-fence `pytest -k arch`, import probes) with NO command exercising the GOAL's observable
# end-state lets an INERT deliverable pass as Done." Recommendation 1's whole point is that this
# prose rule generalizes into a machine rule, and this is that rule.
#
# A command is decomposed into SEGMENTS on `&&`, `||`, `;` and `|`, and each segment is classed:
#   STATIC  — a recognized static check (below);
#   INERT   — a no-op that exercises nothing (`true`, `false`, `:`, `exit N`, `echo …`, `cd …`);
#   OTHER   — anything else, i.e. something that MIGHT drive the surface.
# The set is refused only when at least one segment is STATIC and every segment is STATIC-or-INERT.
# Both halves matter: without the "at least one STATIC" clause a placeholder `true` gate would be
# refused by a rule that is not about placeholders (a different failure, owned by the baseline
# classifier), and without the "every segment" clause `test -f x && bash drive-it.sh` — a static
# precondition guarding a real drive — would be refused for having a static part.
STATIC_CHECK_PATTERNS = [
    re.compile(r"^\[\s+-[a-z]\s"),                                        # [ -f path ]
    re.compile(r"^test\s+-[a-z]\b"),                                      # test -f / -d / -e …
    re.compile(r"^(e|f|z|r|)grep\b"),                                     # grep family
    re.compile(r"^(ruff|flake8|pylint|mypy|pyright|tsc|eslint|shellcheck|golangci-lint|clippy)\b", re.I),
    re.compile(r"^terraform\s+(validate|fmt)\b", re.I),
    re.compile(r"\bpy_compile\b"),
    re.compile(r"^python[0-9.]*\s+-c\s+['\"]?\s*import\b", re.I),         # bare import probe
    re.compile(r"^node\s+-e\s+['\"]?\s*require\([^)]*\)\s*['\"]?$", re.I),  # bare require probe
    re.compile(r"^pytest\b.*\s-k\s+['\"]?arch", re.I),                    # arch-fence pytest
]
INERT_SEGMENT_PATTERNS = [
    re.compile(r"^(true|false|:)$"),
    re.compile(r"^exit\s+\d+$"),
    re.compile(r"^echo\b"),
    # `cat f | grep -q x` and `printf '%s' x | grep -q y` are the two piped shapes that used to pass a
    # purely static gate: `cat`/`printf` classed OTHER, which satisfied the "something might drive the
    # surface" clause all by itself. Neither exercises anything.
    re.compile(r"^(cat|printf)\b"),
    re.compile(r"^cd\s"),
    re.compile(r"^set\s+-"),
]
_SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|]")

# The lint/typecheck arm of the static-check rule, ANCHORED TO THE PROGRAM TOKEN. As a free search
# over the whole segment it classed ANY command containing the word "lint" as a static check, with no
# override: `npm run lint:e2e` and `bash e2e/lint-fix-flow.sh` — a lint task with a real end-to-end arm,
# and a script that fixes and re-drives — were refused as inert. The rule is about what the segment
# RUNS, so it now tests only the tokens that NAME what it runs: the program, plus the task/script name
# after a known runner. A task called exactly `lint` (or `lint.sh`) still classes static; one whose
# name merely contains it does not.
STATIC_TASK_TOKEN = re.compile(
    r"^(lint|typecheck|type-check|format-check|fmt-check)(\.(sh|bash|py|js|mjs|ts))?$", re.I)
_RUNNER_TOKENS = {"bash", "sh", "zsh", "make", "just", "task", "npm", "pnpm", "yarn", "bun", "npx",
                  "pnpx", "uv", "poetry", "pdm", "rye", "cargo", "go", "deno", "rake", "mise"}
_RUNNER_SUBCOMMANDS = {"run", "exec", "dlx", "x", "--"}


def _program_tokens(segment: str):
    """The tokens that NAME what a segment runs: its program, plus the task name after a known runner.

    Flags and everything past the program are arguments, not the program — `pytest tests/lint_test.py`
    runs pytest over a file that happens to be named for linting."""
    tokens = []
    for raw in segment.split():
        if raw.startswith("-") and raw != "--":
            continue
        base = raw.rsplit("/", 1)[-1]
        tokens.append(base)
        if base.lower() not in _RUNNER_TOKENS and base.lower() not in _RUNNER_SUBCOMMANDS:
            break
    return tokens


class ValidationError(Exception):
    pass


def die(message: str, code: int = 1):
    sys.stderr.write(f"idc-validation-contract: {message}\n")
    sys.exit(code)


def sha256_json(value) -> str:
    blob = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _clip(text: str | None, limit: int = 400) -> str:
    if not text:
        return ""
    text = str(text)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _abs_repo(repo: str) -> str:
    repo_abs = os.path.abspath(repo)
    if not os.path.isdir(repo_abs):
        raise ValidationError(f"repo directory does not exist: {repo}")
    return repo_abs


def _read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _common_git_dir(cwd: str) -> str:
    proc = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if proc.returncode != 0:
        proc = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if proc.returncode != 0:
            detail = _clip(CS.scrub(proc.stderr or proc.stdout or "git rev-parse failed"), 200)
            raise ValidationError(f"{cwd} is not inside a governed git repository ({detail})")
        raw = proc.stdout.strip()
        if not os.path.isabs(raw):
            raw = os.path.abspath(os.path.join(cwd, raw))
        return os.path.realpath(raw)
    return os.path.realpath(os.path.abspath(proc.stdout.strip()))


def _repo_identity(path: str) -> str:
    return os.path.realpath(os.path.dirname(_common_git_dir(path)))


def _repo_context(path: str):
    abs_path = os.path.realpath(os.path.abspath(path))
    parent = os.path.dirname(abs_path) or "."
    common_git_dir = _common_git_dir(parent)
    repo_root = os.path.realpath(os.path.dirname(common_git_dir))
    try:
        rel = os.path.relpath(abs_path, repo_root)
    except ValueError as exc:
        raise ValidationError(f"could not relativize {path} under the repo root ({exc})") from exc
    if rel == ".." or rel.startswith(".." + os.sep):
        raise ValidationError(f"{path} must live under the governed repo root {repo_root}")
    return repo_root, common_git_dir, rel


def _witness_path(common_git_dir: str) -> str:
    return os.path.join(common_git_dir, WITNESS_FILE)


def _read_witnesses(common_git_dir: str):
    path = _witness_path(common_git_dir)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _digest_file(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


@contextlib.contextmanager
def _witness_store_lock(common_git_dir: str):
    """Serialize the witness-store read-modify-write across concurrent recorders (F30).

    The store is ONE shared file in the git COMMON dir, written by stages that can run concurrently in
    different linked worktrees of the same repo — e.g. a Plan recording a PLANNING witness while a Build
    freeze records a CONTRACT witness. `os.replace` makes the final swap atomic, but each recorder does
    read-whole-store → mutate one key → replace, and the read→mutate is NOT covered by that atom. Two
    writers that both read the pre-image lose-update (whole-file last-writer-wins), dropping one
    witness and leaving a receipt witness-less → a later Build borrow fails closed with 'no machine-owned
    witness' (the same fail-closed refusal F27 exists to prevent). An exclusive advisory lock held
    across the WHOLE read→write makes concurrent recorders serialize instead. On a platform without
    `fcntl` the lock degrades to a no-op (best-effort); the plugin's supported hosts are POSIX."""
    if fcntl is None:
        yield
        return
    lock_path = os.path.join(common_git_dir, WITNESS_FILE + ".lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _record_witness(kind: str, path: str, doc: dict):
    repo_root, common_git_dir, rel = _repo_context(path)
    digest = _digest_file(path)
    with _witness_store_lock(common_git_dir):            # F30: RMW under an exclusive lock
        witnesses = _read_witnesses(common_git_dir)
        if witnesses is None:
            raise ValidationError("the validation witness store is unreadable")
        witnesses[rel] = {
            "kind": kind,
            "digest": digest,
            "repo_root": repo_root,
            "issue": doc.get("issue"),
            "pr": doc.get("pr"),
            "head": doc.get("head"),
            "diff_digest": doc.get("diff_digest"),
            "contract_digest": doc.get("contract_digest"),
            "validated_at": _now(),
            "validator": os.path.basename(__file__),
        }
        target = _witness_path(common_git_dir)
        fd, tmp = tempfile.mkstemp(prefix=".idc-build-validation.", suffix=".tmp", dir=common_git_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(witnesses, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.replace(tmp, target)
        except OSError as exc:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise ValidationError(f"could not record the validation witness for {rel} ({exc})") from exc
    return rel


def _witness_problem(kind: str, path: str, doc: dict):
    try:
        repo_root, common_git_dir, rel = _repo_context(path)
    except ValidationError as exc:
        return str(exc)
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        return "the validation witness store is unreadable"
    rec = witnesses.get(rel)
    if not isinstance(rec, dict):
        return f"no source-owned validation witness is recorded for {rel}"
    if rec.get("kind") != kind:
        return f"the validation witness for {rel} is for {rec.get('kind')!r}, not {kind!r}"
    if rec.get("repo_root") != repo_root:
        return f"the validation witness for {rel} names repo {rec.get('repo_root')!r}, not this repo"
    try:
        digest = _digest_file(path)
    except OSError as exc:
        return f"could not re-read {rel} to verify its witness ({exc})"
    if rec.get("digest") != digest:
        return f"the validation witness for {rel} is stale — its digest no longer matches the file"
    for key in ("issue", "pr", "head", "diff_digest", "contract_digest"):
        expected = rec.get(key)
        actual = doc.get(key)
        if expected is not None and actual is not None and expected != actual:
            return f"the validation witness for {rel} is for {key}={expected!r}, not {actual!r}"
    return None


# --- Planning-receipt witness -------------------------------------------------------------------
# A planning receipt is written during Plan and BORROWED at Build freeze, so — unlike the contract /
# execution / build-receipt witnesses, which are recorded and verified within a single Build worktree
# lifecycle — its witness must survive travelling from the checkout Plan ran in to a DIFFERENT Build
# worktree of the same repo. It is therefore keyed by the receipt's path relative to its OWN worktree
# toplevel (the stable logical repo path `docs/workflow/planning-receipts/<label>.json`, identical in
# every worktree) rather than the primary-checkout-relative path (`_repo_context`, which embeds the
# worktree subdir and so differs per worktree). The store still lives in the shared git common dir and
# still binds the stable repo identity (the primary checkout root), so a foreign-repo receipt is
# refused (F7) while a legitimate cross-worktree receipt is recognized (F19).
PLANNING_WITNESS_KIND = "planning-receipt"


def _worktree_toplevel(path: str) -> str:
    proc = subprocess.run(
        ["git", "-C", path, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, timeout=15)
    if proc.returncode != 0:
        detail = _clip(CS.scrub(proc.stderr or proc.stdout or "git rev-parse failed"), 200)
        raise ValidationError(f"{path} is not inside a git worktree ({detail})")
    return os.path.realpath(proc.stdout.strip())


def _planning_witness_context(receipt_path: str):
    """`(common_git_dir, repo_identity, logical_rel)` for a planning receipt.

    `logical_rel` is the receipt's path relative to its own worktree toplevel (stable across linked
    worktrees); `repo_identity` is the shared primary checkout root; the store is the common git dir."""
    abs_path = os.path.realpath(os.path.abspath(receipt_path))
    parent = os.path.dirname(abs_path) or "."
    common_git_dir = _common_git_dir(parent)
    repo_identity = os.path.realpath(os.path.dirname(common_git_dir))
    toplevel = _worktree_toplevel(parent)
    rel = os.path.relpath(abs_path, toplevel)
    if rel == ".." or rel.startswith(".." + os.sep):
        raise ValidationError(
            f"planning receipt {receipt_path} must live under its worktree root {toplevel}")
    return common_git_dir, repo_identity, rel


def _planning_witness_key(rel: str) -> str:
    return f"{PLANNING_WITNESS_KIND}:{rel}"


def _embedded_receipt_digest(raw: bytes):
    """The `receipt_digest` a planning receipt commits to inside its own bytes, or None if the bytes do
    not parse as a receipt object. Read from the SAME bytes the witness keys on, so the recorded
    (byte-digest -> receipt_digest) binding is always internally consistent (F38)."""
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return doc.get("receipt_digest") if isinstance(doc, dict) else None


PLANNING_WITNESS_RETAIN = 8

# AGE-AWARE retention (see `_evict_stale_versions`). A pure count-8 cap is measured in RE-APPLIES, not
# in time, so a burst of same-label Plan re-applies can evict a version an in-flight Build is still
# holding — `planning_witness_problem` is consulted exactly ONCE, at Build contract freeze, so the
# window between a Build claiming work and freezing it is exactly where that eviction strands a
# LEGITIMATE receipt. The grace window is sized to the real thing being protected: a Build claims and
# freezes within days, not weeks.
PLANNING_WITNESS_GRACE_SECONDS = 7 * 24 * 3600
# ...but the F31 boundedness guarantee must survive the grace window, or a re-apply loop inside 7 days
# grows the in-.git store without limit again. Beyond this many retained versions, eviction resumes
# oldest-first EVEN INSIDE grace, so the bucket is bounded by a constant no matter the re-apply rate.
PLANNING_WITNESS_HARD_CAP = 64


def _witness_age_seconds(validated_at, now_epoch):
    """Age in seconds of a witness record's `validated_at`, or None when it cannot be parsed.

    `_now()` emits UTC `%Y-%m-%dT%H:%M:%SZ`, which ambient Python 3.9 parses with `time.strptime` +
    `calendar.timegm` (no `datetime.fromisoformat` 'Z' handling, which only arrived in 3.11). A record
    written by an older/newer format — or with the field absent — returns None and is treated as NOT
    grace-protected, so it falls back to the count rule. That is the fail-closed direction: an
    unparseable stamp can only cause an EVICTION, and an evicted version is refused stale (never
    false-accepted)."""
    if not validated_at:
        return None
    try:
        parsed = time.strptime(str(validated_at), "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, TypeError):
        return None
    return now_epoch - calendar.timegm(parsed)


def _record_validated_at(rec) -> str:
    """A witness record's `validated_at` as a STRING, always — `""` when the record does not carry a
    usable one (F43).

    `_witness_age_seconds` is carefully defensive about a stamp it cannot PARSE, but the eviction SORT
    one caller up was not defensive about a stamp of the wrong TYPE. `sorted()` on a key of
    `(validated_at or "", digest)` compares tuples element-wise, so a record whose `validated_at` is a
    JSON number, object or array compares `int`/`dict`/`list` against `str` and raises an uncaught
    `TypeError`. That crash lands in the WORST place: `record_planning_witness` has already replaced
    the receipt on disk by then and the witness store is written after eviction, so the new receipt is
    left UNWITNESSED and a later Build refuses it. Both value-shaped reads of the field go through
    here, so the shape is normalized once rather than at each call site.

    A NON-DICT record normalizes too. The store's container and its `witnesses` map are shape-checked
    on read, but the individual records inside were not, so `rec.get(...)` on a hand-edited store
    raised `AttributeError` on the same line for the same reason.

    `""` is deliberately the answer for every unusable shape, rather than `str(rec)`: it sorts OLDEST
    and `_witness_age_seconds` reads it as unparseable, so such a record is evicted first and is never
    grace-protected — identical to the treatment an unparseable STRING stamp already gets, and the
    same fail-closed direction (an evicted version is refused stale, never false-accepted). Reaching
    any of this needs a hand-edited or corrupted store: this module is the only writer, and `_now()`
    has only ever emitted a string."""
    if not isinstance(rec, dict):
        return ""
    stamp = rec.get("validated_at")
    return stamp if isinstance(stamp, str) else ""


def _evict_stale_versions(bucket: dict, receipt_path: str) -> None:
    """Bound the per-path planning-witness bucket (F31). `record_planning_witness` ADDS a version per
    receipt byte digest so a same-label rerun does not clobber the one an in-flight Build still borrows
    (F27) — but each same-projection re-apply embeds a fresh `created_at` → new bytes → new digest → a
    new entry, so repeated recirc re-applies would otherwise grow the bucket (and the in-.git store)
    without bound.

    Retention is count+age hybrid. ALWAYS KEEP the UNION of (a) and (b) — they are independent
    guarantees and neither consumes the other's budget, so the retained floor is
    `PLANNING_WITNESS_RETAIN` versions PLUS the live one when it is not already among them:
      (a) the receipt's CURRENT on-disk digest — always borrowable;
      (b) the newest PLANNING_WITNESS_RETAIN versions by `validated_at`;
      (c) ANY version whose `validated_at` is within PLANNING_WITNESS_GRACE_SECONDS of now (a stamp
          in the FUTURE is not "recent" and gets no grace) —
          bounded by PLANNING_WITNESS_HARD_CAP, beyond which eviction resumes oldest-first even
          inside the grace window so (b)'s boundedness guarantee survives.

    (c) is why this is not a pure count: a Build consults `planning_witness_problem` exactly ONCE, at
    contract freeze, so re-apply churn between a Build CLAIMING work and FREEZING it could evict the
    version it legitimately holds — the count cap measures re-applies, not the time a Build actually
    takes. Inside the grace window that can no longer happen.

    RESIDUAL, stated honestly: a Build that takes longer than the grace window, or that is buried under
    more than PLANNING_WITNESS_HARD_CAP newer versions, can still have its version evicted. That
    remains the fail-closed direction — an evicted version is REFUSED stale and the Build re-anchors
    its receipt via the existing recovery message; it is never false-accepted."""
    if len(bucket) <= PLANNING_WITNESS_RETAIN:
        return
    try:
        live = _digest_file(receipt_path)
    except OSError:
        live = None
    now_epoch = time.time()
    # newest first by validated_at; digest is a stable tiebreaker for records written the same second.
    ordered = [dg for dg, _rec in sorted(
        bucket.items(), key=lambda kv: (_record_validated_at(kv[1]), kv[0]), reverse=True)]
    # (b) FIRST and on its own counter, then (a) unioned in. Seeding `keep` with the live digest and
    # then filling to RETAIN meant the live version CONSUMED one of the newest-RETAIN slots, so the
    # retained set was `live` + newest-(RETAIN-1) rather than the documented `live` UNION newest-RETAIN
    # — with the live receipt the OLDEST entry, the 8th-newest version was evicted even though the
    # stated rule keeps it. The two clauses are independent guarantees and must not share a budget.
    keep = set()
    for dg in ordered:                                  # (b) the newest RETAIN by validated_at
        if len(keep) >= PLANNING_WITNESS_RETAIN:
            break
        keep.add(dg)
    if live in bucket:                                  # (a) the live on-disk version, always borrowable
        keep.add(live)
    # (c) grace window, newest-first so the HARD CAP drops the OLDEST in-grace versions first.
    for dg in ordered:
        if len(keep) >= PLANNING_WITNESS_HARD_CAP:
            break
        if dg in keep:
            continue
        age = _witness_age_seconds(_record_validated_at(bucket[dg]), now_epoch)
        # `0 <= age`: a FUTURE `validated_at` (clock skew, a hand-edited store, a record written on a
        # machine running fast) yields a NEGATIVE age, which satisfies `age <= GRACE` and would let a
        # skewed record claim grace protection indefinitely — and, worse, consume hard-cap slots ahead
        # of legitimately recent versions. A stamp in the future is not evidence of recency, so it is
        # simply not grace-protected and falls back to the count rule, exactly like an unparseable one.
        if age is not None and 0 <= age <= PLANNING_WITNESS_GRACE_SECONDS:
            keep.add(dg)
    for dg in [d for d in bucket if d not in keep]:
        del bucket[dg]


def record_planning_witness(receipt_path: str, doc: dict, *, write_receipt=None) -> str:
    """Record the out-of-tree machine witness for a freshly written planning receipt (called by the
    sanctioned transaction). Keyed by the worktree-relative logical path so a Build contract frozen in
    a different worktree can find it; and WITHIN that key, keyed by the receipt's BYTE digest so a
    same-label rerun ADDS a witness rather than REPLACING the one an in-flight Build still depends on
    (F27). The label default is stable across same-projection reruns (`planning-<sha256(projection)
    [:12]>`), so the logical path is identical on re-apply — but `build_receipt` embeds a fresh
    `created_at`, so the receipt BYTES differ. A single-entry witness would overwrite, invalidating a
    Build worktree that still holds the earlier committed receipt (the F19 cross-worktree handoff).
    Retaining byte versions keeps each legitimate receipt borrowable while a re-signed forgery — whose
    bytes match NO recorded version — is still refused (F7). The retained set is BOUNDED by the
    count+age hybrid in `_evict_stale_versions` — the current on-disk version, the newest
    PLANNING_WITNESS_RETAIN, and anything inside PLANNING_WITNESS_GRACE_SECONDS, all capped at
    PLANNING_WITNESS_HARD_CAP — so repeated same-label re-applies cannot grow the in-.git store without
    limit (F31), and cannot evict the version a not-yet-frozen Build is holding WITHIN THOSE BOUNDS:
    while that version is still inside PLANNING_WITNESS_GRACE_SECONDS and not buried under
    PLANNING_WITNESS_HARD_CAP newer ones. Past either bound it CAN be evicted — `_evict_stale_versions`
    states that residual and why it stays fail-closed (the Build is refused as stale and re-anchors its
    receipt; it is never false-accepted). Do not restate this guarantee unqualified: the code delivers
    the bounded version of it. The read-modify-write runs under
    an exclusive store lock so a concurrent contract-witness write cannot drop it (F30). The receipt is
    read ONCE, under that same lock, so the byte-digest key and the receipt's embedded self-digest are
    taken from a single view — a concurrent same-path rewrite cannot bind one version's bytes to
    another version's receipt_digest (F38).

    `write_receipt` (optional) is the callable that PUTS the receipt on disk. When the sanctioned
    transaction passes it, the file replacement happens INSIDE this lock, making the replace and the
    witness record one critical section (F54). With the replace outside, two same-label writers could
    interleave as: A writes bytes A and witnesses them; B replaces the file with bytes B and then dies
    before witnessing — leaving the FINAL on-disk bytes unwitnessed, so a later Build refuses a Plan
    that reported success. The F38 guard below cannot repair that: it acts at record time and cannot
    retroactively invalidate the witness A already recorded. Holding the lock across both steps means a
    second writer cannot replace the file until the first has witnessed whatever it wrote."""
    common_git_dir, repo_identity, rel = _planning_witness_context(receipt_path)
    with _witness_store_lock(common_git_dir):            # F30/F38/F54: replace + RMW + read, one lock
        if write_receipt is not None:
            write_receipt()                              # F54: the atomic replace, inside the section
        # F38: read the receipt's bytes ONCE, under the lock, and derive the byte-digest key from THAT
        # read. Digesting before the lock (or in a read separate from the freshness check below) lets a
        # concurrent same-path writer replace the receipt between reads, so the entry binds one
        # version's bytes to another version's `receipt_digest`; the final on-disk receipt then matches
        # a witness whose receipt_digest is wrong and Build refuses the legitimate receipt (fail-closed).
        try:
            with open(receipt_path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            raise ValidationError(
                f"could not read the planning receipt to witness it ({exc})") from exc
        digest = hashlib.sha256(raw).hexdigest()
        # The receipt embeds its own receipt_digest. If the bytes on disk no longer carry the digest the
        # caller computed for the receipt IT wrote, a concurrent writer clobbered this path after
        # write_receipt wrote it — refuse rather than record the caller's stale doc against another
        # version's bytes (F38). The writer whose bytes are actually on disk records a self-consistent
        # witness, so its receipt stays borrowable; only the losing racer fails closed.
        on_disk_digest = _embedded_receipt_digest(raw)
        doc_digest = doc.get("receipt_digest")
        if doc_digest is not None and on_disk_digest is not None and on_disk_digest != doc_digest:
            raise ValidationError(
                "the planning receipt on disk was overwritten by a concurrent writer while its witness "
                "was being recorded — refusing to bind a stale receipt version to the current bytes (F38)")
        witnesses = _read_witnesses(common_git_dir)
        if witnesses is None:
            raise ValidationError("the validation witness store is unreadable")
        key = _planning_witness_key(rel)
        container = witnesses.get(key)
        if (not isinstance(container, dict) or container.get("kind") != PLANNING_WITNESS_KIND
                or not isinstance(container.get("witnesses"), dict)):
            container = {"kind": PLANNING_WITNESS_KIND, "witnesses": {}}
        container["witnesses"][digest] = {
            "repo_identity": repo_identity,
            "label": doc.get("label"),
            "receipt_digest": doc.get("receipt_digest"),
            "validated_at": _now(),
            "validator": os.path.basename(__file__),
        }
        _evict_stale_versions(container["witnesses"], receipt_path)   # F31: bound the retained set
        witnesses[key] = container
        target = _witness_path(common_git_dir)
        fd, tmp = tempfile.mkstemp(prefix=".idc-build-validation.", suffix=".tmp", dir=common_git_dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(witnesses, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.replace(tmp, target)
        except OSError as exc:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise ValidationError(f"could not record the planning-receipt witness for {rel} ({exc})") from exc
    return rel


# A receipt whose path has NO witness entry at all is either (a) minted by a pre-witness build of the
# plugin — an upgrade that landed between a Plan and its Build — or (b) hand-forged at a path the
# machine never wrote. Nothing in the receipt distinguishes them: `schema_version` did not change when
# witnessing was introduced, and every in-band field is forgeable (that is why the witness exists). So
# this can never be auto-accepted or re-anchored — doing so would hand a forger the exact bypass F7
# closes. What CAN be fixed is the diagnosis: name the sanctioned recovery so the operator hitting the
# legitimate upgrade case is not left guessing (F55).
LEGACY_RECEIPT_RECOVERY = (
    "if this Plan predates the planning-receipt witness (an upgrade landed between Plan and Build), "
    "re-run the sanctioned Plan apply to mint a fresh witnessed receipt — the receipt cannot be "
    "re-anchored in place, because a forged receipt is indistinguishable from a pre-witness one"
)


def planning_witness_problem(receipt_path: str, doc: dict):
    """Refusal reason if the planning receipt is not machine-anchored, else None."""
    try:
        common_git_dir, repo_identity, rel = _planning_witness_context(receipt_path)
    except ValidationError as exc:
        return str(exc)
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        return "the validation witness store is unreadable"
    container = witnesses.get(_planning_witness_key(rel))
    if not isinstance(container, dict) or container.get("kind") != PLANNING_WITNESS_KIND:
        return f"no machine-owned witness is recorded for planning receipt {rel} — {LEGACY_RECEIPT_RECOVERY}"
    bucket = container.get("witnesses")
    if not isinstance(bucket, dict):
        return f"no machine-owned witness is recorded for planning receipt {rel} — {LEGACY_RECEIPT_RECOVERY}"
    try:
        digest = _digest_file(receipt_path)
    except OSError as exc:
        return f"could not re-read {rel} to verify its witness ({exc})"
    # Match by BYTE digest: a same-label rerun ADDS a version, so an in-flight Build holding an earlier
    # receipt still finds its own version; a re-signed forgery matches no recorded version (F7/F27).
    rec = bucket.get(digest)
    if not isinstance(rec, dict):
        return (f"the planning-receipt witness for {rel} is stale — its byte digest matches no recorded "
                f"machine witness; {LEGACY_RECEIPT_RECOVERY}")
    if rec.get("repo_identity") != repo_identity:
        return f"the planning-receipt witness for {rel} names repository {rec.get('repo_identity')!r}, not this repo"
    expected_self = rec.get("receipt_digest")
    actual_self = doc.get("receipt_digest")
    if expected_self is not None and actual_self is not None and expected_self != actual_self:
        return f"the planning-receipt witness for {rel} vouches for a different receipt version"
    return None


def atomic_write_json(path: str, data):
    parent = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".idc-build-validation-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = ""
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def _ensure_hex(label: str, value: str, width: int = 64) -> str:
    text = str(value or "").strip()
    if not re.fullmatch(rf"[0-9a-f]{{{width}}}", text):
        raise ValidationError(f"{label} must be {width} lowercase hex characters (got {value!r})")
    return text


def _normalize_surfaces(values, label: str):
    if not values:
        raise ValidationError(f"{label} must declare at least one surface")
    normalized = []
    seen = set()
    for raw in values:
        info = idc_matrix_check.normalize_surface(raw)
        if info["normalized"] not in seen:
            normalized.append(info["normalized"])
            seen.add(info["normalized"])
    return normalized


def _git(repo: str, *args: str, text: bool = True):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=text)
    if proc.returncode != 0:
        detail = _clip(CS.scrub(proc.stderr or proc.stdout or f"git {' '.join(args)} failed"), 200)
        raise ValidationError(f"git {' '.join(args)} failed: {detail}")
    return proc.stdout if text else proc.stdout


def git_head(repo: str, ref: str = "HEAD") -> str:
    return _git(repo, "rev-parse", ref).strip()


def git_diff_info(repo: str, base_commit: str, ref: str = "HEAD"):
    diff = subprocess.run(["git", "-C", repo, "diff", "--binary", f"{base_commit}...{ref}"], capture_output=True)
    if diff.returncode != 0:
        detail = _clip(CS.scrub((diff.stderr or diff.stdout or b"git diff failed").decode("utf-8", "replace")), 200)
        raise ValidationError(f"git diff --binary {base_commit}...{ref} failed: {detail}")
    names = _git(repo, "diff", "--name-only", f"{base_commit}...{ref}")
    changed = sorted({line.strip() for line in names.splitlines() if line.strip()})
    return {
        "diff_digest": sha256_bytes(diff.stdout),
        "changed_paths": changed,
    }


# THE SAME REDACTION PROFILE AS THE REPO'S OTHER COMMITTED-EVIDENCE WRITER. `CS.scrub` alone is the
# shared floor: it catches what NAMES itself a secret or carries a vendor's documented prefix, and
# nothing else. A gate's output is not that kind of text — it is an UNPREDICTABLE CAPTURE from a
# project's own verify probe, which is precisely the case `idc_credential_shapes` names when it says
# the opaque-run backstop is affordable "where the text is an unpredictable capture … whose output
# nobody can characterise in advance". `idc_live_check.py`, the only other module writing probe output
# into a committed file, applies `machine_output_redactors() + backstop`; this path applied the floor,
# so a bare AWS secret access key, an Azure `AccountKey=…`, a base64/hex blob and a PEM body with no
# footer still reached a git-committed file. Same provenance, same profile.
#
# The backstop is a GUESS ("a long opaque run is a credential we have no name for"), so it is declared
# HERE rather than in the shared table — see that module on why it must never run over prose or over a
# structured diagnostic, where a 40-character run is the commit sha the message exists to carry.
_OPAQUE_RUN_BACKSTOP = re.compile(r"\b[A-Za-z0-9_\-]{40,4096}\b")
MAX_CAPTURE_CHARS = 17 * 1024


def _gate_evidence(scrubbed: str | None) -> str:
    """Apply the opaque-run backstop to a capture that has ALREADY been through the scrub door.

    THE BOUND SITS HERE AND NOT IN FRONT OF `CS.scrub`, deliberately. A cut taken before the door
    destroys the left context every shared rule anchors on — the URL rule its scheme, the auth rule its
    verb, the PEM rule its BEGIN line — which is why `tests/smoke/phase11-honesty-repro.sh` R28 refuses
    a truncation inside a scrub call outright. So the shared profile still walks the whole capture
    (every quantifier in it is bounded), and only this last rule is bounded to the head `_clip` keeps
    anyway. Cutting the HEAD, not the tail, is what makes that lossless: nothing that reaches the
    stored excerpt was ever outside the bound."""
    out = scrubbed or ""
    if len(out) > MAX_CAPTURE_CHARS:
        out = out[:MAX_CAPTURE_CHARS] + f"\n[capture bounded at {MAX_CAPTURE_CHARS} characters]"
    return _OPAQUE_RUN_BACKSTOP.sub("[REDACTED]", out)


# A gate that hangs hangs the freeze, with no bound at all — spec §3.4 names "timeout" as a stopping
# condition and this runner had none. `idc_live_check` sources its own the same way: a default, raised
# or lowered per surface. The timeout is a REFUSAL, not a red baseline: a gate that could not finish
# established nothing, and recording that as `expected-red` would let a hanging command freeze as a
# legitimate baseline.
DEFAULT_VERIFY_TIMEOUT = 600


def _verify_timeout() -> int:
    raw = str(os.environ.get("IDC_VERIFY_TIMEOUT") or "").strip()
    if not raw:
        return DEFAULT_VERIFY_TIMEOUT
    try:
        seconds = int(raw)
    except ValueError as exc:
        raise ValidationError(f"IDC_VERIFY_TIMEOUT must be a positive integer of seconds, got {raw!r}") from exc
    if seconds <= 0:
        raise ValidationError(f"IDC_VERIFY_TIMEOUT must be a positive integer of seconds, got {raw!r}")
    return seconds


def _verification_results(repo: str, commands):
    results = []
    timeout = _verify_timeout()
    for command in commands:
        try:
            proc = subprocess.run(
                ["/bin/bash", "-lc", command],
                cwd=repo,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired as exc:
            raise ValidationError(
                f"verification command timed out after {timeout}s and established nothing: {command!r} "
                "— raise IDC_VERIFY_TIMEOUT or make the gate terminate") from exc
        results.append({
            "command": command,
            "exit_code": int(proc.returncode),
            # BOTH streams go through the door AT THE READ, over the COMPLETE capture, before `_clip`
            # cuts the stored excerpt — so there is no partial match at the 400-character boundary.
            # `CS.scrub`'s docstring reserves itself for `stderr` because in this repo a child's stdout
            # is usually DATA that its reader PARSES (parsing redaction markers would be a bug). A gate
            # command's stdout is the exception that proves the rule: nothing parses it — it is stored
            # as bounded EVIDENCE in the frozen contract's `baseline.results` and in the execution
            # receipt's `declared_evidence.records`, and BOTH are COMMITTED repo files on the ticket's
            # branch. Bounded-but-raw was half a promise: spec §3.5 requires "bounded REDACTED
            # evidence", and a gate that prints a token to stdout wrote it verbatim into git history.
            "stdout_excerpt": _clip(_gate_evidence(CS.scrub(proc.stdout))),
            "stderr_excerpt": _clip(_gate_evidence(CS.scrub(proc.stderr))),
        })
    return results


def _matching_handle_commands(repo: str, handle_registry: str | None, handle_id: str | None,
                              surface: str | None, commands):
    if not handle_id:
        return surface, None, [str(cmd).strip() for cmd in (commands or []) if str(cmd).strip()]
    try:
        import idc_verification_handles as VH  # noqa: E402 — lazy: only U6 handle-backed contracts use this helper
    except ImportError as exc:
        raise ValidationError(f"verification-handle resolution requested, but idc_verification_handles.py is unavailable ({exc})") from exc
    if not surface:
        raise ValidationError("handle-backed validation contracts must declare --surface")
    if handle_registry:
        # CONTAINMENT ON THE READ PATH TOO. The commands this resolves are copied inline into the
        # committed contract and later executed through `/bin/bash -lc`, so `--handle-registry
        # <anywhere>` lets an out-of-tree file choose what the frozen gate runs, with nothing in the
        # governed repo to review. Its sibling write door (`append`) refuses the same shape.
        try:
            VH.registry_path(repo, handle_registry, must_be_inside_repo=True)
        except VH.HandleError as exc:
            raise ValidationError(
                f"--handle-registry {handle_registry} resolves outside the governed repo: {exc}") from exc
    result = VH.resolve_handle(repo=repo, handle_id=handle_id, surface=surface, override=handle_registry)
    handle = result.get("handle") or {}
    resolved_commands = [str(cmd).strip() for cmd in handle.get("verify_commands") or [] if str(cmd).strip()]
    explicit = [str(cmd).strip() for cmd in (commands or []) if str(cmd).strip()]
    if explicit and explicit != resolved_commands:
        raise ValidationError(
            f"handle_id {handle_id!r} resolved verify_commands {resolved_commands!r}, which do not exactly match the explicit --verify commands {explicit!r}")
    return surface, handle, resolved_commands



def _segments(command: str):
    return [seg.strip() for seg in _SEGMENT_SPLIT.split(command) if seg.strip()]


def _classify_segment(segment: str) -> str:
    if any(STATIC_TASK_TOKEN.fullmatch(token) for token in _program_tokens(segment)):
        return "static"
    for pattern in STATIC_CHECK_PATTERNS:
        if pattern.search(segment):
            return "static"
    for pattern in INERT_SEGMENT_PATTERNS:
        if pattern.search(segment):
            return "inert"
    return "other"


def _static_check_problem(commands) -> str | None:
    """The all-static verification-surface refusal, or None. See STATIC_CHECK_PATTERNS."""
    classes = [_classify_segment(seg) for cmd in commands for seg in _segments(cmd)]
    if not classes:
        return None
    if "other" in classes or "static" not in classes:
        return None
    return ("all-static verification surface refused: every declared command is a static check "
            "(file-exists / grep / lint / typecheck / parse or import probe / terraform validate|fmt / "
            "arch-fence pytest) with no command exercising the goal's observable end-state, so an inert "
            "deliverable would pass this gate — declare a command that runs, applies, queries or drives "
            "the surface, or declare surface:none with a one-line skip_reason")


def _evidence_problem(evidence_kind: str, surface: str, commands) -> str | None:
    if evidence_kind == "pane-capture":
        # A CLI pane capture is produced by literally any command that runs, so a positive pattern
        # here can only ever be `.` — a check that refuses nothing. The rule the CLI slot actually
        # owns is the all-static one.
        return _static_check_problem(commands)
    patterns = EVIDENCE_PATTERNS[evidence_kind]
    if not any(any(p.search(cmd) for p in patterns) for cmd in commands):
        return f"declared commands cannot produce evidence_kind {evidence_kind!r} for surface {surface!r}"
    return None


def _validation_surface(surface: str | None, evidence_kind: str | None, skip_reason: str | None, commands):
    commands = [str(cmd).strip() for cmd in (commands or []) if str(cmd).strip()]
    # AN UNDECLARED SURFACE IS NOT A DECLARATION. This used to default to `cli` whenever any command
    # was present, which made the whole surface-typing scheme opt-in: omitting `--surface` was easier
    # and free, and silently stored a gui/api ticket as cli/pane-capture. The declaration is the point
    # of the contract, so it is required.
    surface = str(surface or "").strip()
    if not surface:
        raise ValidationError(
            "a validation contract must declare its surface explicitly "
            f"(--surface {'|'.join(sorted(SURFACE_EVIDENCE_TABLE))}); an undeclared surface is not a declaration")
    if surface not in SURFACE_EVIDENCE_TABLE:
        raise ValidationError(f"surface must be one of {sorted(SURFACE_EVIDENCE_TABLE)}, got {surface!r}")
    expected = SURFACE_EVIDENCE_TABLE[surface]
    evidence_kind = evidence_kind or expected
    if evidence_kind != expected:
        raise ValidationError(
            f"surface/evidence pair mismatch: surface {surface!r} requires evidence_kind {expected!r}, got {evidence_kind!r}")
    if surface == "none":
        if commands:
            raise ValidationError("surface:none must not carry runnable verification commands")
        reason = str(skip_reason or "").strip()
        if not reason or "\n" in reason:
            raise ValidationError("surface:none requires a one-line skip_reason")
        return surface, expected, reason, []
    if skip_reason not in (None, ""):
        raise ValidationError("skip_reason is legal only when surface:none")
    if not commands:
        raise ValidationError("at least one --verify command is required unless surface:none")
    problem = _evidence_problem(expected, surface, commands)
    if problem:
        raise ValidationError(problem)
    return surface, expected, None, commands



def _declared_evidence(kind: str, surface: str, skip_reason: str | None, results):
    if kind == "none":
        return {"kind": kind, "surface": surface, "skip_reason": skip_reason, "records": []}
    records = []
    for row in results:
        records.append({
            "command": row.get("command"),
            "exit_code": row.get("exit_code"),
            "stdout_excerpt": _clip(row.get("stdout_excerpt")),
            "stderr_excerpt": _clip(row.get("stderr_excerpt")),
        })
    return {"kind": kind, "surface": surface, "skip_reason": None, "records": records}



def _baseline_state(results):
    return "expected-green" if all(row.get("exit_code") == 0 for row in results) else "expected-red"


def _contract_digest(doc: dict) -> str:
    body = dict(doc)
    body.pop("contract_digest", None)
    return sha256_json(body)


def _execution_digest(doc: dict) -> str:
    body = dict(doc)
    body.pop("execution_digest", None)
    return sha256_json(body)


def _planning_receipt_info(path: str):
    if not path:
        return None
    try:
        import idc_planning_receipt as PR  # noqa: E402 — sibling script on sys.path
    except ImportError as exc:
        raise ValidationError(
            f"cannot verify the planning receipt: idc_planning_receipt.py is unavailable ({exc})") from exc
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ValidationError(f"could not read planning receipt {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"planning receipt {path} is invalid JSON: {exc}") from exc
    # 1. Self-integrity — machine writer, recomputed self-digest, and internal
    #    projection/operations/final digests — so a lazily edited receipt is refused (F5).
    try:
        PR.verify_receipt_integrity(doc)
    except PR.ReceiptError as exc:
        raise ValidationError(f"planning receipt failed verification: {exc}") from exc
    # 2. OUT-OF-TREE MACHINE ANCHOR (F7). The receipt's written_by + receipt_digest are IN-BAND — a
    #    repo-local forger can swap a borrowed binding and recompute the self-digest, passing step 1.
    #    The authoritative proof of machine authorship is the witness the sanctioned transaction
    #    records in the git common dir when it writes the receipt (the same store the build-contract /
    #    execution / build receipts use): it lives outside the committed working tree a PR can edit and
    #    is keyed to the receipt file's byte digest, so a hand-forged or re-signed receipt has no
    #    matching witness and is refused. The common dir is shared across linked worktrees, so a
    #    receipt written by Plan in one worktree is recognized by a Build contract frozen in another
    #    worktree of the same repo (F19) — this supersedes the earlier realpath(receipt["repo"])
    #    compare, which rejected every worktree-produced receipt because freeze normalizes the repo to
    #    the primary checkout root while the receipt records the (worktree) checkout Plan ran in.
    problem = planning_witness_problem(path, doc)
    if problem:
        raise ValidationError(
            f"planning receipt is not machine-anchored ({problem}); refusing to borrow its bindings")
    return {
        "path": path,
        "graph_digest": doc.get("graph_digest"),
        "projection_digest": doc.get("projection_digest"),
        "final_digest": doc.get("final_digest"),
    }


DEFAULT_ATTEMPT_CEILING = 3


def _resolve_attempt_ceiling(workspace: str, attempt_ceiling: int | None) -> int:
    """The contract's attempt_ceiling: an explicit CLI value wins; otherwise default from the repo
    config (`pathway_enforcement.attempt_ceiling`, spec §2.1); otherwise the built-in default (F11).

    A config that DECLARES a malformed ceiling (non-integer / non-positive) is not silently swallowed:
    the operator gets a warning on stderr and the safe built-in default, mirroring the F10 mode
    hardening (F23). Only the sibling import is tolerated — a genuine parse/attribute bug in the reader
    propagates rather than being masked as 'unset', which the old blanket `except Exception` hid."""
    if attempt_ceiling is not None:
        return attempt_ceiling
    try:
        import idc_path_gate as PG  # noqa: E402 — sibling script on sys.path
    except ImportError:
        return DEFAULT_ATTEMPT_CEILING
    configured = PG.pathway_attempt_ceiling(workspace)
    if configured is PG.MALFORMED_ATTEMPT_CEILING:
        sys.stderr.write(
            "idc-validation-contract: WARNING — WORKFLOW-config.yaml declares a "
            "pathway_enforcement.attempt_ceiling that is not a positive integer; using the built-in "
            f"default {DEFAULT_ATTEMPT_CEILING}. Set a positive integer (or remove the key) to silence "
            "this.\n")
        return DEFAULT_ATTEMPT_CEILING
    return configured if configured is not None else DEFAULT_ATTEMPT_CEILING


def freeze_contract(*, repo: str, issue: int, pr: int, graph_node: str, graph_digest: str | None,
                    projection_digest: str | None, planning_receipt: str | None, touch, off_limits,
                    verify_commands, baseline: str, label: str, out: str, attempt_ceiling: int | None = None,
                    surface: str | None = None, evidence_kind: str | None = None,
                    skip_reason: str | None = None, handle_registry: str | None = None,
                    handle_id: str | None = None):
    workspace = _abs_repo(repo)
    attempt_ceiling = _resolve_attempt_ceiling(workspace, attempt_ceiling)
    repo = _repo_identity(workspace)
    planning = _planning_receipt_info(planning_receipt) if planning_receipt else None
    if planning:
        graph_digest = graph_digest or planning.get("graph_digest")
        projection_digest = projection_digest or planning.get("projection_digest")
    graph_node = str(graph_node or "").strip()
    if not graph_node:
        raise ValidationError("graph_node must be non-empty")
    graph_digest = _ensure_hex("graph_digest", graph_digest)
    projection_digest = _ensure_hex("projection_digest", projection_digest)
    if baseline not in {"expected-red", "expected-green"}:
        raise ValidationError(f"baseline must be expected-red or expected-green, got {baseline!r}")
    if attempt_ceiling <= 0:
        raise ValidationError("attempt_ceiling must be positive")
    surface, handle_doc, commands = _matching_handle_commands(repo, handle_registry, handle_id, surface, verify_commands)
    surface, evidence_kind, skip_reason, commands = _validation_surface(surface, evidence_kind, skip_reason, commands)
    touch_surfaces = _normalize_surfaces(touch, "touch")
    off_limits_surfaces = _normalize_surfaces(off_limits, "off-limits")
    base_commit = git_head(workspace)
    baseline_results = _verification_results(workspace, commands)
    actual = _baseline_state(baseline_results)
    if actual != baseline:
        raise ValidationError(f"unexpected-green baseline refusal: expected {baseline}, actual {actual}")
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kind": CONTRACT_KIND,
        "written_by": os.path.basename(__file__),
        "created_at": _now(),
        "repo": repo,
        "workspace": workspace,
        "label": str(label or "build-validation").strip() or "build-validation",
        "issue": int(issue),
        "pr": int(pr),
        "graph_node": graph_node,
        "graph_digest": graph_digest,
        "projection_digest": projection_digest,
        "planning_receipt": os.path.relpath(planning["path"], repo) if planning else None,
        "planning_final_digest": planning.get("final_digest") if planning else None,
        "base_commit": base_commit,
        "attempt_ceiling": int(attempt_ceiling),
        "touch": touch_surfaces,
        "off_limits": off_limits_surfaces,
        "surface": surface,
        "evidence_kind": evidence_kind,
        "skip_reason": skip_reason,
        "handle_id": handle_id,
        "handle_registry": (
            os.path.relpath(os.path.abspath(handle_registry), repo) if (handle_id and handle_registry)
            else ("docs/workflow/verification-handles.yaml" if handle_id else None)
        ),
        "verification": [{"command": cmd} for cmd in commands],
        "baseline": {
            "expected": baseline,
            "actual": actual,
            "head": base_commit,
            "results": baseline_results,
        },
    }
    doc["contract_digest"] = _contract_digest(doc)
    atomic_write_json(out, doc)
    _record_witness("contract", out, doc)
    return doc


def load_contract(path: str, require_witness: bool = True):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ValidationError(f"could not read frozen contract {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"frozen contract {path} is invalid JSON: {exc}") from exc
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(f"frozen contract schema_version must be {SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("kind") != CONTRACT_KIND:
        raise ValidationError(f"frozen contract kind must be {CONTRACT_KIND!r}, got {doc.get('kind')!r}")
    if doc.get("written_by") != os.path.basename(__file__):
        raise ValidationError("frozen contract must be source-owned by idc_validation_contract.py")
    expected = _contract_digest(doc)
    if doc.get("contract_digest") != expected:
        raise ValidationError("frozen contract digest mismatch — the frozen gate was modified after issuance")
    commands = [row.get("command") for row in doc.get("verification") or [] if isinstance(row, dict)]
    _validation_surface(doc.get("surface"), doc.get("evidence_kind"), doc.get("skip_reason"), commands)
    if require_witness:
        problem = _witness_problem("contract", path, doc)
        if problem:
            raise ValidationError(problem)
    return doc


def run_contract(*, repo: str, contract_path: str, out: str):
    contract = load_contract(contract_path)
    workspace = _abs_repo(repo)
    if _repo_identity(workspace) != os.path.abspath(contract.get("repo") or ""):
        raise ValidationError("validation contract is bound to a different repo identity")
    commands = [row.get("command") for row in contract.get("verification") or []]
    surface, evidence_kind, skip_reason, commands = _validation_surface(
        contract.get("surface"), contract.get("evidence_kind"), contract.get("skip_reason"), commands)
    results = _verification_results(workspace, commands)
    diff_info = git_diff_info(workspace, contract["base_commit"], ref="HEAD")
    head = git_head(workspace)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kind": EXECUTION_KIND,
        "written_by": os.path.basename(__file__),
        "created_at": _now(),
        "repo": contract.get("repo"),
        "workspace": workspace,
        "label": contract.get("label"),
        "issue": contract.get("issue"),
        "pr": contract.get("pr"),
        "graph_node": contract.get("graph_node"),
        "graph_digest": contract.get("graph_digest"),
        "projection_digest": contract.get("projection_digest"),
        "contract_path": os.path.relpath(os.path.abspath(contract_path), repo),
        "contract_digest": contract.get("contract_digest"),
        "base_commit": contract.get("base_commit"),
        "head": head,
        "diff_digest": diff_info["diff_digest"],
        "changed_paths": diff_info["changed_paths"],
        "surface": surface,
        "evidence_kind": evidence_kind,
        "skip_reason": skip_reason,
        "handle_id": contract.get("handle_id"),
        "handle_registry": contract.get("handle_registry"),
        "verification": results,
        "declared_evidence": _declared_evidence(evidence_kind, surface, skip_reason, results),
        "result": "pass" if all(row.get("exit_code") == 0 for row in results) else "fail",
    }
    doc["execution_digest"] = _execution_digest(doc)
    atomic_write_json(out, doc)
    _record_witness("execution", out, doc)
    return doc


def load_execution(path: str, require_witness: bool = True):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ValidationError(f"could not read execution receipt {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"execution receipt {path} is invalid JSON: {exc}") from exc
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(f"execution receipt schema_version must be {SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("kind") != EXECUTION_KIND:
        raise ValidationError(f"execution receipt kind must be {EXECUTION_KIND!r}, got {doc.get('kind')!r}")
    if doc.get("written_by") != os.path.basename(__file__):
        raise ValidationError("execution receipt must be source-owned by idc_validation_contract.py")
    expected = _execution_digest(doc)
    if doc.get("execution_digest") != expected:
        raise ValidationError("execution receipt digest mismatch — the recorded execution was modified after it ran")
    _validation_surface(doc.get("surface"), doc.get("evidence_kind"), doc.get("skip_reason"),
                        [row.get("command") for row in (doc.get("verification") or []) if isinstance(row, dict)])
    declared = doc.get("declared_evidence") or {}
    if declared.get("kind") != doc.get("evidence_kind") or declared.get("surface") != doc.get("surface"):
        raise ValidationError("execution receipt contract-drift: declared evidence no longer matches its recorded surface/evidence kind")
    if require_witness:
        problem = _witness_problem("execution", path, doc)
        if problem:
            raise ValidationError(problem)
    return doc


def check_surface(*, contract_path: str, execution_path: str | None = None,
                  require_witness: bool = True):
    """Re-run the fixed surface/evidence rules read-only, for the review stage (see `check-surface`).

    Raises ValidationError on any refusal — the caller turns that into exit 2 — so the reviewer
    inherits the machine's answer rather than judging the prose rule by eye."""
    contract = load_contract(contract_path, require_witness=require_witness)
    report = {
        "ok": True,
        # A reviewer pasting this JSON as evidence could not tell a WITNESSED check from a
        # `--no-witness` one — two very different claims that printed identically.
        "witness_checked": bool(require_witness),
        "contract": os.path.abspath(contract_path),
        "surface": contract.get("surface"),
        "evidence_kind": contract.get("evidence_kind"),
        "skip_reason": contract.get("skip_reason"),
        "handle_id": contract.get("handle_id"),
        "commands": [row.get("command") for row in contract.get("verification") or []
                     if isinstance(row, dict)],
    }
    if execution_path:
        execution = load_execution(execution_path, require_witness=require_witness)
        if (execution.get("surface") != contract.get("surface")
                or execution.get("evidence_kind") != contract.get("evidence_kind")):
            raise ValidationError(
                "contract-drift refused: the execution receipt's declared surface/evidence kind no "
                "longer match the frozen validation contract")
        if execution.get("skip_reason") != contract.get("skip_reason"):
            raise ValidationError(
                "contract-drift refused: the execution receipt's skip_reason no longer matches the "
                "frozen validation contract")
        report["execution"] = os.path.abspath(execution_path)
        report["result"] = execution.get("result")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(description="Freeze and execute build validation contracts.")
    sp = ap.add_subparsers(dest="command", required=True)

    fp = sp.add_parser("freeze")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--issue", type=int, required=True)
    fp.add_argument("--pr", type=int, required=True)
    fp.add_argument("--graph-node", required=True)
    fp.add_argument("--graph-digest")
    fp.add_argument("--projection-digest")
    fp.add_argument("--planning-receipt")
    fp.add_argument("--touch", action="append", required=True)
    fp.add_argument("--off-limits", action="append", required=True)
    fp.add_argument("--verify", action="append")
    # `--surface` is REQUIRED, but the requirement is NOT declared here. `_validation_surface` is the
    # single enforcement point (it also runs on every re-read of a frozen contract, where no CLI is
    # involved), and an argparse `required=True`/`choices=` in front of it is a second copy of the same
    # rule — one that no test can be red for, because removing it just lets the library refuse the same
    # input one step later. The help text documents the requirement; the library enforces it.
    fp.add_argument("--surface",
                    help="REQUIRED — where a user/system meets the change: "
                         + "|".join(sorted(SURFACE_EVIDENCE_TABLE))
                         + " (an undeclared surface is not a declaration; docs-only tickets declare "
                           "`none` with a one-line --skip-reason)")
    fp.add_argument("--evidence-kind")
    fp.add_argument("--skip-reason")
    fp.add_argument("--handle-registry")
    fp.add_argument("--handle-id")
    fp.add_argument("--baseline", required=True, choices=("expected-red", "expected-green"))
    fp.add_argument("--label", required=True)
    fp.add_argument("--out", required=True)
    fp.add_argument("--attempt-ceiling", type=int, default=None,
                    help="explicit attempt ceiling; when omitted, defaults from the repo config's "
                         "pathway_enforcement.attempt_ceiling, then the built-in %d" % DEFAULT_ATTEMPT_CEILING)

    rp = sp.add_parser("run")
    rp.add_argument("--repo", required=True)
    rp.add_argument("--contract", required=True)
    rp.add_argument("--out", required=True)

    # The SINGLE resolved attempt-ceiling source (F21). Both the risk gate's `--attempt-ceiling` and
    # the implementer's retry loop read this, so the operator's `pathway_enforcement.attempt_ceiling`
    # (spec §2.1) governs the risk gate, the frozen contract, AND the loop from one value — not a
    # hard-coded 3 that silently disagrees with the config.
    # THE REVIEWER'S DETERMINISTIC PRE-CHECK (see skills/idc-review-engine/SKILL.md). The surface /
    # evidence rules are enforced in fixed code at FREEZE and again at FINISH (idc_build_receipt.py),
    # which left review — the stage between them — with nothing but prose to judge by. This subcommand
    # exposes the SAME fixed rule, read-only, so a reviewer INHERITS the refusal instead of forming an
    # opinion about it. It adds no new rule: everything it reports would refuse the merge anyway; it
    # just reports it while the fix is still cheap.
    kp = sp.add_parser("check-surface",
                       help="read-only: re-run the fixed surface/evidence rules over a frozen "
                            "contract (and optionally its execution receipt) — the reviewer's "
                            "deterministic pre-check")
    kp.add_argument("--contract", required=True)
    kp.add_argument("--execution")
    kp.add_argument("--no-witness", action="store_true",
                    help="check the surface rules only, without the out-of-tree witness binding "
                         "(the witness chain is still enforced at freeze and at finish)")

    cp = sp.add_parser("attempt-ceiling",
                       help="print the repo's resolved attempt ceiling (config value, else the "
                            "built-in default) — the single source the risk gate + retry loop consume")
    cp.add_argument("--repo", required=True)

    args = ap.parse_args(argv)
    try:
        if args.command == "attempt-ceiling":
            print(_resolve_attempt_ceiling(_abs_repo(args.repo), None))
            return 0
        if args.command == "freeze":
            freeze_contract(
                repo=args.repo,
                issue=args.issue,
                pr=args.pr,
                graph_node=args.graph_node,
                graph_digest=args.graph_digest,
                projection_digest=args.projection_digest,
                planning_receipt=args.planning_receipt,
                touch=args.touch,
                off_limits=args.off_limits,
                verify_commands=args.verify,
                baseline=args.baseline,
                label=args.label,
                out=args.out,
                attempt_ceiling=args.attempt_ceiling,
                surface=args.surface,
                evidence_kind=args.evidence_kind,
                skip_reason=args.skip_reason,
                handle_registry=args.handle_registry,
                handle_id=args.handle_id,
            )
            return 0
        if args.command == "check-surface":
            report = check_surface(contract_path=args.contract, execution_path=args.execution,
                                  require_witness=not args.no_witness)
            json.dump(report, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        if args.command == "run":
            doc = run_contract(repo=args.repo, contract_path=args.contract, out=args.out)
            json.dump({
                "ok": True,
                "result": doc.get("result"),
                "head": doc.get("head"),
                "diff_digest": doc.get("diff_digest"),
            }, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
    except ValidationError as exc:
        die(str(exc), code=2)
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    raise SystemExit(main())
