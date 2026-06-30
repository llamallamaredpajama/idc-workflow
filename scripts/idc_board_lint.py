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
    {"number": <int>, "title": <str>, "body": <str>, "blocked_by": [<int>, ...] | null,
     "stage": <str>?, "status": <str>?}
`blocked_by` is the issue's native GitHub blocked-by links (numbers), as read by the caller, and is
**tri-state**: `[n, ...]` = linked, `[]` = confirmed no link, `null` = UNKNOWN (the caller's lookup
FAILED — e.g. the `gh api` dependencies call errored). UNKNOWN ≠ "no link": a prose dependency on an
issue we could not disprove is never flagged.
`stage`/`status` are **optional** and **backward-compatible**: a caller that supplies the whole board
(each issue's `stage`/`status`) enables the **retired-recirc** rule; the legacy thin shape (no
`stage`/`status`) leaves that rule silent. Two roles per object — an object IN the build-eligible lane
(`stage` absent or `Buildable`, `status` absent or `Todo`) is **scanned**; an object explicitly
outside it (e.g. a Done `Recirculation` ticket a paused issue is `blocked_by`) is **index-only**: it
is never schema-scanned (its non-contract body would false-flag) and never counted in `scanned`, it
only resolves a blocker's lane for the retired-recirc rule.

The **retired-recirc** rule fail-closes on the premature-eligibility / infinite-recirc trap: a
build-eligible issue whose only remaining blocker is a **retired (Done) `Stage = Recirculation`
ticket** is spuriously eligible — Plan's paused-issue re-link (idc-plan Phase 4) should have
re-pointed it off that retired ticket onto the real new unblockers. It fires only when the blocker's
`stage`/`status` are present and resolve to a Done Recirculation ticket.

Output (stdout): one line per flagged issue, then a summary line:
    board-lint: clean (<M> scanned)
    board-lint: <N> flagged of <M> scanned (<S> schema, <P> prose-dep)
When one or more scanned issues carry `blocked_by == null` (UNKNOWN — the caller's native
blocked-by lookup FAILED), the summary appends `; <U> dependency lookups indeterminate` *inside*
the parentheses of whichever form prints, so a board-wide dependencies-API outage — every issue →
UNKNOWN → nothing flagged — cannot masquerade as a clean all-clear. The clause is omitted entirely
when <U> == 0, leaving the summary byte-for-byte unchanged.
When one or more issues are flagged retired-recirc, the flagged summary appends `, <R> retired-recirc`
*inside* the parentheses; the clause is omitted when <R> == 0 (same byte-identical-when-zero discipline
as the degraded clause), so the existing `(<S> schema, <P> prose-dep)` form is preserved.

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

# The retired-recirc rule resolves each native blocked-by to its board lane. A blocker that resolves
# to a `Stage = Recirculation` ticket already `Status = Done` is a RETIRED recirculation ticket — its
# scope was admitted as a consideration, so Plan's paused-issue re-link (idc-plan Phase 4) should have
# re-pointed this issue OFF it onto the real new unblockers. If that link is the issue's last blocker,
# the issue is spuriously eligible (the premature-eligibility / infinite-recirc trap).
RECIRC_STAGE = "Recirculation"
DONE_STATUS = "Done"
# Build-eligible-lane sentinels: an input object IS scanned (schema/prose/retired) only when it is in
# this lane; an object explicitly outside it (e.g. the Done Recirculation blocker) rides in INDEX-ONLY
# to supply a blocker's stage/status and is never schema-scanned (its non-contract body would
# false-flag) nor counted as `scanned`.
BUILDABLE_STAGE = "Buildable"
TODO_STATUS = "Todo"

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


def retired_recirc_evidence(blocked_by, stage_status):
    """Return a short evidence string if a paused issue is spuriously eligible behind a retired
    (Done) Recirculation ticket, else ''.

    The paused-issue re-link (idc-plan Phase 4) re-points a paused origin issue OFF its retired recirc
    ticket and onto the real new unblocker issues. If that step was skipped, the paused issue stays
    `blocked_by` a `Stage = Recirculation` ticket that has since gone `Done` — so that blocker is
    satisfied and the issue is **spuriously eligible** (the premature-eligibility / infinite-recirc
    trap this rule fail-closes on).

    SOLE/SATISFIED semantics: the issue is spuriously eligible ONLY when **every** blocker is
    satisfied (Done) AND at least one of them is a retired Recirculation ticket. A blocker that is
    still LIVE (status ≠ Done), or UNKNOWN (absent from the index — a thin legacy object, or a
    degraded lookup), counts as **remaining**: it genuinely holds the issue, so the issue is NOT
    eligible and the rule stays silent (never over-reports a still-blocked issue — Minor 1).

    `blocked_by` is tri-state (`[n,…]` = linked, `[]` = no link, `None` = UNKNOWN — nothing to
    resolve in any case but the first). `stage_status` is `{number: (stage, status)}` over the full
    input list."""
    if not blocked_by:
        return ""

    def _entry(num):
        return stage_status.get(num, (None, None))

    # A live or unknown blocker still holds the issue -> NOT spuriously eligible.
    if not all(_entry(b)[1] == DONE_STATUS for b in blocked_by):
        return ""
    # Every blocker is satisfied (Done). Flag iff at least one is a retired Recirculation ticket.
    for b in blocked_by:
        if _entry(b)[0] == RECIRC_STAGE:
            return (f"carries retired (Done) {RECIRC_STAGE} ticket #{b} as a (satisfied) blocker — "
                    "paused-issue re-link skipped (idc-plan Phase 4); re-point onto real unblockers")
    return ""


def in_scan_lane(it):
    """Whether an input object is a build-eligible-lane issue to SCAN (schema/prose/retired), versus
    an index-only entry that only supplies a blocker's stage/status.

    The legacy thin shape (NEITHER `stage` nor `status` present) is ALWAYS scanned — the caller
    pre-filtered to `Status = Todo` + `Stage = Buildable`, exactly as before. ANY object that carries
    at least one of `stage`/`status` is a board-index object and is scanned ONLY when it sits squarely
    in the build-eligible lane: `stage == Buildable` AND `status == Todo`. Anything else is index-only
    (it only supplies a blocker's stage/status to the resolution index) — scanning it would schema-flag
    its non-contract body and inflate the `scanned` tally.

    The load-bearing case is a PRESENT stage with an ABSENT/null status: `idc_gh_board.py` OMITS absent
    fields, so an issue carrying no Status re-materializes (via doctor's index pass) as `{stage:
    "Buildable", status: null}`. That is an index object, NOT a thin legacy issue, so it must be
    index-only — never scanned with an empty body (the false-schema-flag this guards)."""
    stage = it.get("stage")
    status = it.get("status")
    if stage is None and status is None:
        return True                                   # legacy thin shape — pre-filtered by the caller
    return stage == BUILDABLE_STAGE and status == TODO_STATUS


def lint(issues):
    """Return (lines, scanned, schema_count, prose_count, retired_count, unknown_count)."""
    lines = []
    scanned = schema_count = prose_count = retired_count = unknown_count = 0
    # Blocker-resolution index: {number: (stage, status)} over the WHOLE input, so the retired-recirc
    # rule can resolve each native blocked-by to its board lane. Index-only entries (a Done
    # Recirculation ticket) ride in solely to populate this — see in_scan_lane().
    stage_status = {it.get("number"): (it.get("stage"), it.get("status")) for it in issues}
    for it in issues:
        title = str(it.get("title", "")).strip()
        if title.startswith(OPERATOR_GATE_PREFIX):
            continue  # the operator's gate issue — not a goal-contract, never built cold
        if not in_scan_lane(it):
            continue  # index-only entry (supplies a blocker's stage/status); not a scanned lane issue
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
        retired_ev = retired_recirc_evidence(blocked_by, stage_status)
        if retired_ev:
            retired_count += 1
            findings.append("retired-recirc — " + retired_ev)

        if findings:
            label = f'#{num} "{title}"' if title else f"#{num}"
            for f in findings:
                lines.append(f"{label}: {f}")
    return lines, scanned, schema_count, prose_count, retired_count, unknown_count


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

    lines, scanned, schema_count, prose_count, retired_count, unknown_count = lint(issues)
    for ln in lines:
        print(ln)
    flagged = schema_count + prose_count + retired_count
    # Append the degraded-lookup clause ONLY when >0 — when 0 the summary is byte-for-byte unchanged.
    _noun = "lookup" if unknown_count == 1 else "lookups"
    unknown_clause = f"; {unknown_count} dependency {_noun} indeterminate" if unknown_count else ""
    # The retired-recirc tally rides the flagged parens as a conditional clause (like the degraded
    # clause), so a board with zero retired-recirc findings keeps the pre-existing summary byte-for-
    # byte (the existing schema/prose-dep assertions stay green).
    retired_clause = f", {retired_count} retired-recirc" if retired_count else ""
    if flagged:
        print(f"board-lint: {flagged} flagged of {scanned} scanned "
              f"({schema_count} schema, {prose_count} prose-dep{retired_clause}{unknown_clause})")
    else:
        print(f"board-lint: clean ({scanned} scanned{unknown_clause})")
    sys.exit(0)


if __name__ == "__main__":
    main()
