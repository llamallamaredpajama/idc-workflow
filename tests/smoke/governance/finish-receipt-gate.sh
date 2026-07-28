#!/bin/bash
# finish-receipt-gate.sh — governance scenario: idc_git_finish.py is a P5 RECEIPT GATE.
#
# The invariant (v4 Phase 2, plan §3.3): the finish tail is the SECOND write door that closes an item
# (the transition engine's guarded `close` is the first), so it enforces the SAME receipt invariant —
# it REFUSES to merge/close unless the review verdict for THIS PR/issue validates, is passing, owns
# the item, has every routable finding (each minor/nit + every deferral) already ROUTED to the board
# by the filer, and has NO unmet merge_conditions[]. Enforcement is ON BY DEFAULT (no --verdict ⇒
# refuse; `--no-require-routed-findings` is a debug-only escape for the routed sub-check). The gate
# runs BEFORE any mutation, so in this non-git sandbox a PROCEEDING finish fails at the FIRST git step
# (`resolve-branch`) — that later failure is the proof the gate let it through.
#
# Red-when-broken: neuter idc_git_finish.enforce_receipt_gate (make it a no-op) → the (U)/(C)/(M)/(O)
# refuse-cases and the github (G) fail-closed case all stop refusing → this scenario FAILs.
#
#   (U) unrouted nit ⇒ REFUSE, naming the filer remediation  [THE headline negative]
#   (R) route it via the filer ⇒ the same verdict PROCEEDS
#   (C) unmet merge_condition ⇒ REFUSE
#   (P) clean, routed, condition-met receipt ⇒ PROCEEDS
#   (E) --no-require-routed-findings ⇒ skips ONLY the routed sub-check (escape hatch)
#   (M) no --verdict ⇒ REFUSE (receipt gate; no call site can silently skip)
#   (O) a verdict for a different PR ⇒ REFUSE (the receipt must own the item)
#   (B) omitting --build-receipt on a normal finish ⇒ REFUSE before any irreversible finish step
#   (G) github: an unreadable board ⇒ fail CLOSED (never merge on an unverifiable routing state)
#
# Usage: bash tests/smoke/governance/finish-receipt-gate.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

FIN="$GOV_PLUGIN/scripts/idc_git_finish.py"
FILER="$GOV_PLUGIN/scripts/idc_file_findings.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
[ -f "$FIN" ] || gov_fail "idc_git_finish.py not found at $FIN (not implemented yet)"

WORK="$(mktemp -d)"
WORK2=""
trap 'rm -rf "$WORK" "$WORK2"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow/code-reviews"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" config user.email test@example.com >/dev/null 2>&1
git -C "$REPO" config user.name Test >/dev/null 2>&1
T="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$T" init >/dev/null || gov_fail "tracker init failed"
PARENT="$(python3 "$TRK" --tracker "$T" create --title 'build: feature' --stage Buildable --status 'In Progress')" \
  || gov_fail "seed of the parent build issue failed"

# The finish tail's git steps fail in this non-git sandbox — every assertion is on the receipt gate,
# which runs first. `--worktree` is a placeholder (never reached: the gate or resolve-branch fires first).
fin() { ( cd "$REPO" && python3 "$FIN" --repo "$REPO" --tracker "$T" --worktree "$REPO/nowt" "$@" 2>&1 ); }

PROCEEDED='finish: resolve-branch failed'   # the first git step past the gate → proof the gate passed

make_gh_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
STATE_FILE = os.path.join(os.environ["WORK2"], "gh-pr-merged")
BRANCH = os.environ["BRANCH2"]
ORIGIN = os.environ["ORIGIN2"]
BASE = os.environ.get("BASE2", "main")

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
    open(STATE_FILE, "w").close()
    subprocess.run(["git", "-C", ORIGIN, "branch", "-D", BRANCH], capture_output=True)
    sys.exit(0)

sys.stderr.write("gh stub: unhandled " + repr(args) + "\n")
sys.exit(99)
STUB
  chmod +x "$bindir/gh"
}

setup_finish_repo() {
  local work="$1"
  ORIGIN2="$work/origin.git"
  REPO2="$work/repo"
  BRANCH2='worktree-build-1'
  git init -q --bare "$ORIGIN2"
  git clone -q "$ORIGIN2" "$REPO2"
  git -C "$REPO2" config user.email t@example.com
  git -C "$REPO2" config user.name tester
  mkdir -p "$REPO2/docs/workflow/code-reviews"
  printf 'backend: filesystem\n' > "$REPO2/docs/workflow/tracker-config.yaml"
  printf '# seed\n' > "$REPO2/README.md"
  git -C "$REPO2" add README.md docs/workflow/tracker-config.yaml
  git -C "$REPO2" commit -qm init
  BASE2="$(git -C "$REPO2" symbolic-ref --short HEAD)"
  git -C "$REPO2" push -q origin "HEAD:$BASE2"

  WT2="$REPO2/.claude/worktrees/$BRANCH2"
  git -C "$REPO2" worktree add -q -b "$BRANCH2" "$WT2" "$BASE2"
  printf 'real finish branch\n' > "$WT2/change.txt"
  git -C "$WT2" add change.txt
  git -C "$WT2" commit -qm branch
  git -C "$WT2" push -q origin "$BRANCH2"

  TRACKER2="$REPO2/TRACKER.md"
  python3 "$TRK" --tracker "$TRACKER2" init >/dev/null || gov_fail "(B) tracker init failed"
  ISSUE2="$(python3 "$TRK" --tracker "$TRACKER2" create --title 'build: receipt gate' --stage Buildable --status 'In Progress')" \
    || gov_fail "(B) build issue seed failed"

  VERDICT2="$REPO2/docs/workflow/code-reviews/2026-07-23-pr-501-clean.json"
  cat > "$VERDICT2" <<JSON
{"verdict":"PASS","pr":501,"issue":$ISSUE2,"findings":[]}
JSON
  python3 "$CHECK" "$VERDICT2" >/dev/null 2>&1 || gov_fail "(B) clean verdict did not validate"
}

# ── (U) unrouted nit ⇒ REFUSE (headline) ─────────────────────────────────────────────────────────
V_NIT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-77-nit.json"
cat > "$V_NIT" <<JSON
{"verdict":"PASS-WITH-NITS","pr":77,"issue":$PARENT,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"magic 7","attack":"a","unblock":"name it","fingerprint":"style:f.py:7:magic"}]}
JSON
python3 "$CHECK" "$V_NIT" >/dev/null 2>&1 || gov_fail "(U) verdict did not validate"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_NIT")"; rc=$?
[ "$rc" -ne 0 ] || gov_fail "(U) finish did NOT refuse while a review nit was unrouted"
printf '%s\n' "$out" | grep -q 'finish: require-routed-findings failed' \
  || gov_fail "(U) refusal not attributed to require-routed-findings: $out"
printf '%s\n' "$out" | grep -qi 'idc_file_findings' \
  || gov_fail "(U) refusal did not name the filer remediation: $out"
echo "  ok (U) unrouted finding ⇒ finish REFUSES, naming the filer remediation [headline]"

# ── (R) route it with the filer ⇒ the SAME verdict now PROCEEDS ───────────────────────────────────
python3 "$FILER" --repo "$REPO" --verdict "$V_NIT" >/dev/null || gov_fail "(R) filer run failed"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_NIT")"
printf '%s\n' "$out" | grep -q 'require-routed-findings failed' \
  && gov_fail "(R) still refused after the finding was routed to the board: $out"
printf '%s\n' "$out" | grep -qF "$PROCEEDED" \
  || gov_fail "(R) did not proceed past the gate after routing: $out"
echo "  ok (R) once the filer routes the finding, the gate PROCEEDS"

# ── (C) unmet merge_condition ⇒ REFUSE (routing clean: no findings) ───────────────────────────────
V_COND="$REPO/docs/workflow/code-reviews/2026-07-22-pr-77-cond.json"
cat > "$V_COND" <<JSON
{"verdict":"PASS","pr":77,"issue":$PARENT,"findings":[],
 "merge_conditions":[{"id":"ci-green","description":"CI must be green before merge","met":false}]}
JSON
python3 "$CHECK" "$V_COND" >/dev/null 2>&1 || gov_fail "(C) verdict did not validate"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_COND")"; rc=$?
[ "$rc" -ne 0 ] || gov_fail "(C) finish did NOT refuse while a merge_condition was unmet"
printf '%s\n' "$out" | grep -q 'finish: merge-conditions-met failed' \
  || gov_fail "(C) refusal not attributed to merge-conditions-met: $out"
echo "  ok (C) unmet merge_condition ⇒ finish REFUSES"

# ── (P) clean, routed, condition-met receipt ⇒ PROCEEDS ───────────────────────────────────────────
V_CLEAN="$REPO/docs/workflow/code-reviews/2026-07-22-pr-77-clean.json"
cat > "$V_CLEAN" <<JSON
{"verdict":"PASS","pr":77,"issue":$PARENT,"findings":[]}
JSON
python3 "$CHECK" "$V_CLEAN" >/dev/null 2>&1 || gov_fail "(P) verdict did not validate"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_CLEAN")"
printf '%s\n' "$out" | grep -qE 'finish: (require-routed-findings|merge-conditions-met|verdict) failed' \
  && gov_fail "(P) a clean receipt was wrongly refused by the gate: $out"
printf '%s\n' "$out" | grep -qF "$PROCEEDED" \
  || gov_fail "(P) a clean receipt did not proceed past the gate to the git tail: $out"
echo "  ok (P) a clean, routed, condition-met receipt PROCEEDS past the gate"

# ── (E) --no-require-routed-findings skips ONLY the routed sub-check ───────────────────────────────
V_NIT2="$REPO/docs/workflow/code-reviews/2026-07-22-pr-77-nit2.json"
cat > "$V_NIT2" <<JSON
{"verdict":"PASS-WITH-NITS","pr":77,"issue":$PARENT,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"unrouted","attack":"a","unblock":"u","fingerprint":"style:z.py:1:unrouted"}]}
JSON
python3 "$CHECK" "$V_NIT2" >/dev/null 2>&1 || gov_fail "(E) verdict did not validate"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_NIT2")"
printf '%s\n' "$out" | grep -q 'finish: require-routed-findings failed' \
  || gov_fail "(E-pre) an unrouted nit must refuse by DEFAULT: $out"
out="$(fin --pr 77 --issue "$PARENT" --verdict "$V_NIT2" --no-require-routed-findings)"
printf '%s\n' "$out" | grep -q 'require-routed-findings failed' \
  && gov_fail "(E) --no-require-routed-findings did not skip the routed check: $out"
printf '%s\n' "$out" | grep -qF "$PROCEEDED" \
  || gov_fail "(E) escape hatch did not proceed past the gate: $out"
echo "  ok (E) --no-require-routed-findings skips the routed sub-check (debug escape hatch)"

# ── (M) no --verdict ⇒ REFUSE (receipt gate; no silent skip) ──────────────────────────────────────
out="$(fin --pr 77 --issue "$PARENT")"; rc=$?
[ "$rc" -ne 0 ] || gov_fail "(M) finish did NOT refuse with no --verdict receipt"
printf '%s\n' "$out" | grep -q 'finish: verdict failed' \
  || gov_fail "(M) a missing verdict was not refused at the verdict step: $out"
echo "  ok (M) no --verdict ⇒ finish REFUSES (receipt gate; no call site can silently skip)"

# ── (O) a verdict for a DIFFERENT PR ⇒ REFUSE (ownership) ─────────────────────────────────────────
out="$(fin --pr 999 --issue "$PARENT" --verdict "$V_CLEAN")"; rc=$?
[ "$rc" -ne 0 ] || gov_fail "(O) finish accepted a verdict bound to a different PR"
printf '%s\n' "$out" | grep -q 'finish: verdict failed' \
  || gov_fail "(O) a wrong-PR verdict was not refused: $out"
echo "  ok (O) a verdict for a different PR ⇒ finish REFUSES (the receipt must own the item)"

# ── (G) github: an unreadable board ⇒ fail CLOSED ─────────────────────────────────────────────────
# In-process (no live GitHub): monkeypatch the board reader to raise, then prove BOTH the routing
# helper's fail-closed signal AND the CLI gate's refusal (never merges on an unverifiable board).
V_GH="$REPO/docs/workflow/code-reviews/2026-07-22-pr-77-gh.json"
cat > "$V_GH" <<JSON
{"verdict":"PASS-WITH-NITS","pr":77,"issue":1,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,
               "evidence":"e","attack":"a","unblock":"u","fingerprint":"gh:fp"}]}
JSON
python3 "$CHECK" "$V_GH" >/dev/null 2>&1 || gov_fail "(G) github verdict did not validate"
python3 - "$GOV_PLUGIN/scripts" "$REPO" "$V_GH" <<'PY' || gov_fail "(G) github fail-closed unit failed (see assertion above)"
import sys, argparse, io, contextlib
sys.path.insert(0, sys.argv[1])
repo, vf = sys.argv[2], sys.argv[3]
import idc_gh_board as B
import idc_git_finish as G

VERDICT = {"verdict": "PASS-WITH-NITS", "pr": 77, "issue": 1,
           "findings": [{"dimension": "style", "severity": "nit", "confidence": 0.9,
                         "evidence": "e", "attack": "a", "unblock": "u", "fingerprint": "gh:fp"}]}

def boom(*a, **k):
    raise B.BoardReadError("simulated board read failure")

orig = B.fetch_items
B.fetch_items = boom
try:
    # (G1) the routing helper propagates BoardReadError (never a silent empty routed-set).
    try:
        G.routing_gap(VERDICT, "github", repo, None, "owner", "1")
    except B.BoardReadError:
        print("  ok (G1) github: unreadable board → routing_gap raises BoardReadError (fail-closed)")
    else:
        print("FAIL: (G1) routing_gap did not raise on an unreadable board"); sys.exit(1)

    # (G2) the CLI gate turns that into a REFUSAL (exit non-zero, attributed to require-routed-findings).
    args = argparse.Namespace(verdict=vf, issue=1, pr=77, require_routed=True)
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            G.enforce_receipt_gate(args, "github", repo, None, "owner", "1")
    except SystemExit as e:
        assert e.code and e.code != 0, f"gate exit was {e.code!r} (expected non-zero)"
    else:
        print("FAIL: (G2) enforce_receipt_gate did not refuse on an unreadable board"); sys.exit(1)
    assert "require-routed-findings" in err.getvalue(), err.getvalue()
    print("  ok (G2) github: unreadable board → enforce_receipt_gate REFUSES (never merges blind)")
finally:
    B.fetch_items = orig
PY

# ── (B) omitting --build-receipt on a real finish ⇒ REFUSE before any irreversible step ─────────────
WORK2="$(mktemp -d)"
setup_finish_repo "$WORK2"
make_gh_stub "$WORK2/bin"
set +e
out="$(cd "$REPO2" && PATH="$WORK2/bin:$PATH" WORK2="$WORK2" ORIGIN2="$ORIGIN2" BRANCH2="$BRANCH2" BASE2="$BASE2" \
  python3 "$FIN" --repo "$REPO2" --tracker "$TRACKER2" --worktree "$WT2" --pr 501 --issue "$ISSUE2" --verdict "$VERDICT2" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || gov_fail "(B) finish accepted a clean verdict while omitting --build-receipt"
printf '%s\n' "$out" | grep -q 'finish: build-receipt failed' \
  || gov_fail "(B) missing --build-receipt refusal was not attributed to the build-receipt gate: $out"
[ -d "$WT2" ] || gov_fail "(B) missing --build-receipt refusal must leave the worktree intact"
[ "$(python3 "$TRK" --tracker "$TRACKER2" show --num "$ISSUE2" --field Status)" = "In Progress" ] \
  || gov_fail "(B) missing --build-receipt refusal must not close the tracker item"
git -C "$ORIGIN2" show-ref --verify --quiet "refs/heads/$BRANCH2" \
  || gov_fail "(B) missing --build-receipt refusal must leave the remote branch intact"
echo "  ok (B) omitting --build-receipt on a real finish REFUSES before any irreversible step"

echo "PASS: idc_git_finish.py is a receipt gate — unrouted findings + unmet merge_conditions + missing/wrong-PR verdicts REFUSE the merge/close; omitting --build-receipt now REFUSES before any irreversible finish step; a clean routed condition-met receipt PROCEEDS; --no-require-routed-findings is a routed-only escape; github fails CLOSED on an unreadable board"
