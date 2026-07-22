#!/usr/bin/env python3
"""idc_review_verdict_check.py — validate a merged-review-engine verdict (`WORKFLOW.md §4.3`).

The review engine (`idc:idc-review-engine`) emits a structured JSON verdict per PR. This is
the executable guardrail that keeps the verdict well-formed and internally consistent, so
the Build finisher can trust it for the automerge decision. It checks:

  * `verdict` ∈ {PASS, PASS-WITH-NITS, FAIL, FAIL-BLOCKED};
  * every finding carries dimension, a severity on the ladder {blocker, major, minor, nit},
    a confidence ≥ 0.8 (the reporting floor), and non-empty evidence + attack + unblock +
    fingerprint (the engine's required finding shape);
  * the verdict is CONSISTENT with the findings — the worst severity present determines it:
    blocker→FAIL-BLOCKED, major→FAIL, minor/nit→PASS-WITH-NITS, none→PASS. A PASS that hides
    a major, or a FAIL with no actionable finding, is rejected.
  * a `test-genuineness` finding (a shallow/shortcut/placeholder test — one that asserts
    nothing, mirrors the implementation, or stubs the thing under test) is a FAIL, never a
    nit: its severity must be `major` or `blocker`. A `minor`/`nit` test-genuineness finding
    is rejected so a fake-green suite can never merge as a nit (`WORKFLOW.md §4.3`).
  * an optional `deferrals` list (default empty) is well-formed: every item carries kind,
    what, suggested_issue (non-empty) and a `blocks_goal` that is a real JSON boolean — the
    structured obligation a closeout emits instead of an unparsed prose footnote, consumed by
    the wave-close acceptance check.
  * an optional `merge_conditions` list (default empty; backward-compatible — absent ⇒ no
    conditions) is well-formed: every item carries id + description (non-empty strings) and a
    `met` that is a real JSON boolean. These are the pre-merge conditions a PASS-WITH-NITS review
    attaches; the transition engine's `close` guard blocks Done while any entry is unmet, closing
    the silently-downgraded pre-merge-condition failure (#246 -> #248).

Usage: idc_review_verdict_check.py <verdict.json>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time

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

VERDICTS = {"PASS", "PASS-WITH-NITS", "FAIL", "FAIL-BLOCKED"}
# The PASSING dispositions — a verdict that may permit a merge/close. FAIL/FAIL-BLOCKED must be fixed,
# never closed. The transition engine's close guard reads this so the pass/fail split has ONE owner.
PASSING = {"PASS", "PASS-WITH-NITS"}
SEVERITIES = {"blocker", "major", "minor", "nit"}
REQUIRED_FINDING = ("dimension", "severity", "confidence", "evidence", "attack", "unblock", "fingerprint")
# A deferral is a structured, validated obligation a closeout carries instead of an unparsed
# prose footnote (autorun audit Defect 5). The acceptance check (idc_acceptance_check.py)
# consumes `blocks_goal` to flag a Done-but-inert increment, so it must be a real JSON boolean.
REQUIRED_DEFERRAL = ("kind", "what", "blocks_goal", "suggested_issue")
# A merge_condition is a structured pre-merge gate a PASS-WITH-NITS review attaches; the transition
# engine's close guard blocks Done while any entry's `met` is not True. `met` must be a real JSON
# boolean so a stringy "false" can never read as satisfied.
REQUIRED_MERGE_CONDITION = ("id", "description", "met")
CONFIDENCE_FLOOR = 0.8
# Test genuineness is fail-closed: a shallow/placeholder test is a FAIL, not a nit.
TEST_GENUINENESS_DIM = "test-genuineness"
TEST_GENUINENESS_MIN = {"major", "blocker"}
CODE_REVIEWS_DIR = os.path.join("docs", "workflow", "code-reviews")
WITNESS_FILE = "idc-review-verdict-witnesses.json"


def _code_reviews_context(verdict_path):
    abs_path = os.path.abspath(verdict_path)
    marker = os.path.join(os.sep, CODE_REVIEWS_DIR, "")
    idx = abs_path.rfind(marker)
    if idx < 0:
        return None, None, None, None
    repo_root = abs_path[:idx] or os.sep
    rel = os.path.relpath(abs_path, repo_root)
    try:
        proc = subprocess.run(["git", "-C", repo_root, "rev-parse", "--show-toplevel", "--git-common-dir"],
                              capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError) as exc:
        return repo_root, None, rel, f"could not resolve the repository git directory ({exc})"
    if proc.returncode != 0:
        detail = CS.scrub(proc.stderr or proc.stdout or "git rev-parse failed").strip()[:200]
        return repo_root, None, rel, f"could not resolve the repository git directory ({detail})"
    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        return repo_root, None, rel, "could not resolve the repository git directory (git rev-parse returned incomplete output)"
    top, common = os.path.abspath(lines[0]), lines[1]
    if not os.path.isabs(common):
        common = os.path.abspath(os.path.join(top, common))
    return top, common, rel, None


def _witness_path(common_git_dir):
    return os.path.join(common_git_dir, WITNESS_FILE)


def _digest_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _read_witnesses(common_git_dir):
    path = _witness_path(common_git_dir)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def witness_problem(verdict_path, doc):
    repo_root, common_git_dir, rel, err = _code_reviews_context(verdict_path)
    if rel is None:
        return None
    if err:
        return err
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        return "the validator witness store is unreadable"
    rec = witnesses.get(rel)
    if not isinstance(rec, dict):
        return f"no source-owned validator witness is recorded for {rel}"
    if rec.get("repo_root") != repo_root:
        return f"the validator witness for {rel} names repo {rec.get('repo_root')!r}, not this repo"
    try:
        digest = _digest_file(verdict_path)
    except OSError as exc:
        return f"could not re-read {rel} to verify its witness ({exc})"
    if rec.get("digest") != digest:
        return f"the validator witness for {rel} is stale — its digest no longer matches the verdict file"
    for key in ("pr", "issue", "verdict"):
        if key in rec and rec.get(key) != doc.get(key):
            return f"the validator witness for {rel} is for {key}={rec.get(key)!r}, not {doc.get(key)!r}"
    return None


def record_witness(verdict_path, doc):
    repo_root, common_git_dir, rel, err = _code_reviews_context(verdict_path)
    if rel is None:
        return True, None
    if err:
        return False, err
    try:
        digest = _digest_file(verdict_path)
    except OSError as exc:
        return False, f"could not read {rel} to record its validator witness ({exc})"
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        return False, "the validator witness store is unreadable"
    witnesses[rel] = {
        "digest": digest,
        "repo_root": repo_root,
        "issue": doc.get("issue"),
        "pr": doc.get("pr"),
        "validated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "validator": os.path.basename(__file__),
        "verdict": doc.get("verdict"),
    }
    path = _witness_path(common_git_dir)
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=common_git_dir, prefix=".idc-review-witness.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(witnesses, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        if tmp is not None:
            try:
                os.remove(tmp)
            except OSError:
                pass
        return False, f"could not record the validator witness for {rel} ({exc})"
    return True, None


def expected_verdict(severities):
    if "blocker" in severities:
        return "FAIL-BLOCKED"
    if "major" in severities:
        return "FAIL"
    if severities & {"minor", "nit"}:
        return "PASS-WITH-NITS"
    return "PASS"


def require_strings(obj, keys, exempt, label, i, problems):
    """Append a problem for each required key that is missing, or present-but-not-a-non-empty-string.

    A required field that is present-but-null/[]/{}/0 (any non-string) must be rejected, not silently
    accepted — a strip()-only guard only catches empty *strings*. `exempt` names the one key that is
    numeric/boolean and carries its own range/type check at the call site, so it is checked for
    presence here but not against the non-empty-string rule.
    """
    for k in keys:
        if k not in obj:
            problems.append(f"{label}[{i}] missing `{k}`")
        elif k != exempt and (not isinstance(obj.get(k), str) or not obj[k].strip()):
            problems.append(f"{label}[{i}] `{k}` must be a non-empty string")


def check(doc):
    problems = []
    verdict = doc.get("verdict")
    if verdict not in VERDICTS:
        problems.append(f"`verdict` must be one of {sorted(VERDICTS)} (got {verdict!r})")
    findings = doc.get("findings", [])
    if not isinstance(findings, list):
        return ["`findings` must be a list"]
    seen = set()
    for i, f in enumerate(findings):
        if not isinstance(f, dict):
            problems.append(f"finding[{i}] is not a JSON object")
            continue
        # `confidence` is numeric and carries its own range check below, so it is exempt here.
        require_strings(f, REQUIRED_FINDING, "confidence", "finding", i, problems)
        if f.get("severity") not in SEVERITIES:
            problems.append(f"finding[{i}] severity must be one of {sorted(SEVERITIES)}")
        elif f.get("dimension") == TEST_GENUINENESS_DIM and f.get("severity") not in TEST_GENUINENESS_MIN:
            problems.append(f"finding[{i}] test-genuineness severity {f.get('severity')!r} too low — "
                            f"a shallow/placeholder test is a FAIL ({sorted(TEST_GENUINENESS_MIN)}), not a nit")
        c = f.get("confidence")
        if not isinstance(c, (int, float)) or c < CONFIDENCE_FLOOR or c > 1:
            problems.append(f"finding[{i}] confidence must be a number in [{CONFIDENCE_FLOOR}, 1] (the reporting floor)")
        fp = f.get("fingerprint")
        if fp in seen:
            problems.append(f"finding[{i}] duplicate fingerprint {fp!r} (coordinator must dedup)")
        elif fp:
            seen.add(fp)
    deferrals = doc.get("deferrals", [])
    if not isinstance(deferrals, list):
        problems.append("`deferrals` must be a list")
    else:
        for i, d in enumerate(deferrals):
            if not isinstance(d, dict):
                problems.append(f"deferral[{i}] is not a JSON object")
                continue
            # `blocks_goal` is a boolean with its own type check below, so it is exempt here.
            require_strings(d, REQUIRED_DEFERRAL, "blocks_goal", "deferral", i, problems)
            # blocks_goal gates the acceptance check; a strip()-only check would pass the string
            # "true", so the boolean type is enforced explicitly.
            if "blocks_goal" in d and not isinstance(d.get("blocks_goal"), bool):
                problems.append(f"deferral[{i}] `blocks_goal` must be a JSON boolean "
                                f"(got {type(d.get('blocks_goal')).__name__})")
    merge_conditions = doc.get("merge_conditions", [])
    if not isinstance(merge_conditions, list):
        problems.append("`merge_conditions` must be a list")
    else:
        seen_ids = set()
        for i, c in enumerate(merge_conditions):
            if not isinstance(c, dict):
                problems.append(f"merge_condition[{i}] is not a JSON object")
                continue
            # `met` is a boolean with its own type check below, so it is exempt from the string rule.
            require_strings(c, REQUIRED_MERGE_CONDITION, "met", "merge_condition", i, problems)
            if "met" in c and not isinstance(c.get("met"), bool):
                problems.append(f"merge_condition[{i}] `met` must be a JSON boolean "
                                f"(got {type(c.get('met')).__name__})")
            cid = c.get("id")
            if isinstance(cid, str) and cid in seen_ids:
                problems.append(f"merge_condition[{i}] duplicate id {cid!r}")
            elif isinstance(cid, str):
                seen_ids.add(cid)
    if verdict in VERDICTS:
        sevs = {f.get("severity") for f in findings if isinstance(f, dict) and f.get("severity") in SEVERITIES}
        exp = expected_verdict(sevs)
        if verdict != exp:
            problems.append(f"verdict {verdict!r} inconsistent with findings — worst severity "
                            f"present implies {exp!r}")
    # Optional `pr` / `issue` (the reviewed PR and the board issue it implements): when present they
    # must be positive integers — the filer (idc_file_findings.py) reads `issue` as the blocks_goal
    # parent-link target, so a garbage value must surface here, not fail silently downstream. Absent
    # is fine (backward-compatible; the filer degrades to no parent link).
    for k in ("pr", "issue"):
        if k in doc and not (isinstance(doc[k], int) and not isinstance(doc[k], bool) and doc[k] > 0):
            problems.append(f"`{k}` must be a positive integer when present (got {doc[k]!r})")
    return problems


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_review_verdict_check.py <verdict.json>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"idc-review-verdict-check: cannot parse {sys.argv[1]}: {e}\n")
        sys.exit(2)
    problems = check(doc)
    if problems:
        print("review verdict check: FAIL")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    ok, err = record_witness(sys.argv[1], doc)
    if not ok:
        sys.stderr.write(f"idc-review-verdict-check: warning: {err}\n")
    print("review verdict check: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
