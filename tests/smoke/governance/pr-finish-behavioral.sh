#!/bin/bash
# idc-assert-class: behavior
# pr-finish-behavioral.sh — the sanctioned PR finisher's SAFETY CONTRACT, exercised behaviorally
# (Task 3, round-4 Fix 4).
#
# The CLI-contract test proves argparse ACCEPTS the documented invocations; this proves the finisher
# actually ENFORCES its safety rules. It stubs the two external seams — `gh` (via idc_pr_finish._gh,
# simulating PR/gate states) and the engine tail (via idc_pr_finish._transition, recording the
# dispose/unblock ops) — and drives the REAL cmd_autonomous / cmd_requirements logic:
#
#   autonomous:
#     * REJECTS a PR whose head does not match the kind's branch prefix (plan/ · recirc/ · intake/) —
#       BEFORE any merge;
#     * on a valid OPEN+MERGEABLE, matching-prefix PR: merges (squash+delete) and re-reads MERGED, and
#       NEVER mutates a tracker item (no dispose/unblock).
#   requirements EXITS BEFORE any tracker mutation when the PR is:
#     * markerless / double-marked / bound to ANOTHER PR;
#     * unmerged with no --operator-approved (IDC never infers approval), i.e. open-without-approval;
#   requirements on the legal paths does DISPOSE-BEFORE-UNBLOCK:
#     * already-merged → dispose(gate-approved) THEN unblock; if dispose FAILS it does NOT unblock;
#     * open + --operator-approved → merges the bound PR, re-verifies MERGED, then the same tail.
#
# Red-when-broken: drop the prefix check / the marker validation / the merge-state re-read / the
# dispose-before-unblock ordering → the matching assertion below FAILs.
#
# Usage: bash tests/smoke/governance/pr-finish-behavioral.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FIN="$GOV_PLUGIN/scripts/idc_pr_finish.py"
[ -f "$FIN" ] || gov_fail "idc_pr_finish.py not found at $FIN"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || gov_fail "pr-finish behavioral unit failed (see above)"
import contextlib, io, json, sys
sys.path.insert(0, sys.argv[1])
import idc_pr_finish as F

MARK = "<!-- idc-gate-pr: %d -->"

def install(state):
    """Wire the two external seams to a mutable `state`, recording the EXACT merge argv, every `pr
    view` re-read, and the dispose/unblock ops."""
    state.setdefault("merge_args", [])       # the FULL argv of each `gh pr merge` (exact-flag proof)
    state.setdefault("pr_views", 0)          # count of `pr view` reads (the post-merge re-read proof)
    state.setdefault("transitions", [])

    def fake_gh(args, repo):
        a = list(args)
        if a[:2] == ["pr", "view"]:
            state["pr_views"] += 1
            return json.dumps(state["pr"])
        if a[:2] == ["pr", "merge"]:
            state["merge_args"].append(a)
            if state.get("merge_cli_fails"):
                # A NONZERO merge CLI result — but the server DID merge (a nonzero branch-cleanup step).
                state["pr"] = dict(state["pr"], state="MERGED", mergedAt="2026-01-01T00:00:00Z")
                raise F.FinishError("simulated nonzero merge CLI (branch-delete step failed)", code=2)
            state["pr"] = dict(state["pr"], state="MERGED", mergedAt="2026-01-01T00:00:00Z")
            return ""
        if a[:2] == ["issue", "view"]:
            return json.dumps({"body": state.get("gate_body", "")})
        raise AssertionError(f"unexpected gh call reached the stub: {a!r}")

    def fake_transition(args, extra):
        state["transitions"].append(list(extra))
        if state.get("dispose_fails") and extra and extra[0] == "dispose":
            raise F.FinishError("simulated dispose refusal", code=2)
        return "{}"

    F._gh = fake_gh
    F._transition = fake_transition
    return state

def run(state, argv):
    """Drive the REAL finisher against `state`; return (rc, merge_pr_numbers, transitions) for the
    legacy assertions, and stash merge_args / pr_views / the parsed receipt back on `state`."""
    install(state)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = F.main(argv)
    state["rc"] = rc
    try:
        state["receipt"] = json.loads(buf.getvalue()) if buf.getvalue().strip() else None
    except ValueError:
        state["receipt"] = None
    merges = [int(a[2]) for a in state["merge_args"]]
    return rc, merges, state["transitions"]

fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)

SQUASH_DELETE = ["--squash", "--delete-branch"]

# ── autonomous ────────────────────────────────────────────────────────────────────────────────────
# (1) wrong branch prefix → rejected BEFORE any merge.
st = {"pr": {"state": "OPEN", "mergeable": "MERGEABLE", "headRefName": "feature/x"}}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "planning"])
check(rc == 2, f"autonomous wrong-prefix should exit 2, got {rc}")
check(merges == [], f"autonomous wrong-prefix must NOT merge, merged={merges}")
print("  ok autonomous REJECTS a mismatched-prefix PR before merging")

# (2) valid open+mergeable, matching prefix → merges with EXACTLY `--squash --delete-branch`, does a
#     SECOND `pr view` re-read to MERGED, and mutates NO tracker item.
st = {"pr": {"state": "OPEN", "mergeable": "MERGEABLE", "headRefName": "plan/x"}}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "planning"])
check(rc == 0, f"autonomous valid should exit 0, got {rc}")
check(merges == [12], f"autonomous valid must merge #12, merged={merges}")
check(trans == [], f"autonomous must NEVER mutate a tracker item, transitions={trans}")
# EXACT merge flags: a mutation to `--auto` (or dropping the flags) makes this FAIL.
check(st["merge_args"] and st["merge_args"][0][3:] == SQUASH_DELETE,
      f"merge must be EXACTLY `--squash --delete-branch` (never --auto), got {st['merge_args']}")
# The SECOND `pr view` re-read: the initial state read + the post-merge MERGED re-read = 2. Removing
# the re-read drops this to 1 and FAILs.
check(st["pr_views"] >= 2, f"autonomous must RE-READ pr state after merge (>=2 pr view), got {st['pr_views']}")
check(st["receipt"] and st["receipt"].get("state") == "MERGED",
      f"receipt must confirm MERGED, got {st.get('receipt')}")
check(st["receipt"] and "branch_deleted" in st["receipt"],
      f"receipt must report the branch-deletion outcome, got {st.get('receipt')}")
check(st["receipt"] and st["receipt"].get("branch_deleted") is True,
      f"a clean merge deletes the branch → branch_deleted True, got {st.get('receipt')}")
print("  ok autonomous merges with EXACTLY --squash --delete-branch, RE-READS MERGED, reports branch deletion, touches no tracker")

# (2r) recirculation + intake kinds honor their branch prefixes and merge.
for kind, head in (("recirculation", "recirc/x"), ("intake", "intake/x")):
    st = {"pr": {"state": "OPEN", "mergeable": "MERGEABLE", "headRefName": head}}
    rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", kind])
    check(rc == 0, f"autonomous {kind} should exit 0, got {rc}")
    check(merges == [12] and st["merge_args"][0][3:] == SQUASH_DELETE,
          f"autonomous {kind} must merge with --squash --delete-branch, got {st['merge_args']}")
# wrong prefix for a recirculation PR → refuse.
st = {"pr": {"state": "OPEN", "mergeable": "MERGEABLE", "headRefName": "plan/x"}}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "recirculation"])
check(rc == 2 and merges == [], f"autonomous recirculation with a plan/ head must refuse, rc={rc} merged={merges}")
print("  ok autonomous honors recirculation/intake prefixes and refuses a cross-kind head")

# (2n) NEGATIVE fail-closed: a not-OPEN PR and a not-MERGEABLE PR both refuse BEFORE any merge.
st = {"pr": {"state": "CLOSED", "mergeable": "MERGEABLE", "headRefName": "plan/x"}}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "planning"])
check(rc == 2 and merges == [], f"autonomous must refuse a not-OPEN PR before merging, rc={rc} merged={merges}")
st = {"pr": {"state": "OPEN", "mergeable": "CONFLICTING", "headRefName": "plan/x"}}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "planning"])
check(rc == 2 and merges == [], f"autonomous must refuse a not-MERGEABLE PR before merging, rc={rc} merged={merges}")
print("  ok autonomous fail-closes on a not-OPEN / not-MERGEABLE PR (no merge)")

# (2x) ROBUSTNESS: a NONZERO merge CLI result whose server-side merge DID land is still recognized
#      MERGED (success), with branch_deleted reported False (the nonzero cleanup step failed).
st = {"pr": {"state": "OPEN", "mergeable": "MERGEABLE", "headRefName": "plan/x"}, "merge_cli_fails": True}
rc, merges, trans = run(st, ["autonomous", "--repo", ".", "--pr", "12", "--kind", "planning"])
check(rc == 0, f"a server-merged PR with a nonzero cleanup step must still succeed, got rc={rc}")
check(st["receipt"] and st["receipt"].get("state") == "MERGED",
      f"nonzero-cleanup merge must still be recognized MERGED, got {st.get('receipt')}")
check(st["receipt"] and st["receipt"].get("branch_deleted") is False,
      f"a nonzero cleanup step means the branch delete did not complete → branch_deleted False, got {st.get('receipt')}")
print("  ok a server-merged PR with a nonzero branch-cleanup step is recognized MERGED (branch_deleted reported False)")

# ── requirements: fail-closed BEFORE any tracker mutation ──────────────────────────────────────────
def req(state_extra, argv_extra=()):
    base = {"pr": {"state": "MERGED", "mergeable": "MERGEABLE", "mergedAt": "2026-01-01T00:00:00Z"}}
    base.update(state_extra)
    return run(base, ["requirements", "--repo", ".", "--pr", "12", "--gate", "5", "--pointer", "7",
                      *argv_extra])

for label, extra in [
    ("markerless", {"gate_body": ""}),
    ("double-marked", {"gate_body": (MARK % 12) + "\n" + (MARK % 12)}),
    ("bound-to-another-PR", {"gate_body": MARK % 99}),
]:
    rc, merges, trans = req(extra)
    check(rc == 2, f"requirements {label} should exit 2, got {rc}")
    check(trans == [], f"requirements {label} must exit BEFORE any tracker mutation, transitions={trans}")
    check(merges == [], f"requirements {label} must not merge, merged={merges}")
print("  ok requirements exits before mutation on markerless / double-marked / other-PR-bound gates")

# unmerged (open) with no --operator-approved → refuse (IDC never infers approval), no mutation/merge.
rc, merges, trans = req({"gate_body": MARK % 12,
                         "pr": {"state": "OPEN", "mergeable": "MERGEABLE", "mergedAt": None}})
check(rc == 2, f"requirements open-no-approval should exit 2, got {rc}")
check(trans == [] and merges == [], f"open-no-approval must not merge/mutate: merged={merges} trans={trans}")
print("  ok requirements refuses an OPEN PR with no --operator-approved (no merge, no mutation)")

# ── requirements: legal paths do DISPOSE-BEFORE-UNBLOCK ─────────────────────────────────────────────
# already merged → dispose(gate-approved) THEN unblock, in that order; no merge needed.
rc, merges, trans = req({"gate_body": MARK % 12})
check(rc == 0, f"requirements merged-happy should exit 0, got {rc}")
check(merges == [], f"already-merged path must NOT merge, merged={merges}")
ops = [t[0] for t in trans]
check(ops == ["dispose", "unblock"], f"must dispose THEN unblock, got {ops}")
check(trans and trans[0][:3] == ["dispose", "--disposition", "gate-approved"],
      f"first tail op must be dispose gate-approved, got {trans[:1]}")
print("  ok requirements (already merged) disposes gate-approved THEN unblocks, in order")

# dispose FAILS → the unblock must NOT run (dispose-before-unblock; a failed dispose stops the tail).
rc, merges, trans = req({"gate_body": MARK % 12, "dispose_fails": True})
check(rc == 2, f"requirements dispose-fail should exit 2, got {rc}")
check([t[0] for t in trans] == ["dispose"], f"a failed dispose must NOT reach unblock, got {trans}")
print("  ok requirements does NOT unblock when the dispose fails")

# open + --operator-approved → merges the bound PR, re-verifies MERGED, then the same tail.
rc, merges, trans = req({"gate_body": MARK % 12,
                         "pr": {"state": "OPEN", "mergeable": "MERGEABLE", "mergedAt": None}},
                        ("--operator-approved",))
check(rc == 0, f"requirements open+approved should exit 0, got {rc}")
check(merges == [12], f"open+approved must merge the bound PR, merged={merges}")
check([t[0] for t in trans] == ["dispose", "unblock"], f"open+approved must dispose THEN unblock, got {trans}")
print("  ok requirements (open + operator-approved) merges then disposes-before-unblocks")

if fails:
    print("FAIL:")
    for m in fails:
        print("   -", m)
    sys.exit(1)
PY

echo "PASS: the PR finisher enforces its safety contract — prefix gating, merge re-read, tracker-immutability (autonomous), marker validation, no-infer-approval, and dispose-before-unblock (requirements)"
