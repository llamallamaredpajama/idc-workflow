#!/bin/bash
# idc-assert-class: behavior
# finish-close-door-provenance.sh — the finisher's TWO sanctioned close doors must stay
# DISTINGUISHABLE in the canonical transition journal (#159).
#
# `idc_git_finish.py` closes an item through two doors: the normal VERDICT-GUARDED finish
# (merge + tracker close, receipt = the validated review verdict) and the `--close-only`
# RECOVERY door (already-merged PR whose board never advanced, receipt = the proven MERGED
# state). Both journal op="close" from the same tracker_close — and before #159 the recovery
# record was a byte-level LOOK-ALIKE of the verdict close: a merged-state recovery could never
# again be told apart from a guarded close in the audit trail, the exact provenance-laundering
# shape the janitor's `janitor-repair` attribution exists to prevent.
#
# The contract under test:
#   * the verdict-door close record carries NO `door` marker and NO `evidence` field;
#   * the recovery-door close record carries `door: "close-only-recovery"` plus its merged-state
#     evidence (`evidence.pr` + `evidence.pr_state: "MERGED"`);
#   * BOTH records keep op="close" — replay reconstruction keys on the op + structured item/to
#     fields, so no journal consumer needs to learn a new op name.
#
# RED-WHEN-BROKEN, PROVEN: revert tracker_close's `recovery_evidence` stamping (journal the
# recovery close as a bare op="close" entry, the pre-#159 shape) → B2 FAILs: "the recovery close
# record must carry door=close-only-recovery". Probe: git stash the scripts/idc_git_finish.py fix,
# run this lane, observe the B2 FAIL line, git stash pop.
#
# Hermetic REAL git (the phase4 finisher rig): a bare origin, a real clone + worktree, real merges.
# Only `gh pr view` / `gh pr merge` are stubbed on PATH. One repo runs BOTH doors back to back —
# a normal finish, then the idempotent `--close-only` re-run on the same already-finished item
# (the exact post-finish state a recovery pass sees) — so the differential is asserted on two
# records in the SAME journal.
#
# Usage: bash tests/smoke/governance/finish-close-door-provenance.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FINISH="$PLUGIN/scripts/idc_git_finish.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
VAL="$PLUGIN/scripts/idc_validation_contract.py"
BREC="$PLUGIN/scripts/idc_build_receipt.py"
GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

for f in "$FINISH" "$TRK" "$CHECK" "$VAL" "$BREC"; do
  [ -f "$f" ] || fail "missing helper: $f"
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# gh stub (the phase4-mid-finish-recovery rig, minus the kill switches): `pr view --json
# headRefName|state|baseRefName`, and `pr merge --squash --delete-branch` performing a REAL merge
# of the head branch into base + push + origin branch delete, so every downstream git check
# observes real git state.
# ---------------------------------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
STATE_FILE = os.path.join(os.environ["WORK"], "gh-pr-merged")
BRANCH, ORIGIN, REPO, BASE = (os.environ["BRANCH"], os.environ["ORIGIN"],
                              os.environ["REPO"], os.environ.get("BASE", "main"))

if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    if j == "headRefName":
        print(BRANCH)
    elif j == "state":
        print("MERGED" if os.path.exists(STATE_FILE) else "OPEN")
    elif j == "baseRefName":
        print(BASE)
    sys.exit(0)

if args[:2] == ["pr", "merge"]:
    if "--squash" not in args or "--delete-branch" not in args:
        sys.stderr.write("gh stub: pr merge missing --squash/--delete-branch\n")
        sys.exit(1)
    subprocess.run(["git", "-C", REPO, "checkout", "-q", BASE], capture_output=True)
    subprocess.run(["git", "-C", REPO, "merge", "-q", "--no-ff", "-m", "merge " + BRANCH, BRANCH],
                   capture_output=True)
    subprocess.run(["git", "-C", REPO, "push", "-q", "origin", BASE], capture_output=True)
    subprocess.run(["git", "-C", ORIGIN, "branch", "-D", BRANCH], capture_output=True)
    open(STATE_FILE, "w").close()
    sys.exit(0)

sys.stderr.write("gh stub: unhandled " + repr(args) + "\n")
sys.exit(99)
STUB
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------------------------
# Repo rig: bare origin + clone + a real worktree on `worktree-build-1` with a pushed commit, a
# governed filesystem tracker with issue #1 In Progress, and the full verdict + build-receipt
# fixture the NORMAL finish door requires.
# ---------------------------------------------------------------------------------------------
ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; BRANCH="worktree-build-1"
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/docs/workflow/build-validation" \
         "$REPO/docs/workflow/build-validation-executions" \
         "$REPO/docs/workflow/build-receipts" \
         "$REPO/docs/workflow/code-reviews"
echo hello > "$REPO/README.md"
cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'green' change.txt
SH
chmod +x "$REPO/verify.sh"
git -C "$REPO" add README.md verify.sh
git -C "$REPO" commit -qm init
BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" push -q origin "HEAD:$BASE"

WT="$REPO/.claude/worktrees/$BRANCH"
git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE"

printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
TRACKER="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$TRACKER" init >/dev/null
python3 "$TRK" --tracker "$TRACKER" create --title "Test issue" >/dev/null
python3 "$TRK" --tracker "$TRACKER" claim --num 1 --agent tester >/dev/null

CONTRACT="$REPO/docs/workflow/build-validation/${BRANCH}.json"
EXECUTION="$REPO/docs/workflow/build-validation-executions/${BRANCH}.json"
BUILD_RECEIPT="$REPO/docs/workflow/build-receipts/${BRANCH}.json"

echo change > "$WT/change.txt"
git -C "$WT" add change.txt
git -C "$WT" commit -qm work
git -C "$WT" push -q origin "$BRANCH"

python3 "$VAL" freeze \
  --surface cli --repo "$WT" --issue 1 --pr 501 \
  --graph-node test-issue --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch change.txt --off-limits README.md --verify 'bash verify.sh' \
  --baseline expected-red --label "$BRANCH" --out "$CONTRACT" >/dev/null \
  || fail "could not freeze the build validation contract for $BRANCH"

echo green > "$WT/change.txt"
git -C "$WT" add change.txt
git -C "$WT" commit -qm "green"
git -C "$WT" push -q origin "$BRANCH"

python3 "$VAL" run --repo "$WT" --contract "$CONTRACT" --out "$EXECUTION" >/dev/null \
  || fail "could not execute the frozen validation gate for $BRANCH"
VERDICT="$REPO/docs/workflow/code-reviews/2026-08-02-pr-501-review.json"
python3 - "$EXECUTION" "$VERDICT" <<'PY' || fail "could not write the PASS verdict"
import json, sys
execution_path, verdict_path = sys.argv[1:3]
execution = json.load(open(execution_path, encoding='utf-8'))
verdict = {
    'verdict': 'PASS',
    'pr': 501,
    'issue': 1,
    'head': execution['head'],
    'diff_digest': execution['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
python3 "$CHECK" "$VERDICT" >/dev/null 2>&1 || fail "validator did not accept the clean finish verdict"
python3 "$BREC" write \
  --repo "$WT" --contract "$CONTRACT" --execution "$EXECUTION" --verdict "$VERDICT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$BUILD_RECEIPT" >/dev/null \
  || fail "could not write the implementation receipt for $BRANCH"

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

# assert_close_records <expected-count> — read every op="close" record for item 1 from the journal
# and assert the door differential (bound: the journal is a small local file). With 1 expected
# record only the verdict-door shape is asserted; with 2, the recovery-door shape + the
# differential too. Prints the offending record on failure. No eval — fixed named assertions.
assert_close_records() {
  python3 - "$JOURNAL" "$1" <<'PY'
import json, sys
path, expected = sys.argv[1], int(sys.argv[2])
recs = []
try:
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("op") == "close" and r.get("item") == 1:
            recs.append(r)
except OSError as e:
    print(f"FAIL: journal unreadable: {e}")
    sys.exit(1)

def bail(msg, rec):
    print("FAIL: " + msg)
    print("RECORD: " + json.dumps(rec, sort_keys=True))
    sys.exit(1)

if len(recs) != expected:
    print(f"FAIL: expected {expected} op=close record(s) for item 1, found {len(recs)}")
    sys.exit(1)

# A. the VERDICT-GUARDED door's record: attributed, verdict-hashed, UNMARKED.
v = recs[0]
if v.get("who") != "finisher":
    bail("the verdict-door close must be attributed who=finisher", v)
if not v.get("guard_evidence_hash"):
    bail("the verdict-door close must carry the verdict's guard_evidence_hash "
         "(positive control: the journal machinery attributes this door)", v)
if "door" in v or "evidence" in v:
    bail("the verdict-door close record must carry NO door marker and NO evidence field "
         "(the differential: only the recovery door is marked)", v)

if expected == 2:
    # B. the RECOVERY door's record: SAME op (replay reconstruction keys on it), but marked with
    # its own door + the merged-state evidence that authorized it (#159).
    r = recs[1]
    if r.get("op") != "close":
        bail("the recovery close must STAY op=close — a renamed op would vanish from every "
             "journal consumer's reconstruction", r)
    if r.get("door") != "close-only-recovery":
        bail("the recovery close record must carry door=close-only-recovery — without it a "
             "merged-state recovery is indistinguishable from the verdict-guarded close door "
             "in the audit trail (#159)", r)
    ev = r.get("evidence")
    if not (isinstance(ev, dict) and ev.get("pr") == 501 and ev.get("pr_state") == "MERGED"):
        bail("the recovery close record must carry its merged-state evidence "
             "(evidence.pr=501, evidence.pr_state=MERGED) — the recovery's receipt is the "
             "proven merged PR, not a verdict", r)
print("ok")
PY
}

# ============ A. the VERDICT-GUARDED door: a normal finish journals an UNMARKED close ============
out="$( cd "$REPO" && env PATH="$BIN:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" REPO="$REPO" \
    BRANCH="$BRANCH" BASE="$BASE" \
    timeout 120 python3 "$FINISH" --pr 501 --issue 1 --worktree "$WT" --repo "$REPO" \
      --tracker "$TRACKER" --verdict "$VERDICT" --build-receipt "$BUILD_RECEIPT" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] || fail "A: the normal finish must succeed (rc=$rc): $out"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "A: item #1 must be Done after the normal finish"
out="$(assert_close_records 1)" || fail "A: verdict-door journal record — $out"
echo "  ok A verdict door: one op=close record, attributed + verdict-hashed + unmarked"

# ============ B. the RECOVERY door: --close-only journals a MARKED close on the SAME journal ======
# The idempotent --close-only re-run on the just-finished item is exactly the state a recovery pass
# sees (PR MERGED, branches gone, board Done) — phase4-git-finish Scenario C proves the re-run
# contract; here it produces the SECOND close record for the differential.
out="$( cd "$REPO" && env PATH="$BIN:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" REPO="$REPO" \
    BRANCH="$BRANCH" BASE="$BASE" \
    timeout 120 python3 "$FINISH" --pr 501 --issue 1 --worktree "$WT" --repo "$REPO" \
      --tracker "$TRACKER" --close-only 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] || fail "B: --close-only on the merged item must succeed (rc=$rc): $out"
out="$(assert_close_records 2)" || fail "B: close-door differential — $out"
echo "  ok B recovery door: op=close + door=close-only-recovery + merged-state evidence; verdict record still unmarked"

echo "PASS: finish-close-door-provenance"
exit 0
