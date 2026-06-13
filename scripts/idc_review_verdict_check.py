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

Usage: idc_review_verdict_check.py <verdict.json>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import json
import sys

VERDICTS = {"PASS", "PASS-WITH-NITS", "FAIL", "FAIL-BLOCKED"}
SEVERITIES = {"blocker", "major", "minor", "nit"}
REQUIRED_FINDING = ("dimension", "severity", "confidence", "evidence", "attack", "unblock", "fingerprint")
CONFIDENCE_FLOOR = 0.8
# Test genuineness is fail-closed: a shallow/placeholder test is a FAIL, not a nit.
TEST_GENUINENESS_DIM = "test-genuineness"
TEST_GENUINENESS_MIN = {"major", "blocker"}


def expected_verdict(severities):
    if "blocker" in severities:
        return "FAIL-BLOCKED"
    if "major" in severities:
        return "FAIL"
    if severities & {"minor", "nit"}:
        return "PASS-WITH-NITS"
    return "PASS"


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
        for k in REQUIRED_FINDING:
            if k not in f or (isinstance(f.get(k), str) and not f[k].strip()):
                problems.append(f"finding[{i}] missing/empty `{k}`")
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
    if verdict in VERDICTS:
        sevs = {f.get("severity") for f in findings if isinstance(f, dict) and f.get("severity") in SEVERITIES}
        exp = expected_verdict(sevs)
        if verdict != exp:
            problems.append(f"verdict {verdict!r} inconsistent with findings — worst severity "
                            f"present implies {exp!r}")
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
    print("review verdict check: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
