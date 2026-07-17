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
    """Wire the three external seams to a mutable `state`, recording the EXACT merge argv, every `pr
    view` re-read, the engine ops, and each pointer-finish DOOR invocation."""
    state.setdefault("merge_args", [])       # the FULL argv of each `gh pr merge` (exact-flag proof)
    state.setdefault("pr_views", 0)          # count of `pr view` reads (the post-merge re-read proof)
    state.setdefault("transitions", [])
    state.setdefault("finish_calls", [])     # the `apply_` of each pointer-finish door call

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

    def fake_finish_pointer(args, apply_):
        """Stand in for the real `idc_gate_repair.py --finish-pointer` door, mirroring its contract:
        a dry run REPORTS the pointer's other blockers (status `refused`) and writes nothing, and an
        `--apply` against remaining blockers raises. The door's own enforcement is proven for real —
        against a live tracker + journal — by the section below and by
        gate-repair-session-b7a93ff6.sh; here we prove the FINISHER routes through it and honors its
        verdict."""
        state["finish_calls"].append(bool(apply_))
        others = list(state.get("other_blockers") or [])
        if others and apply_:
            raise F.FinishError(f"simulated door refusal: also blocked by {others}", code=2)
        status = ("refused" if others else ("applied" if apply_ else "planned"))
        return {"steps": [{"id": "unblock-pointer", "other_blockers": others, "status": status}]}

    F._gh = fake_gh
    F._transition = fake_transition
    F._finish_pointer = fake_finish_pointer
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
    """Drive requirements mode; `st` is rebound to THIS run's state so the assertions below can read
    back its receipt / finish_calls."""
    global st
    st = {"pr": {"state": "MERGED", "mergeable": "MERGEABLE", "mergedAt": "2026-01-01T00:00:00Z"}}
    st.update(state_extra)
    return run(st, ["requirements", "--repo", ".", "--pr", "12", "--gate", "5", "--pointer", "7",
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
# already merged → dispose(gate-approved) THEN the pointer-finish door, in that order; no merge needed.
rc, merges, trans = req({"gate_body": MARK % 12})
check(rc == 0, f"requirements merged-happy should exit 0, got {rc}")
check(merges == [], f"already-merged path must NOT merge, merged={merges}")
ops = [t[0] for t in trans]
# The ONLY engine op the tail runs is the dispose: the pointer goes through the guarded door, so a
# raw `unblock` reappearing in the engine ops means the invariant was bypassed again (Task 7 wave 2b).
check(ops == ["dispose"], f"the tail's only raw engine op must be the dispose, got {ops}")
check(trans and trans[0][:3] == ["dispose", "--disposition", "gate-approved"],
      f"first tail op must be dispose gate-approved, got {trans[:1]}")
check(st["finish_calls"] == [False, True],
      f"the pointer must be finished through the DOOR (dry run, then --apply), got {st['finish_calls']}")
check(st["receipt"] and st["receipt"].get("unblock") == "applied",
      f"the receipt must report the pointer's real outcome, got {st.get('receipt')}")
print("  ok requirements (already merged) disposes gate-approved THEN finishes the pointer through the guarded door")

# dispose FAILS → the pointer-finish must NOT run (dispose-before-unblock; a failed dispose stops the tail).
rc, merges, trans = req({"gate_body": MARK % 12, "dispose_fails": True})
check(rc == 2, f"requirements dispose-fail should exit 2, got {rc}")
check([t[0] for t in trans] == ["dispose"], f"a failed dispose must NOT reach the pointer, got {trans}")
check(st["finish_calls"] == [], f"a failed dispose must never reach the pointer-finish door, got {st['finish_calls']}")
print("  ok requirements does NOT finish the pointer when the dispose fails")

# other blockers remain → the door refuses: the dispose STANDS, nothing is applied, the receipt NAMES
# the remainder, and the finisher exits NONZERO (a silent success would hide a pointer left Blocked).
rc, merges, trans = req({"gate_body": MARK % 12, "other_blockers": [999]})
check(rc != 0, f"a pointer held by other blockers must exit NONZERO, got {rc}")
check([t[0] for t in trans] == ["dispose"], f"the dispose must STAND and never be rolled back, got {trans}")
check(st["finish_calls"] == [False], f"the door must be read but never applied, got {st['finish_calls']}")
check(st["receipt"] and st["receipt"].get("remaining_blockers") == [999],
      f"the receipt must NAME the remaining blockers, got {st.get('receipt')}")
check(st["receipt"] and st["receipt"].get("unblock") == "refused",
      f"the receipt must report the unblock refused, got {st.get('receipt')}")
check(st["receipt"] and st["receipt"].get("tracker_mutation") == "dispose(gate-approved)",
      f"the receipt must not claim an unblock that never happened, got {st.get('receipt')}")
print("  ok requirements refuses a pointer held by OTHER blockers — dispose stands, receipt names them, exit nonzero")

# open + --operator-approved → merges the bound PR, re-verifies MERGED, then the same tail.
rc, merges, trans = req({"gate_body": MARK % 12,
                         "pr": {"state": "OPEN", "mergeable": "MERGEABLE", "mergedAt": None}},
                        ("--operator-approved",))
check(rc == 0, f"requirements open+approved should exit 0, got {rc}")
check(merges == [12], f"open+approved must merge the bound PR, merged={merges}")
check([t[0] for t in trans] == ["dispose"], f"open+approved's only engine op must be the dispose, got {trans}")
check(st["finish_calls"] == [False, True],
      f"open+approved must finish the pointer through the door, got {st['finish_calls']}")
print("  ok requirements (open + operator-approved) merges then disposes-before-finishing the pointer")

if fails:
    print("FAIL:")
    for m in fails:
        print("   -", m)
    sys.exit(1)
PY

# ── the requirements tail holds the SOLE-BLOCKER invariant (Task 7 wave 2b) ────────────────────────
# The stubbed unit above proves the tail's ORDER; this proves what the tail actually does to a REAL
# board. The finisher's `requirements` mode is the mechanized tail idc:idc-gate-issue's step 4
# RECOMMENDS, so it must hold the same invariant as the guarded pointer-finish door: the engine's
# `unblock --by` drops only the NAMED edge before setting Todo, so a dependent Blocked by
# `[gate, other]` sails past `other` WITHOUT `other`'s proof — and Autorun treats an unblocked
# Consideration pointer as approved work. The tail therefore routes its unblock through
# `idc_gate_repair.py --finish-pointer --apply`, which re-reads the gate's on-disk proof AND refuses
# unless the proven gate is the pointer's SOLE remaining blocker.
#
# Real engine, real TRACKER.md, real journal — only `gh` is stubbed (the Think PR + the gate's bound
# marker are github artifacts the filesystem backend has no way to carry). So the dispose really
# lands, the door really reads the proof it left, and the assertions below are board+journal truth.
#
# Red-when-broken: restore the raw `_transition(["unblock", …])` in the tail → case (B) frees the
# pointer past #999 and exits 0 → FAIL.
T="$(gov_new_tracker)" || gov_fail "could not mint the fs tracker"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
mkdir -p "$REPO/docs/workflow"
JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"
PR=12

# The driver: the REAL finisher (real engine tail, real door) with only the `gh` seam faked to report
# the bound Think PR MERGED. Exits with the finisher's own status.
DRIVER="$REPO/drive_finish.py"
cat > "$DRIVER" <<'PY'
import json, sys
scripts, repo, tracker, pr, gate, pointer = sys.argv[1:7]
sys.path.insert(0, scripts)
import idc_pr_finish as F

def fake_gh(args, _repo):
    a = list(args)
    if a[:2] == ["pr", "view"]:
        return json.dumps({"state": "MERGED", "mergeable": "MERGEABLE",
                           "mergedAt": "2026-01-01T00:00:00Z"})
    if a[:2] == ["issue", "view"]:
        return json.dumps({"body": "<!-- idc-gate-pr: %d -->" % int(pr)})
    raise AssertionError("unexpected gh call reached the stub: %r" % (a,))

F._gh = fake_gh
sys.exit(F.main(["requirements", "--repo", repo, "--backend", "filesystem", "--tracker", tracker,
                 "--pr", pr, "--gate", gate, "--pointer", pointer]))
PY
fin() { python3 "$DRIVER" "$GOV_PLUGIN/scripts" "$REPO" "$T" "$PR" "$1" "$2" 2>&1; }

# `op=unblock` records naming an item — the proof that a transition really was (or never was) minted.
unblocked_in_journal() {
  python3 - "$GOV_PLUGIN/scripts" "$JOURNAL" "$1" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import idc_journal_replay as JR
path, num = sys.argv[2], int(sys.argv[3])
n = 0
if os.path.exists(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("op") == "unblock" and JR.journal_item_id(e) == num:
            n += 1
print(n)
PY
}

# (A) GREEN PATH PRESERVED: the gate is the pointer's SOLE blocker → the tail converges to Todo.
GATE_A="$(gov_seed_item "$T" --title '[operator-action] Requirements change — gate A' --stage Buildable --status Todo)" \
  || gov_fail "could not seed gate A"
DEP_A="$(gov_seed_item "$T" --title 'consideration pointer A' --stage Consideration --status Blocked \
  --blocked-by "$GATE_A")" || gov_fail "could not seed dependent A"
OUT="$(fin "$GATE_A" "$DEP_A")"; RC=$?
[ $RC -eq 0 ] || gov_fail "(A) the sole-blocker green path regressed — the finisher exited $RC: $OUT"
[ "$(gov_field "$T" "$GATE_A" Status)" = "Done" ] || gov_fail "(A) the guarded dispose did not mint the gate's Done: $OUT"
[ "$(gov_field "$T" "$DEP_A" Status)" = "Todo" ] || gov_fail "(A) the sole-blocked pointer was not finished: $OUT"
[ "$(unblocked_in_journal "$DEP_A")" = "1" ] || gov_fail "(A) the engine's real unblock was not journaled for #$DEP_A"
echo "  ok (A) requirements on a SOLE-blocker pointer still disposes then finishes it to Todo (green path preserved)"

# (B) THE INVARIANT: another blocker remains → the dispose STANDS, the door REFUSES, the finisher
#     exits nonzero NAMING the remainder, and the pointer is left Blocked with nothing journaled.
GATE_B="$(gov_seed_item "$T" --title '[operator-action] Requirements change — gate B' --stage Buildable --status Todo)" \
  || gov_fail "could not seed gate B"
DEP_B="$(gov_seed_item "$T" --title 'consideration pointer B' --stage Consideration --status Blocked \
  --blocked-by "$GATE_B,999")" || gov_fail "could not seed dependent B"
OUT="$(fin "$GATE_B" "$DEP_B")"; RC=$?
[ $RC -ne 0 ] \
  || gov_fail "(B) the finisher freed #$DEP_B past blocker #999 without its proof and reported success: $OUT"
echo "$OUT" | grep -q '999' || gov_fail "(B) the finisher's output does not NAME the remaining blocker #999: $OUT"
[ "$(gov_field "$T" "$DEP_B" Status)" = "Blocked" ] \
  || gov_fail "(B) the pointer left Blocked-behind-#999 was moved anyway: $OUT"
[ "$(unblocked_in_journal "$DEP_B")" = "0" ] \
  || gov_fail "(B) an op=unblock was journaled for #$DEP_B while #999 still blocks it"
# the dispose is honest work that really happened — it must never be rolled back to hide the refusal.
[ "$(gov_field "$T" "$GATE_B" Status)" = "Done" ] \
  || gov_fail "(B) the guarded dispose did not stand — the gate's approval was verified, so its Done is real: $OUT"
echo "  ok (B) requirements REFUSES to finish a pointer past its other blockers — dispose stands, exit nonzero, #999 named, nothing journaled"

# (C) RERUN CONVERGES: once #999 is resolved through its own door, the same command finishes the job.
python3 "$GOV_TRK" --tracker "$T" unlink --parent 999 --child "$DEP_B" --kind blocks >/dev/null \
  || gov_fail "could not resolve the second blocker"
OUT="$(fin "$GATE_B" "$DEP_B")"; RC=$?
[ $RC -eq 0 ] || gov_fail "(C) the rerun did not converge once the gate was the sole blocker: $OUT"
[ "$(gov_field "$T" "$DEP_B" Status)" = "Todo" ] || gov_fail "(C) the rerun did not finish the pointer: $OUT"
[ "$(unblocked_in_journal "$DEP_B")" = "1" ] || gov_fail "(C) the rerun did not journal the engine's real unblock"
echo "  ok (C) rerunning after the other blocker resolves converges — the pointer finishes through the engine"

echo "PASS: the PR finisher enforces its safety contract — prefix gating, merge re-read, tracker-immutability (autonomous), marker validation, no-infer-approval, dispose-before-unblock, and the SOLE-BLOCKER invariant on the requirements tail (a pointer held by other blockers stays Blocked; the dispose stands and the finisher exits nonzero naming them)"
