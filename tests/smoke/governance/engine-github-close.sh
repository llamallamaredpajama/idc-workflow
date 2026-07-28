#!/bin/bash
# engine-github-close.sh — governance scenario: the github `close` op enforces THE terminal invariant
# identically to fs — only a valid + PASSING + item-owning + pr-bound verdict reaches Done, via the
# shared check_close_guards; the atomic gh close (idc_gh_close.close_issue) runs ONLY after guards pass.
#
# In-process unit (github isn't hermetic): idc_gh_close.close_issue + idc_gh_board.fetch_item and the
# item-id cache are monkeypatched; assertions are on whether close_issue is called. Red-when-broken:
# neuter the ownership / disposition / mandatory-pr checks in check_close_guards → a bad close calls
# close_issue → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-close.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" config user.email test@example.com >/dev/null 2>&1
git -C "$REPO" config user.name Test >/dev/null 2>&1
mkdir -p "$REPO/docs/workflow/code-reviews"

python3 - "$GOV_PLUGIN/scripts" "$REPO" "$CHECK" <<'PY' || fail "github close unit failed (see above)"
import sys, os, json, subprocess
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
check = sys.argv[3]
import idc_transition as E, idc_gh_board as B, idc_gh_close as GC

B.fetch_item = lambda iid, r: {"stage": "Buildable", "status": "In Progress"}  # existence read
closed = []
GC.close_issue = lambda o, p, i, r, item_id=None: closed.append(i)
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

def w(name, doc):
    path = os.path.join(repo, "docs", "workflow", "code-reviews", name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh)
    subprocess.run([sys.executable, check, path], check=True, capture_output=True, text=True)
    return path

owning = w("2026-07-22-pr-9-own.json", {"verdict": "PASS", "pr": 9, "issue": 5, "findings": []})
other  = w("2026-07-22-pr-9-other.json", {"verdict": "PASS", "pr": 9, "issue": 888, "findings": []})
failv  = w("2026-07-22-pr-9-fail.json", {"verdict": "FAIL", "pr": 9, "issue": 5,
           "findings": [{"dimension": "correctness", "severity": "major", "confidence": 0.95,
                         "evidence": "e", "attack": "a", "unblock": "u", "fingerprint": "fp"}]})
# NO `pr` field — so the mandatory-`--pr` guard is the SOLE thing denying case (4). (With a verdict
# that carries pr:9, the separate verdict.pr!=pr check masks the mandatory-pr guard, and neutering
# it leaves case (4) green — the test would prove less than it claims. See PR #134 review NIT-1.)
nopr   = w("2026-07-22-no-pr.json", {"verdict": "PASS", "issue": 5, "findings": []})

def is_denied(fn):
    try: fn(); return False
    except E.TransitionError: return True

# (1) owning + passing + pr-bound → the atomic gh close IS performed.
closed.clear()
E.run("close", ctx, num=5, verdict=owning, pr=9)
assert closed == [5], f"legal github close did not call close_issue once: {closed}"
print("  ok (1) a valid+passing+owning+pr-bound verdict performs the gh close")

# (2) verdict for another item (issue!=num) → DENIED; close_issue NOT called.
closed.clear()
assert is_denied(lambda: E.run("close", ctx, num=5, verdict=other, pr=9)), "cross-item github close allowed"
assert closed == [], f"denied cross-item close still called close_issue: {closed}"
print("  ok (2) a non-owning verdict is DENIED and performs no gh close")

# (3) FAIL verdict → DENIED; no gh close.
closed.clear()
assert is_denied(lambda: E.run("close", ctx, num=5, verdict=failv, pr=9)), "FAIL-verdict github close allowed"
assert closed == [], f"denied FAIL close still called close_issue: {closed}"
print("  ok (3) a FAIL verdict is DENIED and performs no gh close")

# (4) no --pr AND a verdict with no pr field → DENIED by the mandatory-pr guard alone; no gh close.
closed.clear()
assert is_denied(lambda: E.run("close", ctx, num=5, verdict=nopr, pr=None)), "unbound (no --pr, no verdict.pr) github close allowed"
assert closed == [], f"denied no-pr close still called close_issue: {closed}"
print("  ok (4) a close with no --pr (and no verdict.pr) is DENIED and performs no gh close")
PY

echo "PASS: github close reaches Done only via a valid+passing+item-owning+pr-bound verdict; non-owning/FAIL/unbound are denied with no gh close"
