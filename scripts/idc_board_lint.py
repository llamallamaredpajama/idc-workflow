#!/usr/bin/env python3
"""idc_board_lint.py — /idc:doctor's advisory board-lane lint (`WORKFLOW.md §3`).

The schema check (`idc_schema_check.py`) is Plan's gate: it runs once, at issue creation,
before board admission. An issue that bypasses Plan — hand-filed, or a captured review-residual —
can sit in the build-eligible lane (`Status = Todo`, `Stage = Buildable`) malformed and/or with a
**prose-only dependency** ("blocked on X" stated in the body with no native blocked-by link). Build
and Autorun consume the board on trust, so such an issue is claimed and executed cold.

This helper re-runs the existing contract schema check over the build-eligible lane and flags
prose dependencies that were never recorded as a native blocked-by link. It is **advisory** — it
reports, it never gates. (Build does not re-validate every issue; the schema check stays Plan's
gate. This is doctor's read-only heads-up that something slipped past it.)

It is **github-only** by construction: the filesystem backend stores no issue bodies (only
structured metadata), so there is no body to re-scan and a dependency can only ever BE the native
`blocked_by` link — `/idc:doctor` skips this row for the filesystem backend.

Input (stdin): a JSON array, OR newline-delimited JSON objects (one per line), each:
    {"number": <int>, "title": <str>, "body": <str>, "blocked_by": [<int>, ...] | null}
`blocked_by` is the issue's native GitHub blocked-by links (numbers), as read by the caller, and is
**tri-state**: `[n, ...]` = linked, `[]` = confirmed no link, `null` = UNKNOWN (the caller's lookup
FAILED — e.g. the `gh api` dependencies call errored). UNKNOWN ≠ "no link": a prose dependency on an
issue we could not disprove is never flagged.

Output (stdout): one line per flagged issue, then a summary line:
    board-lint: clean (<M> scanned)
    board-lint: <N> flagged of <M> scanned (<S> schema, <P> prose-dep)
When one or more scanned issues carry `blocked_by == null` (UNKNOWN — the caller's native
blocked-by lookup FAILED), the summary appends `; <U> dependency lookups indeterminate` *inside*
the parentheses of whichever form prints, so a board-wide dependencies-API outage — every issue →
UNKNOWN → nothing flagged — cannot masquerade as a clean all-clear. The clause is omitted entirely
when <U> == 0, leaving the summary byte-for-byte unchanged.

Usage: idc_board_lint.py < issues.json   (exit 0 = ran OK; 2 = unreadable/un-parseable input)
"""
import json
import os
import re
import sys

# Reuse Plan's schema check (same directory) rather than re-implement the contract shape.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_schema_check  # noqa: E402

# An `[operator-action]` gate issue is the operator's own hand-filed item, never a goal-contract —
# Autorun's drain already excludes it from build work, and it would always "fail" the contract
# schema. Skip it here so it is never a false positive.
OPERATOR_GATE_PREFIX = "[operator-action]"

# Prose dependency phrases — the SPACE/free-text forms a human writes in a body, deliberately NOT
# the hyphenated structured tokens `blocked-by` / `blocks-on:` (those ARE recorded links / the
# documented fallback, and the canonical "none" footer reads `Dependencies: blocked-by #0 (none)`).
BLOCKER_PROSE = re.compile(
    r"(?i)\b(blocked on|blocked by|depends on|dependent on|waiting on|waiting for"
    r"|(?:requires|needs)\b.{0,40}?\b(?:first|before)\b"
    r"|after #\d+\b.{0,20}?\b(?:done|merged|lands?|complete)"
    r"|once #\d+\b)"
)

# A `blocks-on:#<parent>` body line is the documented fallback when the native dependencies endpoint
# is unavailable — it counts as a recorded link, so an issue carrying one is NOT a prose-only dep.
FALLBACK_LINK = re.compile(r"(?im)^\s*blocks-on:\s*#\d+")

# A `#<n>` reference inside the Dependencies field value names an upstream issue. `#0` is the
# canonical "none" sentinel (`blocked-by #0 (none)`), not a real dependency.
DEP_ISSUE_REF = re.compile(r"#(\d+)")


def read_issues(raw):
    """Accept a JSON array or newline-delimited JSON objects; return a list of dicts."""
    raw = raw.strip()
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return parsed
    except json.JSONDecodeError:
        pass
    # Fall back to JSONL (one object per line) — what `gh issue view --jq '{...}'` emits per issue.
    issues = []
    for ln in raw.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        issues.append(json.loads(ln))
    return issues


def prose_dependency_evidence(body, blocked_by):
    """Return a short evidence string if the body states a dependency with no recorded link, else ''.

    `blocked_by` is tri-state: a list of numbers = linked, `[]` = confirmed no link, `None` = UNKNOWN
    (the caller's native-link lookup FAILED). A recorded link is a native blocked-by (`blocked_by`
    non-empty) OR the documented `blocks-on:#N` fallback line. With either present, a prose mention is
    just commentary on a real link — not a gap. When `blocked_by is None` we could not disprove a
    native link, so a prose mention is never flagged (no false positive on a degraded API lookup).
    """
    if blocked_by is None:
        return ""  # UNKNOWN — lookup failed; never flag a prose dep we could not disprove
    if blocked_by or FALLBACK_LINK.search(body):
        return ""
    # Claim via the Dependencies field naming a real upstream issue (#N, N != 0).
    dep_value = idc_schema_check.value_after(body, "Dependencies") or ""
    for ref in DEP_ISSUE_REF.findall(dep_value):
        if int(ref) != 0:
            return f"Dependencies names #{ref} but no native blocked-by link"
    # Claim via free prose anywhere in the body.
    m = BLOCKER_PROSE.search(body)
    if m:
        phrase = " ".join(m.group(0).split())
        return f"prose dependency (“{phrase}”) but no native blocked-by link"
    return ""


def lint(issues):
    """Return (lines, scanned, schema_count, prose_count, unknown_count)."""
    lines = []
    scanned = schema_count = prose_count = unknown_count = 0
    for it in issues:
        title = str(it.get("title", "")).strip()
        if title.startswith(OPERATOR_GATE_PREFIX):
            continue  # the operator's gate issue — not a goal-contract, never built cold
        scanned += 1
        num = it.get("number", "?")
        body = it.get("body") or ""
        blocked_by = it.get("blocked_by")  # tri-state: list | [] | None(=UNKNOWN); do NOT coerce None→[]
        if blocked_by is None:
            unknown_count += 1  # caller's native blocked-by lookup FAILED — surfaced in the summary so a board-wide outage can't masquerade as clean

        findings = []
        # These are the Buildable lane by construction (the caller filtered Stage=Buildable), so
        # validate them AS goal-contracts directly rather than re-dispatching on a Stage the body
        # never carries (Stage is a board field, not body text).
        problems = idc_schema_check.check_contract(body)
        if problems:
            schema_count += 1
            findings.append("schema — " + "; ".join(problems))
        evidence = prose_dependency_evidence(body, blocked_by)
        if evidence:
            prose_count += 1
            findings.append("prose-dep — " + evidence)

        if findings:
            label = f'#{num} "{title}"' if title else f"#{num}"
            for f in findings:
                lines.append(f"{label}: {f}")
    return lines, scanned, schema_count, prose_count, unknown_count


def main():
    try:
        issues = read_issues(sys.stdin.read())
    except (json.JSONDecodeError, ValueError) as e:
        sys.stderr.write(f"idc-board-lint: cannot parse stdin as JSON issues: {e}\n")
        sys.exit(2)
    for it in issues:
        if not isinstance(it, dict):
            sys.stderr.write("idc-board-lint: each issue must be a JSON object\n")
            sys.exit(2)

    lines, scanned, schema_count, prose_count, unknown_count = lint(issues)
    for ln in lines:
        print(ln)
    flagged = schema_count + prose_count
    # Append the degraded-lookup clause ONLY when >0 — when 0 the summary is byte-for-byte unchanged.
    _noun = "lookup" if unknown_count == 1 else "lookups"
    unknown_clause = f"; {unknown_count} dependency {_noun} indeterminate" if unknown_count else ""
    if flagged:
        print(f"board-lint: {flagged} flagged of {scanned} scanned "
              f"({schema_count} schema, {prose_count} prose-dep{unknown_clause})")
    else:
        print(f"board-lint: clean ({scanned} scanned{unknown_clause})")
    sys.exit(0)


if __name__ == "__main__":
    main()
