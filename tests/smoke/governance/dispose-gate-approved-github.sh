#!/bin/bash
# dispose-gate-approved-github.sh — governance scenario: the github `gate-approved` disposition
# verifies a REAL approval artifact BOUND to the gate — the gate's OWN recorded approval PR (the
# `idc-gate-pr` marker in the gate body) is merged AND reciprocally named by the LIVE PR body, OR
# (for an operator-DECISION gate only) the `decision-approved` label — not merely the caller's say-so.
# An unrelated merged PR, a one-sided gate-body marker, or a stray label can never terminalize an
# unapproved gate.
#
# In-process unit (github isn't hermetic): idc_gh_board._gh (issue/pr reads) + fetch_item + the
# item-id cache + idc_gh_close.close_issue are monkeypatched; assertions are on whether close_issue
# is called. Red-when-broken: neuter check_gate_approved (return without raising) → an unapproved
# gate, a PR-mismatch, a bare label on a requirements gate, or a non-gate item calls close_issue →
# this FAILs. Drop the reciprocal PR-body proof and trust the gate body alone → case (2c) FAILs.
# Derive the gate KIND from labels instead of the producer-stamped title (the codex round-10 P1
# retype door) → cases (10)/(10b) FAIL. Bind the body marker with `.search()` instead of
# `findall`+deny-on->1 (round-14 P1) → case (12) FAILs (an embedded merged-PR marker binds). Accept a
# comment-sourced marker on a requirements gate (round-14 P2) → case (6) FAILs.
#
# Usage: bash tests/smoke/governance/dispose-gate-approved-github.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github gate-approved unit failed (see above)"
import sys, json
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B, idc_gh_close as GC

# Board fixtures: issue# -> {title, labels, body}; pr# -> {state, mergedAt, body}.
GATE_PR = lambda n: f"<!-- idc-gate-pr: {n} -->"
ISSUES = {
    "5":  {"title": "[operator-action] Requirements change — greet by name", "labels": [], "body": "diff\n" + GATE_PR(9)},
    "6":  {"title": "[operator-action] Decision — commit to two-store rework",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}], "body": "the GO/NO-GO"},
    # NOT a gate — but carries a MERGED idc-gate-pr marker, so ONLY the title-prefix guard denies it
    # (isolates the operator-gate check: without it this ordinary item would close on a real artifact).
    "7":  {"title": "implement the greeting banner", "labels": [], "body": "work\n" + GATE_PR(9)},
    "8":  {"title": "[operator-action] Requirements change — add export", "labels": [], "body": GATE_PR(10)},
    "11": {"title": "[operator-action] Requirements change — bare label", "labels": [{"name": "decision-approved"}], "body": "no gate-pr marker"},
    # a DECISION gate with a decision-PR attached (unmerged) BUT approved via the label alternative.
    "12": {"title": "[operator-action] Decision — spike verdict",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}], "body": "spike\n" + GATE_PR(10)},
    # a DECISION gate with a STALE decision-approved label AND an explicit decision-rejected (NO-GO).
    "13": {"title": "[operator-action] Decision — reversed to NO-GO",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}, {"name": "decision-rejected"}], "body": "reversed"},
    # a LEGACY requirements gate (created before the idc-gate-pr marker) — Think PR only in prose.
    "14": {"title": "[operator-action] Requirements change — legacy gate", "labels": [], "body": "merge the Think PR (#9)"},
    # ROUND-14 P2 — a REQUIREMENTS gate whose ONLY idc-gate-pr marker rides a COMMENT is REFUSED: a
    # comment is any adapter caller's door, so it cannot bind the gate's approval PR. Even with the
    # body's own prose Think-PR pointer (#9), comment-only migration no longer approves — the operator
    # must stamp the marker in the gate BODY. (Old comment-migration cross-check removed — it matched a
    # body-wide "PR #N" anywhere, incl. an embedded diff, and the template's approval line has no PR#.)
    "15": {"title": "[operator-action] Requirements change — comment-only marker", "labels": [],
           "body": "merge the Think PR (#9)", "comments": [{"body": GATE_PR(9)}]},
    # a DECISION gate with a comment-only idc-gate-pr marker that ALSO carries the label pair: the
    # comment marker is simply ignored (never binds on its own), and the gate still approves via its
    # LABELS — comment-only refusal must not block a valid decision-label approval (round-14 P2).
    "16": {"title": "[operator-action] Decision — comment marker but label-approved",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}],
           "body": "the GO/NO-GO", "comments": [{"body": GATE_PR(9)}]},
    # a valid gate whose operator flips to NO-GO BETWEEN guard pass and close (TOCTOU, codex r8 P2):
    # the SECOND issue read (the pre-close recheck) sees decision-rejected.
    "17": {"title": "[operator-action] Decision — reversed mid-flight",
           "labels": [{"name": "decision"}], "body": "the GO/NO-GO\n" + GATE_PR(9)},
    # a valid gate whose board Status moves BETWEEN the guard-time snapshot and close (TOCTOU):
    # the SECOND fetch_item read (the pre-close recheck) sees Blocked.
    "18": {"title": "[operator-action] Requirements change — parked mid-flight", "labels": [],
           "body": "diff\n" + GATE_PR(9)},
    # a decision gate approved ONLY by its labels, whose decision-approved label is REMOVED (no
    # rejection added) between the guard and the close (codex r9 P2): the recheck must re-prove the
    # label approval still HOLDS, not merely the absence of a NO-GO.
    "19": {"title": "[operator-action] Decision — approval revoked mid-flight",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}], "body": "the GO/NO-GO"},
    # ROUND-10 P1 — labels must never RETYPE a gate: a REQUIREMENTS-titled gate (unmerged recorded
    # Think PR) relabeled decision+decision-approved through the adapter's label door. The gate KIND
    # is the producer-stamped TITLE (no adapter door), so the label path stays closed to it.
    "20": {"title": "[operator-action] Requirements change — relabeled as decision",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}], "body": "diff\n" + GATE_PR(10)},
    # the same relabel attack on a MARKERLESS requirements gate (no recorded PR at all).
    "21": {"title": "[operator-action] Requirements change — markerless relabel",
           "labels": [{"name": "decision"}, {"name": "decision-approved"}],
           "body": "merge the Think PR when it opens"},
    # a genuine DECISION-titled gate carrying decision-approved WITHOUT the `decision` label: the
    # documented GO signal is the label PAIR (the close-time recheck re-proves the same pair).
    "22": {"title": "[operator-action] Decision — pair incomplete",
           "labels": [{"name": "decision-approved"}], "body": "the GO/NO-GO"},
    # ROUND-14 P1 — TWO idc-gate-pr markers in the body: an embedded one (naming MERGED #9, inside an
    # inline PRD/TRD diff) BEFORE the canonical footer (naming the OPEN real Think PR #10). A bare
    # `.search()` binds the FIRST (#9, merged) → would close on the wrong PR while the real Think PR is
    # open. `findall` + fail-closed-on->1 refuses the ambiguity.
    "23": {"title": "[operator-action] Requirements change — double marker", "labels": [],
           "body": "```diff\n+ migrated a gate doc that shows " + GATE_PR(9) + "\n```\n"
                   "TO APPROVE: merge the Think PR.\n" + GATE_PR(10)},
    # One-sided gate-body evidence is insufficient: the gate body names a MERGED PR, but the LIVE PR
    # body reciprocally binds a DIFFERENT gate. The terminal path must refuse this stale/foreign proof.
    "24": {"title": "[operator-action] Requirements change — one-sided gate body", "labels": [],
           "body": "diff\n" + GATE_PR(9)},
}
PRS = {"9": {"state": "MERGED", "mergedAt": "2026-07-09T00:00:00Z", "body": "PR\n\n" + GATE_PR(5)},
       "10": {"state": "OPEN", "mergedAt": None, "body": "PR\n\n" + GATE_PR(8)}}

VIEWS = {}
def fake_gh(args, r):
    if args[:2] == ["issue", "view"]:
        n = args[2]
        VIEWS[n] = VIEWS.get(n, 0) + 1
        issue = dict(ISSUES[n])
        if n == "17" and VIEWS[n] >= 2:   # the late NO-GO lands after the guard's read
            issue["labels"] = issue["labels"] + [{"name": "decision-rejected"}]
        if n == "19" and VIEWS[n] >= 2:   # the label approval is REVOKED after the guard's read
            issue["labels"] = [l for l in issue["labels"] if l["name"] != "decision-approved"]
        return json.dumps(issue)
    if args[:2] == ["pr", "view"]:
        return json.dumps(PRS[args[2]])
    raise AssertionError(f"unexpected gh call: {args}")
B._gh = fake_gh
FETCHES = {}
def fake_fetch(iid, r):
    FETCHES[iid] = FETCHES.get(iid, 0) + 1
    if iid == "PVTI_18" and FETCHES[iid] >= 2:   # the item is gate-parked after the guard-time snapshot
        return {"stage": "Consideration", "status": "Blocked"}
    return {"stage": "Consideration", "status": "Todo"}
B.fetch_item = fake_fetch
closed = []
GC.close_issue = lambda o, p, i, r, item_id=None: closed.append(i)
ctx = E.github_ctx(repo, "o", "1", itemid_cache={n: f"PVTI_{n}" for n in (5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24)})

def is_denied(fn):
    try: fn(); return False
    except E.TransitionError: return True

# (1) requirements gate whose recorded approval PR (idc-gate-pr: 9) is MERGED and reciprocally
# bound from the LIVE PR body → the gate closes.
closed.clear()
E.run("dispose", ctx, num=5, disposition="gate-approved")
assert closed == [5], f"gate + merged reciprocal approval PR did not close: {closed}"
print("  ok (1) a gate whose recorded idc-gate-pr approval PR is MERGED and reciprocal closes to Done")

# (2) requirements gate whose recorded approval PR (idc-gate-pr: 10) is UNMERGED → DENIED.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=8, disposition="gate-approved")), \
    "gate with an unmerged recorded PR was allowed"
assert closed == [], f"denied unapproved gate still closed: {closed}"
print("  ok (2) a gate whose recorded approval PR is UNMERGED is DENIED")

# (2b) a --gate-pr that is NOT the gate's recorded PR is DENIED (an unrelated merged PR can't approve).
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=5, disposition="gate-approved", gate_pr=10)), \
    "an unrelated --gate-pr (not the gate's recorded PR) was allowed"
assert closed == [], f"denied unbound --gate-pr still closed: {closed}"
print("  ok (2b) a --gate-pr that is not the gate's recorded approval PR is DENIED (bound to THIS gate)")

# (2c) one-sided gate-body evidence is DENIED: gate #24 points at MERGED PR #9, but PR #9's LIVE body
# binds gate #5, not #24. The gate body alone is never enough.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=24, disposition="gate-approved")), \
    "a one-sided gate-body marker (with no reciprocal PR-body proof) was allowed"
assert closed == [], f"denied one-sided gate still closed: {closed}"
print("  ok (2c) a one-sided gate-body marker is DENIED without the reciprocal LIVE PR-body proof")

# (3) an operator-DECISION gate (decision + decision-approved labels) → the gate closes.
closed.clear()
E.run("dispose", ctx, num=6, disposition="gate-approved")
assert closed == [6], f"decision gate + decision-approved label did not close: {closed}"
print("  ok (3) an operator-decision gate carrying the decision-approved label closes to Done")

# (3b) a REQUIREMENTS gate with only a decision-approved label (no decision gate, no merged PR) → DENIED.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=11, disposition="gate-approved")), \
    "a requirements gate was approved by a bare decision-approved label (must merge its Think PR)"
assert closed == [], f"denied bare-label requirements gate still closed: {closed}"
print("  ok (3b) a requirements gate with a bare decision-approved label is DENIED (needs its merged Think PR)")

# (3c) a DECISION gate with a decision-PR marker still OPEN, approved via the label alternative → closes.
# The label is a documented alternative signal for a decision gate; an unmerged bound PR must NOT block it.
closed.clear()
E.run("dispose", ctx, num=12, disposition="gate-approved")
assert closed == [12], f"decision gate approved by label (unmerged decision-PR attached) did not close: {closed}"
print("  ok (3c) a decision gate with an unmerged decision-PR closes on the decision-approved label (the alternative)")

# (3d) a decision gate with an explicit decision-rejected (NO-GO) label → DENIED even with a stale
# decision-approved label — an explicit rejection is never approved.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=13, disposition="gate-approved")), \
    "a decision-rejected (NO-GO) gate was approved despite the rejection"
assert closed == [], f"denied rejected gate still closed: {closed}"
print("  ok (3d) a gate carrying decision-rejected is DENIED even with a stale decision-approved label")

# (4) a NON-gate work item → DENIED (title is not an operator gate).
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=7, disposition="gate-approved", gate_pr=9)), \
    "a non-gate work item was allowed through gate-approved"
assert closed == [], f"denied non-gate item still closed: {closed}"
print("  ok (4) a non-[operator-action] work item is DENIED (no verdict-free backdoor)")

# (5) a LEGACY requirements gate (no idc-gate-pr marker) is REFUSED even with a MERGED --gate-pr — a
# caller-supplied PR is not BOUND to this gate, so it can never approve it; the gate must be MIGRATED
# (stamp its idc-gate-pr marker) so its OWN recorded PR is verified. --gate-pr is only a confirming
# cross-check of the marker, never an approval source on its own.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=14, disposition="gate-approved", gate_pr=9)), \
    "a legacy gate (no marker) was approved by a caller-supplied --gate-pr not bound to the gate"
assert closed == [], f"denied legacy gate still closed: {closed}"
print("  ok (5) a legacy gate (no idc-gate-pr marker) is REFUSED even with a merged --gate-pr — migrate the marker")

# (6) ROUND-14 P2 — a REQUIREMENTS gate whose ONLY idc-gate-pr marker rides a COMMENT is REFUSED,
# even WITH the body's own prose Think-PR pointer: a comment is any adapter caller's door, so it can
# never bind the gate's approval PR. The remediation names the BODY-stamp migration.
closed.clear()
try:
    E.run("dispose", ctx, num=15, disposition="gate-approved")
    raise SystemExit("FAIL: a requirements gate with a comment-only idc-gate-pr marker was approved")
except E.TransitionError as e:
    assert "rides a COMMENT" in str(e) and "gate BODY" in str(e), \
        f"the comment-only denial does not name the body-stamp remediation (round-14 P2): {e}"
assert closed == [], f"the comment-only requirements gate still closed: {closed}"
print("  ok (6) a requirements gate whose only idc-gate-pr marker is in a COMMENT is REFUSED (body-stamp migration; round-14 P2)")

# (6b) comment-only refusal must NOT block a DECISION gate's LABEL approval: #16 carries a comment
# marker (ignored) AND the decision/decision-approved pair → it closes via the labels (the alternative
# signal), proving the round-14 P2 refusal is scoped to the marker path, not the whole gate.
closed.clear()
E.run("dispose", ctx, num=16, disposition="gate-approved")
assert closed == [16], f"a decision gate with a comment marker + valid labels did not close via the label path: {closed}"
print("  ok (6b) a decision gate with a comment-only marker still closes on its decision-approved label (marker ignored)")

# (7) TOCTOU — a decision gate reversed to NO-GO between the guard's read and the close: the
# pre-close label recheck sees decision-rejected → DENIED, nothing closed.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=17, disposition="gate-approved")), \
    "a gate that gained decision-rejected mid-disposition was still closed (guard→close race)"
assert closed == [], f"the late-NO-GO gate still closed: {closed}"
print("  ok (7) a late NO-GO landing between guard and close is caught by the pre-close recheck")

# (8) TOCTOU — the item's board Status moves (Todo → Blocked) between the guard-time snapshot and
# the close: the pre-close state recheck refuses on the drift → DENIED, nothing closed.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=18, disposition="gate-approved")), \
    "an item whose Status moved mid-disposition was still closed (guard→close race)"
assert closed == [], f"the mid-flight-parked gate still closed: {closed}"
print("  ok (8) a Status move between the guard snapshot and the close is refused by the recheck")

# (9) TOCTOU — a label-based approval REVOKED (decision-approved removed, no rejection added)
# between guard and close: the recheck re-proves the approval still holds → DENIED, nothing closed.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=19, disposition="gate-approved")), \
    "a gate whose label approval was revoked mid-disposition was still closed (recheck only looked for a NO-GO)"
assert closed == [], f"the revoked-approval gate still closed: {closed}"
print("  ok (9) a label approval revoked between guard and close is refused (the approval must HOLD at close)")

# (10) ROUND-10 P1 — labels can never RETYPE a gate: a requirements-TITLED gate with an unmerged
# recorded PR + the decision/decision-approved label pair is DENIED. The gate KIND comes from the
# producer-stamped title (`[operator-action] Decision — …`), which has no adapter door — labels are
# any caller's, so relabeling must not reroute a requirements gate onto the label-approval path.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=20, disposition="gate-approved")), \
    "a requirements gate relabeled decision+decision-approved bypassed its unmerged Think PR (label retype)"
assert closed == [], f"the relabeled requirements gate still closed: {closed}"
print("  ok (10) a requirements gate relabeled decision+decision-approved is DENIED (kind = producer title, not labels)")

# (10b) the same relabel attack on a MARKERLESS requirements gate — the label pair alone must
# approve nothing (before the title-kind rule, this closed with NO artifact at all).
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=21, disposition="gate-approved")), \
    "a markerless requirements gate relabeled decision+decision-approved closed via the label path"
assert closed == [], f"the markerless relabeled gate still closed: {closed}"
print("  ok (10b) a markerless requirements gate with the label pair is DENIED (labels alone approve nothing)")

# (11) a decision-TITLED gate with decision-approved but NO `decision` label → DENIED AT THE GUARD:
# the documented GO signal is the label PAIR. The close-time recheck (round 9) re-proves the same
# pair, so the denial must come from the GUARD's no-artifact message — pinning the guard-side
# conjunct specifically, not the recheck masking a half-pair admit.
closed.clear()
try:
    E.run("dispose", ctx, num=22, disposition="gate-approved")
    raise SystemExit("FAIL: a decision gate with an incomplete label pair (no `decision` label) was approved")
except E.TransitionError as e:
    assert "no bound approval artifact" in str(e), \
        f"the incomplete pair was admitted by the GUARD and only caught later (denial: {e})"
assert closed == [], f"the incomplete-pair gate still closed: {closed}"
print("  ok (11) a decision-titled gate needs the FULL decision/decision-approved pair AT THE GUARD")

# (12) ROUND-14 P1 — TWO idc-gate-pr markers in the body must FAIL CLOSED on the ambiguity: #23's
# embedded marker names MERGED #9 (inside an inline diff, BEFORE the footer) while the canonical
# footer names the OPEN real Think PR #10. A bare `.search()` binds the FIRST (#9, merged) and would
# close on the wrong PR; `findall` + deny-on->1 refuses. Mutation proof: revert to `.search()` → #23
# closes on #9.
closed.clear()
try:
    E.run("dispose", ctx, num=23, disposition="gate-approved")
    raise SystemExit("FAIL: a gate with two idc-gate-pr body markers closed (an embedded merged-PR marker bound)")
except E.TransitionError as e:
    assert "idc-gate-pr markers in its body" in str(e), \
        f"the double-marker denial does not name the ambiguity (round-14 P1): {e}"
assert closed == [], f"the double-marker gate still closed: {closed}"
print("  ok (12) two idc-gate-pr body markers FAIL CLOSED — an embedded merged-PR marker can never bind (round-14 P1)")
PY

echo "PASS: github gate-approved closes a gate ONLY on a gate-BOUND approval artifact (the gate's recorded idc-gate-pr marker in the BODY is merged AND reciprocally bound from the LIVE PR body — comment-only markers are refused; or the decision/decision-approved label pair on a DECISION-TITLED gate — the kind is the producer-stamped title, never labels); an unmerged/unbound/one-sided PR, any label pair on a requirements gate, a non-gate item, a comment-only requirements marker, TWO body markers (ambiguity), and both guard→close races (late NO-GO, mid-flight Status move) perform no gh close"
