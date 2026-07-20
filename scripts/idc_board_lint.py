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

The BODY rules (schema / prose-dependency) are **github-only** by construction: the filesystem
backend stores no issue bodies (only structured metadata), so there is no body to re-scan and a
dependency can only ever BE the native `blocked_by` link — `/idc:doctor` feeds no scanned lane for
the filesystem backend. The INDEX rules (`stranded-gate`, `empty-status`) are body-free and
backend-NEUTRAL: doctor's filesystem branch feeds the tracker's structured records as index-only
objects (Buildable+Todo excluded, so nothing is ever body-schema-scanned), because those strand
classes exist on filesystem too.

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

The **empty-Status** rule enforces the `Stage∈{Consideration,Recirculation}` invariant (#255/#256): a
pointer/ticket in either stage that carries an empty/missing Status (`null`, `""`, or the doctor
`"none"` sentinel) is invisible to the dropped-handoff detector and silently never drains. It is
flagged `empty-status`; the tally rides the flagged parens as a conditional `, <E> empty-status`
clause (omitted when <E> == 0, same byte-identical discipline). These items ride index-only (their
non-contract bodies are never schema-scanned) and are NOT counted toward `scanned` (which stays
build-eligible-only), so a flagged count can exceed the scanned count in a pure empty-Status board.

The **stranded-gate** rule (round-11 close-out) is the deterministic surface for the gate skill's
dispose-first liveness gap: `idc:idc-gate-issue` step 4 closes the gate through the guarded
`dispose` FIRST and unblocks dependents only after it succeeds, so a run killed between the two
leaves a dependent `Status = Blocked` behind a gate that is already `Done` — invisible to the drain
(Todo-only), to the open-gate re-checks (the gate is closed), and to every other rule here. It
flags a `Status = Blocked` item ALL of whose blockers are `Done` when at least one blocker is an
`[operator-action]` gate (title from the index; a live or unknown blocker still genuinely holds the
issue, so the rule stays silent — same SOLE/SATISFIED discipline as retired-recirc). But a `Done`
gate does NOT by itself prove the guarded dispose ran — a legacy/manual close, a raw `Status` edit,
or a janitor repair also mints `Done` (round-13 P1). So `--journal <path>` TIERS the finding through
the centralized gate-proof reader: either `guarded-dispose` or `verified-reconciliation` is a proven
`stranded-gate` (a genuine interrupted proof-then-unblock — finish through the guarded pointer door);
a gate whose `Done` carries neither recognized proof is `unproven-gate-done` — its dependents must
NOT be auto-unblocked (a raw-closed requirements
gate whose Think PR never merged would otherwise admit draft requirements). Without `--journal` the
rule cannot prove it and flags `stranded-gate` with a VERIFY-the-journal-first remediation. Fires
only when the caller supplies the Blocked item's `blocked_by` and its blockers' `title`/`status` in
the index (doctor Row 9's recipe does); tallies ride the flagged parens as conditional
`, <K> stranded-gate` / `, <U> unproven-gate-done` clauses. Flagged items ride index-only (never
schema-scanned, not counted in `scanned`).

`--fix` EMITS the repair (this stdin tool has no live board handle, so it never mutates a board): one
`would-fix: #<n> Status=Todo` line per empty-Status item, printed after the summary, for a caller to
apply (future-tense token — the tool proposes the repair, it does not perform it).

Usage: idc_board_lint.py [--fix] [--journal <path>] < issues.json  (exit 0 = ran OK; 2 = bad input)
"""
import json
import os
import re
import sys

# Reuse Plan's schema check (same directory) rather than re-implement the contract shape.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_schema_check  # noqa: E402
import idc_gate_proof  # noqa: E402

# An `[operator-action]` gate issue is the operator's own hand-filed item, never a goal-contract —
# Autorun's drain already excludes it from build work, and it would always "fail" the contract
# schema. Skip it here so it is never a false positive.
OPERATOR_GATE_PREFIX = "[operator-action]"
REQUIREMENTS_GATE_PREFIX = "[operator-action] Requirements change"


def is_requirements_gate_title(title):
    """True only for the requirements-change gate title emitted by the gate skill.

    The ASCII-hyphen spelling is retained for old gates created before the canonical em dash was
    documented. Decision gates and arbitrary operator-action items are deliberately excluded.
    """
    title = str(title or "").strip()
    return (title == REQUIREMENTS_GATE_PREFIX
            or title.startswith(REQUIREMENTS_GATE_PREFIX + " — ")
            or title.startswith(REQUIREMENTS_GATE_PREFIX + " - "))

# The retired-recirc rule resolves each native blocked-by to its board lane. A blocker that resolves
# to a `Stage = Recirculation` ticket already `Status = Done` is a RETIRED recirculation ticket — its
# scope was admitted as a consideration, so Plan's paused-issue re-link (idc-plan Phase 4) should have
# re-pointed this issue OFF it onto the real new unblockers. If that link is the issue's last blocker,
# the issue is spuriously eligible (the premature-eligibility / infinite-recirc trap).
RECIRC_STAGE = "Recirculation"
CONSIDERATION_STAGE = "Consideration"
DONE_STATUS = "Done"
# The empty-Status invariant stages (#255/#256): a pointer/ticket in EITHER of these stages MUST
# carry a Status — a Stage-without-Status pointer is invisible to the dropped-handoff detector, so it
# silently never drains. board-lint flags such an item `empty-status`; `--fix` repairs it to
# `Status=Todo`. These items ride INDEX-ONLY (not build-eligible), so the rule evaluates them on a
# SEPARATE path from in_scan_lane (never schema-scanning their non-contract bodies).
INVARIANT_STAGES = (RECIRC_STAGE, CONSIDERATION_STAGE)
# The repair target: a well-formed pointer is picked up by the drain at Status=Todo.
FIX_STATUS = "Todo"
# Build-eligible-lane sentinels: an input object IS scanned (schema/prose/retired) only when it is in
# this lane; an object explicitly outside it (e.g. the Done Recirculation blocker) rides in INDEX-ONLY
# to supply a blocker's stage/status and is never schema-scanned (its non-contract body would
# false-flag) nor counted as `scanned`.
BUILDABLE_STAGE = "Buildable"
TODO_STATUS = "Todo"
# The stranded-gate rule's subject lane: a gate-parked dependent whose gate has since gone Done.
BLOCKED_STATUS = "Blocked"

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


def _proven_gates(journal_path):
    """Map each gate carrying a recognized journal proof to its proof kind.

    Proof interpretation is centralized in ``idc_gate_proof.proof_kind``: both a guarded disposal
    and a valid verified reconciliation are proof. A Done gate absent from this map reached Done
    without either recognized record, so its dependents must never be auto-unblocked.

    FAIL-CLOSED: an unreadable/corrupt journal (or the replay helper being unavailable) yields the
    EMPTY mapping — every Done gate then reads as UNPROVEN, the safe direction (deny auto-unblock),
    never a permissive all-proven. Archive-aware and sidecar-lock-safe (reuses the engine's own
    strict scan, so it sees the same records the dispose-corroboration guard does)."""
    try:
        import idc_journal_replay as RP  # noqa: E402 — same-dir helper (sys.path set at import time)
    except Exception:
        return {}
    entries, err = RP.scan_journal_strict(journal_path)
    if err or entries is None:
        return {}
    return idc_gate_proof.proof_kinds(entries)


def stranded_gate_evidence(status, blocked_by, stage_status, titles, proven_gates=None):
    """Return ``(kind, evidence)`` for a Blocked dependent whose every blocker is Done and at least
    one is an `[operator-action]` gate, else ``("", "")``.

    `kind` is one of:
      * ``"stranded-gate"`` — one recognized gate proof IS journaled, OR the journal was
        not supplied so it must be verified: an interrupted dispose-then-unblock. SAFE (once
        verified) to finish the unblock.
      * ``"unproven-gate-done"`` — the journal WAS supplied and the gate is Done but carries NO
        recognized proof. A `Done` gate does NOT prove approval: a legacy/manual
        close, a raw `Status` edit, or a janitor repair also mints `Done` (codex round-13 P1). Its
        dependents must NOT be auto-unblocked — a raw-closed requirements gate whose Think PR never
        merged would otherwise admit draft requirements.

    The gate skill's step 4 (dispose-FIRST, then unblock — the round-10 reorder that closed the
    revoked-approval fail-open) leaves one liveness gap: a run killed between the gate's guarded
    dispose (gate → Done, journaled) and the dependent unblock. The dependent then sits
    `Status = Blocked` forever — the drain's build-candidate lane is Todo-only, and every
    start-of-run gate re-check queries OPEN gates (this one is closed). This rule is that strand's
    deterministic surface (round-11 close-out); the recovery is the gate skill's documented one —
    finish through `idc_gate_repair.py --finish-pointer`, never a raw engine unblock/setField — but
    ONLY once either recognized proof is confirmed journaled (`Done` alone is not proof).

    `proven_gates` (mapping of gate item numbers to centralized proof kind, or ``None`` when no
    journal was supplied) drives the tiering. When supplied, a
    dependent is `stranded-gate` only if EVERY gate blocking it is proven; any unproven gate blocker
    → `unproven-gate-done` (naming that gate). When ``None``, the rule cannot prove it here, so it
    flags `stranded-gate` with a remediation that REQUIRES verifying the journal first.

    SOLE/SATISFIED semantics (same as retired-recirc): flag ONLY when **every** blocker is Done —
    a live (status ≠ Done) or unknown (absent from the index) blocker genuinely holds the issue —
    AND at least one Done blocker is an `[operator-action]` gate (title from the index; an
    untitled/unknown blocker never reads as a gate). `blocked_by` tri-state as everywhere:
    `None` = UNKNOWN → silent."""
    if status != BLOCKED_STATUS or not blocked_by:
        return ("", "")
    if not all(stage_status.get(b, (None, None))[1] == DONE_STATUS for b in blocked_by):
        return ("", "")  # a live or unknown blocker still genuinely holds the issue — not stranded
    gate_blockers = [b for b in blocked_by
                     if str(titles.get(b, "")).strip().startswith(OPERATOR_GATE_PREFIX)]
    if not gate_blockers:
        return ("", "")
    if proven_gates is not None:
        # Journal supplied: a dependent is safe to auto-unblock ONLY if EVERY gate blocking it is
        # proven by either recognized kind. Any unproven gate → the Done is UNPROVEN.
        unproven = [b for b in gate_blockers if b not in proven_gates]
        if unproven:
            g = unproven[0]
            return ("unproven-gate-done",
                    f"Status={BLOCKED_STATUS} behind gate #{g} that is {DONE_STATUS} but has NO "
                    "recognized journal proof (guarded-dispose or verified-reconciliation) — the "
                    f"{DONE_STATUS} is UNPROVEN (a raw close, a manual Status edit, or a janitor "
                    "repair also mints Done, none of which validated the approval); do NOT "
                    "auto-unblock — confirm the gate was legitimately approved (its Think PR "
                    "merged), establish reciprocal markers through idc_pr_gate_bind.py if needed, "
                    "then run full `idc_gate_repair.py --gate <gate#> --pointer <dependent#> --pr "
                    "<Think-PR#>` dry-run/apply; that door journals verified-reconciliation before "
                    "it owns the guarded pointer tail — never call the engine unblock directly")
        g = gate_blockers[0]
        proof_kind = (proven_gates.get(g) if hasattr(proven_gates, "get")
                      else idc_gate_proof.GUARDED_DISPOSE)
        return ("stranded-gate",
                f"Status={BLOCKED_STATUS} behind gate #{g} that is already {DONE_STATUS} — the "
                f"gate's proof IS journaled ({proof_kind}), so this is an interrupted "
                "proof-then-unblock; finish it through `idc_gate_repair.py --finish-pointer` "
                "(idc:idc-gate-issue step 4 recovery), never a raw engine `unblock` or setField")
    # No journal supplied: flag the strand, but the remediation REQUIRES verifying the journaled
    # recognized proof first — a Done gate alone does not prove approval.
    g = gate_blockers[0]
    return ("stranded-gate",
            f"Status={BLOCKED_STATUS} behind gate #{g} that is already {DONE_STATUS} — VERIFY the "
            f"gate's journaled proof (guarded-dispose or verified-reconciliation naming #{g}) "
            "FIRST; only then finish the interrupted unblock through "
            "`idc_gate_repair.py --finish-pointer` (idc:idc-gate-issue step 4 recovery), never a raw "
            "engine `unblock` or setField — if it "
            "is not journaled the Done is UNPROVEN (a raw/manual close), so do NOT unblock")


def is_empty_status(status):
    """Whether a Status counts as EMPTY for the invariant rule.

    `idc_gh_board.py` OMITS an absent field, and doctor's index pass re-materializes a missing Status
    as the sentinel string `"none"` — so "no Status" arrives as `None`, `""`, or `"none"`. All three
    mean the pointer carries no real Status and must flag. `Status=Todo` (or any other real status) is
    the valid, non-flagged state."""
    if status is None:
        return True
    s = str(status).strip()
    return s == "" or s.lower() == "none"


def empty_status_evidence(stage, status):
    """Return a short evidence string if a Stage∈{Consideration,Recirculation} item carries an
    empty/missing Status (the #255/#256 detector-blinding bug), else ''.

    A pointer created with a Stage but no Status is invisible to the dropped-handoff detector, so it
    silently never drains. This enforces the Stage∈{Consideration,Recirculation} invariant: those
    stages MUST carry a Status. Evaluated on a SEPARATE path from in_scan_lane so the item's
    non-contract body is never schema-scanned."""
    if stage not in INVARIANT_STAGES or not is_empty_status(status):
        return ""
    return (f"Stage={stage} carries an empty/missing Status — invisible to the dropped-handoff "
            f"detector (#255/#256); --fix sets Status={FIX_STATUS}")


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


def lint(issues, proven_gates=None):
    """Return (lines, scanned, schema_count, prose_count, retired_count, unknown_count,
    empty_status_count, stranded_count, unproven_count, fixes).

    `proven_gates` (set | None) tiers the stranded-gate rule — see stranded_gate_evidence: a Done
    gate whose guarded dispose is journaled is `stranded-gate`, one whose Done is unproven is
    `unproven-gate-done`. `None` (no journal supplied) flags every strand `stranded-gate` with a
    verify-first remediation.

    `fixes` is the list of item numbers flagged empty-status (the records `--fix` repairs to
    Status=Todo)."""
    lines = []
    scanned = schema_count = prose_count = retired_count = unknown_count = empty_status_count = 0
    stranded_count = unproven_count = 0
    fixes = []
    # Blocker-resolution index: {number: (stage, status)} over the WHOLE input, so the retired-recirc
    # rule can resolve each native blocked-by to its board lane. Index-only entries (a Done
    # Recirculation ticket) ride in solely to populate this — see in_scan_lane().
    stage_status = {it.get("number"): (it.get("stage"), it.get("status")) for it in issues}
    # Title index over the WHOLE input: the stranded-gate rule resolves a blocker number to its
    # title to recognise an [operator-action] gate (index-only objects carry title when the caller
    # supplies it; an absent title simply never reads as a gate).
    titles = {it.get("number"): it.get("title") or "" for it in issues}
    for it in issues:
        title = str(it.get("title", "")).strip()
        if title.startswith(OPERATOR_GATE_PREFIX):
            continue  # the operator's gate issue — not a goal-contract, never built cold
        # Empty-Status invariant (Consideration/Recirculation): a SEPARATE path from the build-eligible
        # scan — these items ride index-only (in_scan_lane is False), so their non-contract bodies are
        # never schema-scanned; they are NOT counted toward `scanned` (that stays build-eligible-only).
        empty_ev = empty_status_evidence(it.get("stage"), it.get("status"))
        if empty_ev:
            empty_status_count += 1
            num = it.get("number", "?")
            fixes.append(num)
            label = f'#{num} "{title}"' if title else f"#{num}"
            lines.append(f"{label}: empty-status — {empty_ev}")
        # Stranded-gate (round-11 close-out; round-13 journal tiering): ALSO a separate index-only
        # path (a Blocked item is never in the scan lane) — see stranded_gate_evidence for the strand,
        # the proven/unproven tiering, and the recovery.
        stranded_kind, stranded_ev = stranded_gate_evidence(
            it.get("status"), it.get("blocked_by"), stage_status, titles, proven_gates)
        if stranded_kind:
            num = it.get("number", "?")
            label = f'#{num} "{title}"' if title else f"#{num}"
            if stranded_kind == "unproven-gate-done":
                unproven_count += 1
            else:
                stranded_count += 1
            lines.append(f"{label}: {stranded_kind} — {stranded_ev}")
        elif it.get("status") == BLOCKED_STATUS and it.get("blocked_by") is None:
            # A `Status = Blocked` item whose dependency lookup FAILED (`blocked_by: null`) makes the
            # stranded-gate check INDETERMINATE, not clean — but a Blocked item is index-only, so it
            # exits below BEFORE the scan-lane `unknown_count` increment. Count it here (surfaced in
            # the same `dependency lookups indeterminate` summary clause) so a Blocked-lane read
            # outage can't masquerade as a clean board (codex round-15 P2). Not a finding — the
            # stranded-gate check simply could not run for this item.
            unknown_count += 1
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
    return (lines, scanned, schema_count, prose_count, retired_count, unknown_count,
            empty_status_count, stranded_count, unproven_count, fixes)


def main():
    import argparse
    # argparse with a single optional flag; a bare `python3 idc_board_lint.py` (no args) is unchanged.
    ap = argparse.ArgumentParser(
        prog="idc_board_lint.py",
        description="Advisory board-lane lint (reads issue JSON on stdin).")
    ap.add_argument("--fix", action="store_true",
                    help="emit the repaired record (Status=Todo) for each empty-Status item a caller "
                         "applies to the live board (board-lint has no board handle; it never mutates)")
    ap.add_argument("--journal", default=None,
                    help="path to the transition journal (docs/workflow/transition-journal.ndjson); "
                         "when supplied, the stranded-gate rule tiers a Done gate through the "
                         "central proof reader — either recognized proof rides `stranded-gate` (safe "
                         "to finish the unblock), a gate whose Done is NOT journaled rides "
                         "`unproven-gate-done` (do NOT auto-unblock). Absent → every strand is "
                         "`stranded-gate` with a verify-the-journal-first remediation")
    opts = ap.parse_args()

    try:
        issues = read_issues(sys.stdin.read())
    except (json.JSONDecodeError, ValueError) as e:
        sys.stderr.write(f"idc-board-lint: cannot parse stdin as JSON issues: {e}\n")
        sys.exit(2)
    for it in issues:
        if not isinstance(it, dict):
            sys.stderr.write("idc-board-lint: each issue must be a JSON object\n")
            sys.exit(2)

    # Only READ the journal when --journal is supplied (the tiering is opt-in; a bare invocation is
    # byte-for-byte unchanged). Fail-closed inside _proven_gates: an unreadable journal → empty set
    # → every Done gate reads UNPROVEN (deny auto-unblock), never a permissive all-proven.
    proven_gates = _proven_gates(opts.journal) if opts.journal is not None else None

    (lines, scanned, schema_count, prose_count, retired_count, unknown_count,
     empty_status_count, stranded_count, unproven_count, fixes) = lint(issues, proven_gates)
    for ln in lines:
        print(ln)
    flagged = (schema_count + prose_count + retired_count + empty_status_count
               + stranded_count + unproven_count)
    # Append the degraded-lookup clause ONLY when >0 — when 0 the summary is byte-for-byte unchanged.
    _noun = "lookup" if unknown_count == 1 else "lookups"
    unknown_clause = f"; {unknown_count} dependency {_noun} indeterminate" if unknown_count else ""
    # The retired-recirc + empty-status + stranded-gate + unproven-gate-done tallies ride the flagged
    # parens as conditional clauses (like the degraded clause), so a board with zero of each keeps the
    # pre-existing summary byte-for-byte (the existing schema/prose-dep assertions stay green). The
    # unproven-gate-done clause appears only when the journal was supplied AND a Done gate is unproven.
    retired_clause = f", {retired_count} retired-recirc" if retired_count else ""
    empty_status_clause = f", {empty_status_count} empty-status" if empty_status_count else ""
    stranded_clause = f", {stranded_count} stranded-gate" if stranded_count else ""
    unproven_clause = f", {unproven_count} unproven-gate-done" if unproven_count else ""
    if flagged:
        print(f"board-lint: {flagged} flagged of {scanned} scanned "
              f"({schema_count} schema, {prose_count} prose-dep"
              f"{retired_clause}{empty_status_clause}{stranded_clause}{unproven_clause}{unknown_clause})")
    else:
        print(f"board-lint: clean ({scanned} scanned{unknown_clause})")
    # --fix: EMIT the repair (this stdin tool has no board handle, so it can't write back) — one
    # `would-fix: #<n> Status=Todo` line per empty-Status item, which a caller applies to the live
    # board. The token is future-tense on purpose: this tool never mutates, so a past-tense "fixed:"
    # would be a dishonest signal (the exact failure class this governance work exists to remove).
    if opts.fix:
        for num in fixes:
            print(f"would-fix: #{num} Status={FIX_STATUS}")
    sys.exit(0)


if __name__ == "__main__":
    # Broken-pipe guard: prints one line per flagged item, and this CLI already reads board JSON on
    # stdin — it lives mid-pipeline, where an early-exiting reader is the norm, not the exception.
    import idc_stdio
    raise SystemExit(idc_stdio.run_guarded(main))
