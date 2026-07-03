#!/bin/bash
# verdict-filer.sh — governance scenario: the hook-fired filer routes review findings to the board.
#
# The invariant (Phase 1, plan §3.3): idc_file_findings.py consumes a VALIDATED verdict and, for
# every minor/nit finding AND every deferrals[] entry, creates a Stage=Recirculation / Status=Todo
# board item — with an idc-recirc-source dedupe marker (idempotent re-runs: ZERO duplicates), an
# origin/provenance line, and a parent-blocking dependency link for blocks_goal:true deferrals.
# major/blocker findings are NOT filed (they are FAILs the reviewer must fix, not deferrable nits).
#
#   (A) FILESYSTEM — end-to-end over a real TRACKER.md: N minor/nit findings + M deferrals ⇒ N+M
#       Recirculation/Todo items; re-run ⇒ still N+M (idempotent); a blocks_goal:true deferral
#       blocks the parent issue's Done via blocked_by; a major finding is NOT filed.
#   (B) GITHUB — unit-tested in-process by monkeypatching idc_gh_board._gh + the dedupe read: each
#       nit/deferral is created via the ATOMIC create_item(Stage=Recirculation, Status=Todo); an
#       already-marked key is skipped; a board-read failure fails CLOSED (files nothing, non-zero).
#
# Red-when-broken: neuter the dedupe (case A re-run doubles the count → FAIL); neuter the severity
# filter (a major gets filed → FAIL); neuter the blocks_goal link (no blocked_by → FAIL).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
FILER="$PLUGIN/scripts/idc_file_findings.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$FILER" ] || fail "filer not found at $FILER (not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── (A) FILESYSTEM end-to-end ─────────────────────────────────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null
# A parent build issue the review is about (issue #1 on the board).
PARENT="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'build: feature X' --stage Buildable --status 'In Progress')"

# Verdict: 2 nits (filed) + 1 major (NOT filed) + 2 deferrals (one blocks_goal:true) ⇒ 4 items, 1 link.
cat > "$WORK/verdict.json" <<JSON
{"verdict":"FAIL","issue":$PARENT,"pr":9,
 "findings":[
   {"dimension":"style","severity":"nit","confidence":0.9,"evidence":"magic number 7","attack":"a","unblock":"name the constant","fingerprint":"style:f.py:7:magic"},
   {"dimension":"perf","severity":"minor","confidence":0.85,"evidence":"n^2 loop on small n","attack":"a","unblock":"leave a note","fingerprint":"perf:g.py:20:n2"},
   {"dimension":"correctness","severity":"major","confidence":0.95,"evidence":"off-by-one","attack":"a","unblock":"fix the bound","fingerprint":"correctness:h.py:3:obo"}
 ],
 "deferrals":[
   {"kind":"deferred","what":"add integration test for the new path","blocks_goal":true,"suggested_issue":"integration coverage"},
   {"kind":"out-of-boundary","what":"refactor sibling module","blocks_goal":false,"suggested_issue":"sibling cleanup"}
 ]}
JSON

count_recirc() { python3 "$TRK" --tracker "$REPO/TRACKER.md" query --stage Recirculation --status Todo | grep -c . ; }
parent_blocked_by() {  # echoes the blocked_by list of the parent issue
  python3 - "$REPO/TRACKER.md" "$PARENT" "$PLUGIN/scripts" <<'PY'
import json,sys
sys.path.insert(0, sys.argv[3])
import idc_tracker_fs as T
st=T.load(sys.argv[1])
for it in st["issues"]:
    if it["number"]==int(sys.argv[2]): print(",".join(str(x) for x in it.get("blocked_by",[])))
PY
}

python3 "$FILER" --repo "$REPO" --verdict "$WORK/verdict.json" >/dev/null || fail "(A) filer run failed"
n1="$(count_recirc)"
[ "$n1" -eq 4 ] || fail "(A) expected 4 Recirculation/Todo items (2 nits + 2 deferrals), got $n1"
echo "  ok (A1) 2 minor/nit + 2 deferrals → 4 Recirculation/Todo items; major NOT filed"

# blocks_goal:true deferral must block the parent's Done (parent blocked_by the new ticket).
bb="$(parent_blocked_by)"
[ -n "$bb" ] || fail "(A) blocks_goal:true deferral did not create a parent-blocking link (parent has no blocked_by)"
echo "  ok (A2) blocks_goal:true deferral blocks the parent issue's Done (blocked_by=$bb)"

# Idempotent re-run: zero new items.
python3 "$FILER" --repo "$REPO" --verdict "$WORK/verdict.json" >/dev/null || fail "(A) filer re-run failed"
n2="$(count_recirc)"
[ "$n2" -eq 4 ] || fail "(A) re-run was NOT idempotent — item count went $n1 -> $n2 (duplicates)"
echo "  ok (A3) idempotent re-run: still 4 items (idc-recirc-source dedupe holds)"

# A missing parent for a blocks_goal:true deferral is a failed filing, not success: the caller must
# not believe the parent was blocked when the receipt cannot be created.
cat > "$WORK/bad-parent-verdict.json" <<JSON
{"verdict":"PASS","issue":9999,
 "findings":[],
 "deferrals":[{"kind":"deferred","what":"must block a missing parent","blocks_goal":true,"suggested_issue":"missing parent coverage"}]}
JSON
if python3 "$FILER" --repo "$REPO" --verdict "$WORK/bad-parent-verdict.json" >"$WORK/bad-parent.out" 2>&1; then
  fail "(A4) filesystem filer returned success even though a blocks_goal:true parent receipt could not be created"
fi
echo "  ok (A4) filesystem: missing blocks_goal parent surfaces non-zero"

# ── (B) GITHUB unit (monkeypatched) ────────────────────────────────────────────────────────────────
python3 - "$PLUGIN/scripts" "$FILER" <<'PY' || fail "(B) github filer unit tests failed (see assertion above)"
import json,sys,os
scripts=sys.argv[1]; sys.path.insert(0, scripts)
import idc_gh_board as B
import idc_file_findings as F

VERDICT={"verdict":"PASS-WITH-NITS","issue":1,"pr":9,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"e","attack":"a","unblock":"u","fingerprint":"style:a:1:x"}],
 "deferrals":[{"kind":"deferred","what":"w","blocks_goal":False,"suggested_issue":"s"}]}

created=[]
def fake_create_item(owner,project,repo,title,body,stage,status):
    created.append({"title":title,"stage":stage,"status":status,"body":body})
    return "PVTI_%d"%len(created)

# (B1) each nit+deferral → an ATOMIC create_item at Stage=Recirculation/Status=Todo, dedupe empty.
orig_ci=B.create_item; B.create_item=fake_create_item
try:
    n=F.file_github(VERDICT, repo=".", owner="o", project="1", existing_keys=set(), parent_issue=1, dry_run=False)
    assert len(created)==2, f"expected 2 create_item calls, got {len(created)}"
    for c in created:
        assert c["stage"]=="Recirculation", f"stage {c['stage']!r} != Recirculation"
        assert c["status"]=="Todo", f"status {c['status']!r} != Todo"
        assert "idc-recirc-source" in c["body"], "body missing idc-recirc-source dedupe marker"
    print("  ok (B1) github: each nit/deferral → atomic create_item(Recirculation, Todo) with dedupe marker")

    # (B2) an already-seen key is SKIPPED (idempotent).
    keys=F.work_items(VERDICT)  # the stable dedupe keys
    created.clear()
    n2=F.file_github(VERDICT, repo=".", owner="o", project="1",
                     existing_keys={w["key"] for w in keys}, parent_issue=1, dry_run=False)
    assert len(created)==0, f"expected 0 creates when all keys already filed, got {len(created)}"
    print("  ok (B2) github: an already-marked key is skipped (idempotent)")
finally:
    B.create_item=orig_ci

# (B3) a board-read failure fails CLOSED: the top-level filer files NOTHING (never blind).
def boom(*a,**k): raise B.BoardReadError("simulated dedupe read failure")
orig_fetch=B.fetch_items; B.fetch_items=boom
created.clear(); B.create_item=fake_create_item
try:
    rc=F.run_github(VERDICT, repo=".", owner="o", project="1", parent_issue=1, dry_run=False)
    assert len(created)==0, "filer created tickets despite a failed dedupe read (blind filing risk)"
    assert rc!=0, "filer returned success despite an un-dedupable board (should fail closed)"
    print("  ok (B3) github: dedupe board-read failure → fail-closed (files nothing)")
finally:
    B.fetch_items=orig_fetch; B.create_item=orig_ci

# (B4) a partial dedupe read failure (existing Recirculation item found, body unreadable) also fails
# CLOSED. Otherwise the hidden key on that unreadable item may be missed and duplicated.
def one_recirc(*a,**k):
    return [{"stage":"Recirculation","content":{"number":42}}]
def gh_body_fail(args, repo):
    return False, "", "simulated body read failure"
orig_fetch=B.fetch_items; orig_gh=F.SW.gh; B.fetch_items=one_recirc; F.SW.gh=gh_body_fail
created.clear(); B.create_item=fake_create_item
try:
    rc=F.run_github(VERDICT, repo=".", owner="o", project="1", parent_issue=1, dry_run=False)
    assert len(created)==0, "filer created tickets despite an unreadable existing Recirculation body"
    assert rc!=0, "filer returned success despite a partial dedupe body-read failure"
    print("  ok (B4) github: partial dedupe body-read failure → fail-closed (files nothing)")
finally:
    B.fetch_items=orig_fetch; F.SW.gh=orig_gh; B.create_item=orig_ci
PY

echo "PASS: verdict filer — minor/nit findings + deferrals become Stage=Recirculation/Status=Todo items (both backends), idempotent via idc-recirc-source, blocks_goal:true blocks the parent, major/blocker not filed, github dedupe fails closed"
