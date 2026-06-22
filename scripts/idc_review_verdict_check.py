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

Usage: idc_review_verdict_check.py <verdict.json>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import json
import sys

VERDICTS = {"PASS", "PASS-WITH-NITS", "FAIL", "FAIL-BLOCKED"}
SEVERITIES = {"blocker", "major", "minor", "nit"}
REQUIRED_FINDING = ("dimension", "severity", "confidence", "evidence", "attack", "unblock", "fingerprint")
# A deferral is a structured, validated obligation a closeout carries instead of an unparsed
# prose footnote (autorun audit Defect 5). The acceptance check (idc_acceptance_check.py)
# consumes `blocks_goal` to flag a Done-but-inert increment, so it must be a real JSON boolean.
REQUIRED_DEFERRAL = ("kind", "what", "blocks_goal", "suggested_issue")
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
